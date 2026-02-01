# OBS AvoCam Plugin Packaging

This directory contains scripts for building installer packages for the OBS AvoCam plugin.

## Prerequisites

### All Platforms
- CMake 3.16 or later
- OBS Studio SDK

### macOS
- Xcode Command Line Tools
- macOS 11.0+ SDK (for Universal Binary support)

### Windows
- Visual Studio 2019 or 2022 with C++ workload
- Inno Setup 6.x (for installer creation, optional)
  - Download: https://jrsoftware.org/isinfo.php

## Building

### macOS

```bash
cd packaging/macos
./build-pkg.sh [version]
```

This creates:
- `build-release/obs-avolocam-[version].pkg` - macOS installer package
- `build-release/obs-avolocam-[version]-macos.zip` - ZIP for manual installation

### Windows

```cmd
cd packaging\windows
build-installer.bat [version]
```

This creates:
- `build/obs-avolocam-[version]-setup.exe` - Windows installer (if Inno Setup is available)
- `build/obs-avolocam-[version]-windows.zip` - ZIP for manual installation

## Installation

### macOS

**Option 1: PKG Installer**
1. Double-click the `.pkg` file
2. Follow the installation wizard

**Option 2: Manual Installation**
```bash
unzip obs-avolocam-[version]-macos.zip
cp -r obs-avolocam.plugin ~/Library/Application\ Support/obs-studio/plugins/
```

### Windows

**Option 1: EXE Installer**
1. Run the `.exe` installer
2. Follow the installation wizard

**Option 2: Manual Installation**
1. Extract the ZIP file
2. Copy the `obs-avolocam` folder to `%APPDATA%\obs-studio\plugins\`

## Uninstallation

### macOS
Delete the plugin folder:
```bash
rm -rf ~/Library/Application\ Support/obs-studio/plugins/obs-avolocam.plugin
```

### Windows
- Use "Add or Remove Programs" if installed via the installer
- Or manually delete `%APPDATA%\obs-studio\plugins\obs-avolocam`

## Development Builds

For development, you can install directly after building:

### macOS
```bash
cmake -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build
cmake --install build
```

### Windows
```cmd
cmake -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Debug
cmake --install build --config Debug
```

## Troubleshooting

### Plugin not appearing in OBS

1. Check if the plugin is in the correct directory
2. Check OBS logs for loading errors: Help -> Log Files -> Show Log Files
3. Ensure you have the correct architecture (64-bit OBS requires 64-bit plugin)

### Build errors

1. Ensure OBS SDK is found by CMake
2. Set `LIBOBS_INCLUDE_DIR` and `LIBOBS_LIB` environment variables if needed
3. Check that all dependencies are installed

## Version History

- **1.0.0** - Initial release
  - UDP/RTP video reception
  - Hardware-accelerated H.264 decoding (VideoToolbox/Media Foundation)
  - WebSocket integration for camera control and telemetry
  - GPU texture output support
