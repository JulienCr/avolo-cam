# OBS AvoCam Plugin - Build & Install
#
# Usage:
#   make          - Build the plugin
#   make install  - Build and install (macOS: OBS.app, Windows: use install.bat)
#   make clean    - Clean build artifacts
#   make rebuild  - Clean and rebuild
#
# Windows: Use build.bat and install.bat instead, or nmake with Makefile.win

BUILD_DIR := build
PLUGIN_NAME := obs-avolocam.plugin
OBS_PLUGINS_DIR := /Applications/OBS.app/Contents/PlugIns
LOCAL_PLUGIN_DIR := $(PLUGIN_NAME)/Contents/MacOS

.PHONY: all build install clean rebuild configure

all: build

configure:
	@mkdir -p $(BUILD_DIR)
	@cd $(BUILD_DIR) && cmake .. -DCMAKE_BUILD_TYPE=Release

build: configure
	@echo "Building OBS AvoCam plugin..."
	@cd $(BUILD_DIR) && cmake --build . --parallel
	@cp $(BUILD_DIR)/obs-avolocam.so $(LOCAL_PLUGIN_DIR)/
	@cp $(BUILD_DIR)/obs-avolocam.so $(LOCAL_PLUGIN_DIR)/obs-avolocam
	@echo "Build complete: $(LOCAL_PLUGIN_DIR)/obs-avolocam"

install: build
	@echo "Installing plugin to OBS.app (requires sudo)..."
	@sudo rm -rf $(OBS_PLUGINS_DIR)/$(PLUGIN_NAME)
	@sudo cp -R $(PLUGIN_NAME) $(OBS_PLUGINS_DIR)/
	@echo "Plugin installed to $(OBS_PLUGINS_DIR)/$(PLUGIN_NAME)"
	@echo "Restart OBS to load the updated plugin."

clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(BUILD_DIR)
	@rm -f $(LOCAL_PLUGIN_DIR)/obs-avolocam.so
	@echo "Clean complete."

rebuild: clean build
