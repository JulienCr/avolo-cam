# AvoloCam Build Makefile

.PHONY: build build-ios install-ios debug-ios build-tauri build-obs install-obs clean clean-ios clean-tauri clean-obs help

# OBS plugin install path (override with OBS_PLUGINS_DIR=...)
OBS_PLUGINS_DIR ?= C:\Program Files\obs-studio\obs-plugins\64bit

# Default target
build: build-ios build-tauri build-obs

# Build iOS app (Ad Hoc IPA)
build-ios:
	@echo "[ios] Building iOS app..."
	@cd ios-app/AvoCam && ./build-ipa.sh
	@echo "[ios] Done: ios-app/AvoCam/build/ipa/AvoloCam.ipa"

# Debug build + install + console logs on connected iOS devices
# Usage: make debug-ios               (interactive)
#        make debug-ios DEVICES=all   (all devices)
#        make debug-ios DEVICES="AvoloPhone,iPhone de Julien"
debug-ios:
	@cd ios-app/AvoCam && ./debug-ios.sh "$(DEVICES)"

# Install IPA on connected iOS devices
# Usage: make install-ios              (interactive)
#        make install-ios DEVICES=all  (all devices)
#        make install-ios DEVICES="AvoloPhone,iPhone de Julien"
install-ios:
	@cd ios-app/AvoCam && ./install-ios.sh "$(DEVICES)"

# Build Tauri desktop app
build-tauri:
	@echo "[tauri] Building Tauri app..."
	@cd tauri-controller && pnpm install --frozen-lockfile && pnpm run tauri:build
	@echo "[tauri] Done"

# Build OBS plugin (Windows: cmake Release)
build-obs:
	@echo "[obs] Building OBS plugin..."
	@cd obs-avolocam-plugin && cmake --build build --config Release
	@echo "[obs] Done: obs-avolocam-plugin/build/Release/obs-avolocam.dll"
	@echo "[obs] Install with: make install-obs"

# Install OBS plugin with UAC elevation
install-obs: build-obs
	@echo "[obs] Requesting admin rights to copy to $(OBS_PLUGINS_DIR)..."
	@powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-Command','Copy-Item -Force ''$(CURDIR)/obs-avolocam-plugin/build/Release/obs-avolocam.dll'' ''$(OBS_PLUGINS_DIR)/obs-avolocam.dll'''"
	@echo "[obs] Installed. Restart OBS to load the plugin."

# Clean build artifacts
clean: clean-ios clean-tauri clean-obs

clean-ios:
	@echo "[ios] Cleaning build..."
	@rm -rf ios-app/AvoCam/build

clean-tauri:
	@echo "[tauri] Cleaning build..."
	@rm -rf tauri-controller/src-tauri/target/release

clean-obs:
	@echo "[obs] Cleaning build..."
	@rm -rf obs-avolocam-plugin/build

# Help
help:
	@echo "AvoloCam Build Commands:"
	@echo "  make build        - Build all (iOS + Tauri + OBS)"
	@echo "  make build-ios    - Build iOS Ad Hoc IPA"
	@echo "  make build-tauri  - Build Tauri desktop app"
	@echo "  make build-obs    - Build OBS plugin"
	@echo "  make install-ios  - Install IPA on connected iOS devices"
	@echo "  make debug-ios    - Debug build + install + live console logs"
	@echo "  make install-obs  - Build + install OBS plugin (UAC)"
	@echo "  make clean        - Clean all build artifacts"
	@echo "  make clean-ios    - Clean iOS build only"
	@echo "  make clean-tauri  - Clean Tauri build only"
	@echo "  make clean-obs    - Clean OBS plugin build only"
