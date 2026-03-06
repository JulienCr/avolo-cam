# AvoloCam Build Makefile

.PHONY: build build-ios build-tauri build-obs clean clean-ios clean-tauri clean-obs help

# Default target
build: build-ios build-tauri build-obs

# Build iOS app (Ad Hoc IPA)
build-ios:
	@echo "📱 Building iOS app..."
	@cd ios-app/AvoCam && ./build-ipa.sh
	@echo "✅ iOS IPA: ios-app/AvoCam/build/ipa/AvoloCam.ipa"

# Build Tauri desktop app
build-tauri:
	@echo "🖥️  Building Tauri app..."
	@cd tauri-controller && pnpm install --frozen-lockfile && pnpm run tauri:build
	@echo "✅ Tauri app built"

# Build OBS plugin (Windows: cmake Release)
build-obs:
	@echo "🔌 Building OBS plugin..."
	@cd obs-avolocam-plugin && cmake --build build --config Release
	@echo "✅ OBS plugin built"

# Clean build artifacts
clean: clean-ios clean-tauri clean-obs

clean-ios:
	@echo "🧹 Cleaning iOS build..."
	@rm -rf ios-app/AvoCam/build

clean-tauri:
	@echo "🧹 Cleaning Tauri build..."
	@rm -rf tauri-controller/src-tauri/target/release

clean-obs:
	@echo "🧹 Cleaning OBS plugin build..."
	@rm -rf obs-avolocam-plugin/build

# Help
help:
	@echo "AvoloCam Build Commands:"
	@echo "  make build       - Build both iOS and Tauri apps"
	@echo "  make build-ios   - Build iOS Ad Hoc IPA"
	@echo "  make build-tauri - Build Tauri desktop app"
	@echo "  make build-obs   - Build OBS plugin"
	@echo "  make clean       - Clean all build artifacts"
	@echo "  make clean-ios   - Clean iOS build only"
	@echo "  make clean-tauri - Clean Tauri build only"
	@echo "  make clean-obs   - Clean OBS plugin build only"
