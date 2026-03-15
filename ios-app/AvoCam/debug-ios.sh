#!/bin/bash
# Build Debug, install, and stream console logs from connected iOS devices
# Usage:
#   ./debug-ios.sh                              # Interactive: select devices
#   ./debug-ios.sh all                          # All connected devices
#   ./debug-ios.sh "AvoloPhone,iPhone de Julien" # Named devices
set -e

cd "$(dirname "$0")"

BUNDLE_ID="com.avolo.avolocam"
APP_PATH="build/debug/Build/Products/Debug-iphoneos/AvoCam.app"
LAUNCH_PIDS=()

# Cleanup: kill all background devicectl processes
cleanup() {
    rm -f "$TMP_JSON"
    if [ ${#LAUNCH_PIDS[@]} -gt 0 ]; then
        echo ""
        echo "Stopping console streams..."
        for pid in "${LAUNCH_PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
        wait 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM

# --- Build Debug .app ---
echo "Building Debug .app..."
xcodebuild build \
    -project AvoCam.xcodeproj \
    -scheme AvoCam \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    -derivedDataPath build/debug \
    -allowProvisioningUpdates \
    -quiet

if [ ! -d "$APP_PATH" ]; then
    echo "Error: .app not found at $APP_PATH"
    exit 1
fi
echo "Build OK: $APP_PATH"
echo ""

# --- Discover devices ---
TMP_JSON=$(mktemp /tmp/avolo-devices.XXXXXX.json)
xcrun devicectl list devices --json-output "$TMP_JSON" >/dev/null 2>&1

devices=()
while IFS= read -r line; do
    [ -n "$line" ] && devices+=("$line")
done < <(python3 - "$TMP_JSON" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for d in data['result']['devices']:
    tunnel = d['connectionProperties'].get('tunnelState', '')
    if tunnel == 'unavailable':
        continue
    name = d['deviceProperties']['name']
    cid = d['identifier']
    model = d['hardwareProperties'].get('marketingName', '?')
    print(f'{name}|{cid}|{model}')
PYEOF
)

if [ ${#devices[@]} -eq 0 ]; then
    echo "No available iOS devices found."
    echo "Make sure devices are connected via USB and paired."
    exit 1
fi

# Parse pipe-delimited device record
dev_name()  { local tmp="${1%%|*}"; echo "$tmp"; }
dev_id()    { local tmp="${1#*|}"; echo "${tmp%%|*}"; }
dev_model() { echo "${1##*|}"; }

# --- Select devices ---
selected=()
DEVICES_ARG="${1:-}"

if [ "$DEVICES_ARG" = "all" ]; then
    selected=("${devices[@]}")
elif [ -n "$DEVICES_ARG" ]; then
    IFS=',' read -ra requested <<< "$DEVICES_ARG"
    for req in "${requested[@]}"; do
        req=$(echo "$req" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        found=false
        for dev in "${devices[@]}"; do
            if [ "$(dev_name "$dev")" = "$req" ]; then
                selected+=("$dev")
                found=true
                break
            fi
        done
        if [[ "$found" == false ]]; then
            echo "Warning: device '$req' not found or not available, skipping."
        fi
    done
else
    # Interactive mode
    echo "Available devices:"
    echo ""
    for i in "${!devices[@]}"; do
        echo "  $((i + 1)). $(dev_name "${devices[$i]}") ($(dev_model "${devices[$i]}"))"
    done
    echo ""
    echo "Select devices (e.g. '1 3', 'all', or Enter for all):"
    read -r selection

    if [ -z "$selection" ] || [ "$selection" = "all" ]; then
        selected=("${devices[@]}")
    else
        for num in $selection; do
            idx=$((num - 1))
            if [ "$idx" -ge 0 ] && [ "$idx" -lt ${#devices[@]} ]; then
                selected+=("${devices[$idx]}")
            else
                echo "Warning: invalid selection '$num', skipping."
            fi
        done
    fi
fi

if [ ${#selected[@]} -eq 0 ]; then
    echo "No devices selected."
    exit 1
fi

# --- Install on each device (parallel) ---
echo "Installing on ${#selected[@]} device(s)..."
install_pids=()
install_names=()

for dev in "${selected[@]}"; do
    name="$(dev_name "$dev")"
    identifier="$(dev_id "$dev")"
    (
        if xcrun devicectl device install app --device "$identifier" "$APP_PATH" >/dev/null 2>&1; then
            echo "  Installed: $name"
        else
            echo "  FAILED to install: $name"
            exit 1
        fi
    ) &
    install_pids+=($!)
    install_names+=("$name")
done

# Wait for all installs
install_failures=0
for i in "${!install_pids[@]}"; do
    if ! wait "${install_pids[$i]}"; then
        ((install_failures++))
    fi
done

if [ $install_failures -gt 0 ]; then
    echo "$install_failures install(s) failed."
    exit 1
fi
echo ""

# --- Launch with console on each device (parallel, color-prefixed output) ---
# Cycle through distinct colors for each device
COLORS=("\033[1;36m" "\033[1;33m" "\033[1;32m" "\033[1;35m" "\033[1;31m" "\033[1;34m")
RESET="\033[0m"

echo "Launching with console output (Ctrl+C to stop)..."
echo "---"

for i in "${!selected[@]}"; do
    dev="${selected[$i]}"
    name="$(dev_name "$dev")"
    identifier="$(dev_id "$dev")"
    color="${COLORS[$((i % ${#COLORS[@]}))]}"
    (
        # Retry loop: wait for device to be unlocked before streaming console
        while true; do
            # Try a non-console launch first to test if device is ready
            test_output=$(xcrun devicectl device process launch \
                --terminate-existing \
                --device "$identifier" \
                "$BUNDLE_ID" 2>&1)
            test_rc=$?
            if [ $test_rc -eq 0 ]; then
                break
            fi
            if echo "$test_output" | grep -qi "lock\|passcode\|screen must be unlocked"; then
                printf "${color}[${name}]${RESET} Device locked — unlock to continue (retrying in 3s)...\n"
                sleep 3
            else
                # Unknown error, print and bail
                printf "${color}[${name}]${RESET} Launch failed: %s\n" "$test_output"
                exit 1
            fi
        done
        # Device is unlocked and app is running — relaunch with console streaming
        xcrun devicectl device process launch \
            --terminate-existing \
            --console \
            --device "$identifier" \
            "$BUNDLE_ID" 2>&1 \
        | while IFS= read -r line; do
            printf "${color}[${name}]${RESET} %s\n" "$line"
        done
    ) &
    LAUNCH_PIDS+=($!)
done

# Wait for all — they run until Ctrl+C
wait
