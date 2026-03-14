#!/bin/bash
# Install AvoloCam IPA on connected iOS devices
# Usage:
#   ./install-ios.sh                     # Interactive: select devices
#   ./install-ios.sh all                 # Install on all available devices
#   ./install-ios.sh "AvoloPhone,iPhone de Julien"  # Install on named devices
set -e

cd "$(dirname "$0")"

IPA_PATH="./build/ipa/AvoloCam.ipa"

if [ ! -f "$IPA_PATH" ]; then
    echo "Error: IPA not found at $IPA_PATH"
    echo "Run 'make build-ios' first."
    exit 1
fi

# Get available devices as "name|identifier|model" lines using JSON output
TMP_JSON=$(mktemp /tmp/avolo-devices.XXXXXX.json)
trap "rm -f '$TMP_JSON'" EXIT

xcrun devicectl list devices --json-output "$TMP_JSON" >/dev/null 2>&1

# Parse JSON with python3 — filter to available (paired) devices only
devices=()
while IFS= read -r line; do
    [ -n "$line" ] && devices+=("$line")
done < <(python3 -c "
import json, sys
with open('$TMP_JSON') as f:
    data = json.load(f)
for d in data['result']['devices']:
    tunnel = d['connectionProperties'].get('tunnelState', '')
    if tunnel == 'unavailable':
        continue
    name = d['deviceProperties']['name']
    cid = d['identifier']
    model = d['hardwareProperties'].get('marketingName', '?')
    print(f'{name}|{cid}|{model}')
")

if [ ${#devices[@]} -eq 0 ]; then
    echo "No available iOS devices found."
    echo "Make sure devices are connected via USB and paired."
    exit 1
fi

install_on_device() {
    local name="$1"
    local identifier="$2"
    local logfile="$3"
    echo "Installing on $name ($identifier)..."
    if xcrun devicectl device install app --device "$identifier" "$IPA_PATH" >"$logfile" 2>&1; then
        echo "OK: $name"
    else
        echo "FAILED: $name (see log below)"
        return 1
    fi
}

# Build selection
selected=()
DEVICES_ARG="${1:-}"

if [ "$DEVICES_ARG" = "all" ]; then
    selected=("${devices[@]}")
elif [ -n "$DEVICES_ARG" ]; then
    # Match by name from comma-separated list
    IFS=',' read -ra requested <<< "$DEVICES_ARG"
    for req in "${requested[@]}"; do
        req=$(echo "$req" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        found=false
        for dev in "${devices[@]}"; do
            dev_name="${dev%%|*}"
            if [ "$dev_name" = "$req" ]; then
                selected+=("$dev")
                found=true
                break
            fi
        done
        if ! $found; then
            echo "Warning: device '$req' not found or not available, skipping."
        fi
    done
else
    # Interactive mode
    echo "Available devices:"
    echo ""
    for i in "${!devices[@]}"; do
        dev="${devices[$i]}"
        name="${dev%%|*}"
        model="${dev##*|}"
        echo "  $((i + 1)). $name ($model)"
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

echo ""
echo "Installing AvoloCam.ipa on ${#selected[@]} device(s) in parallel..."

TMP_LOGS=$(mktemp -d /tmp/avolo-install.XXXXXX)
pids=()
pid_names=()
pid_logs=()

for dev in "${selected[@]}"; do
    name="${dev%%|*}"
    identifier=$(echo "$dev" | cut -d'|' -f2)
    logfile="$TMP_LOGS/$(echo "$name" | tr ' ' '_').log"
    install_on_device "$name" "$identifier" "$logfile" &
    pids+=($!)
    pid_names+=("$name")
    pid_logs+=("$logfile")
done

# Wait for all and collect results
failures=0
for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
        ((failures++))
        echo ""
        echo "--- Log for ${pid_names[$i]} ---"
        cat "${pid_logs[$i]}"
        echo "---"
    fi
done

rm -rf "$TMP_LOGS"

echo ""
if [ $failures -eq 0 ]; then
    echo "All installations completed successfully."
else
    echo "$failures installation(s) failed."
    exit 1
fi
