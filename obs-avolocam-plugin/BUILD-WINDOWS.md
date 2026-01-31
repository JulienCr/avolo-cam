# Building OBS AvoCam Plugin on Windows

This guide covers building the OBS AvoCam plugin on Windows.

## Prerequisites

### Required

1. **Visual Studio 2019 or 2022** with C++ workload
   - Download from [visualstudio.microsoft.com](https://visualstudio.microsoft.com/)
   - During installation, select "Desktop development with C++"
   - Ensure Windows SDK is included (10.0.19041.0 or later)

2. **CMake 3.16+**
   - Download from [cmake.org](https://cmake.org/download/)
   - Or install via Visual Studio Installer (Individual Components → CMake tools)
   - Ensure CMake is in your PATH

3. **OBS Studio**
   - Download from [obsproject.com](https://obsproject.com/)
   - Default installation to `C:\Program Files\obs-studio`
   - The plugin links against OBS's obs.dll

### Optional

4. **Bonjour SDK** (for mDNS camera discovery)
   - Download from [Apple Developer](https://developer.apple.com/bonjour/)
   - Install to `C:\Program Files\Bonjour SDK`
   - Without this, you must manually enter camera IP addresses

## Quick Build

### Option 1: Using the Build Script

1. Open **Developer Command Prompt for VS** or **x64 Native Tools Command Prompt**
2. Navigate to the plugin directory:
   ```cmd
   cd path\to\avolo-cam\obs-avolocam-plugin
   ```
3. Run the build script:
   ```cmd
   build-windows.bat
   ```

### Option 2: Manual CMake Build

```cmd
cd obs-avolocam-plugin
mkdir build-win
cd build-win

cmake .. -G "Visual Studio 17 2022" -A x64 ^
    -DOBS_DIR="C:\Program Files\obs-studio" ^
    -DBONJOUR_SDK_DIR="C:\Program Files\Bonjour SDK"

cmake --build . --config Release --parallel
```

## Build Output

After a successful build:
```
build-win\Release\obs-avolocam.dll
```

## Installation

### Manual Installation

1. Create the plugin directory:
   ```cmd
   mkdir "%APPDATA%\obs-studio\plugins\obs-avolocam\bin\64bit"
   ```

2. Copy the DLL:
   ```cmd
   copy build-win\Release\obs-avolocam.dll "%APPDATA%\obs-studio\plugins\obs-avolocam\bin\64bit\"
   ```

3. (Optional) If you have data files:
   ```cmd
   mkdir "%APPDATA%\obs-studio\plugins\obs-avolocam\data"
   xcopy data "%APPDATA%\obs-studio\plugins\obs-avolocam\data\" /E
   ```

### Using CMake Install

```cmd
cmake --install build-win --config Release
```

## Verification

1. Launch OBS Studio
2. Go to **Sources** → **Add** → **AvoCam Source**
3. The source should appear in the list

If the plugin doesn't appear:
- Check **Help** → **Log Files** → **View Current Log** for errors
- Look for lines containing "obs-avolocam"

## CMake Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `OBS_DIR` | Auto-detected | Path to OBS Studio installation |
| `BONJOUR_SDK_DIR` | Auto-detected | Path to Bonjour SDK (optional) |
| `ENABLE_FFMPEG_FALLBACK` | ON | Enable FFmpeg software decoder |

Example with custom paths:
```cmd
cmake .. -G "Visual Studio 17 2022" -A x64 ^
    -DOBS_DIR="D:\OBS Studio" ^
    -DBONJOUR_SDK_DIR="D:\Bonjour SDK" ^
    -DENABLE_FFMPEG_FALLBACK=OFF
```

## Troubleshooting

### "OBS library not found"

Ensure OBS Studio is installed and `OBS_DIR` points to the correct location:
```cmd
cmake .. -DOBS_DIR="C:\Program Files\obs-studio"
```

Check that `obs.dll` exists in `<OBS_DIR>\bin\64bit\`.

### "Bonjour SDK not found"

This is optional. Without it, mDNS auto-discovery is disabled, but you can still connect to cameras by IP address.

To enable mDNS:
1. Download Bonjour SDK from Apple Developer
2. Install to `C:\Program Files\Bonjour SDK`
3. Rebuild with `-DBONJOUR_SDK_DIR="C:\Program Files\Bonjour SDK"`

### "Visual Studio compiler not found"

Run the build from a Visual Studio command prompt:
- Start → Visual Studio 2022 → x64 Native Tools Command Prompt

Or load VS environment manually:
```cmd
"C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
```

### Plugin loads but no video

1. Ensure your camera is streaming (check telemetry in controller)
2. Check OBS log for decoder errors
3. Try disabling hardware decoding in source properties
4. Ensure Windows Media Foundation is functional:
   ```cmd
   dxdiag
   ```
   Check DirectX Video Acceleration (DXVA) support

### Linker errors for Media Foundation

Ensure Windows SDK is installed. The following libraries are required:
- `mf.lib`, `mfplat.lib`, `mfuuid.lib`, `mfreadwrite.lib`
- `d3d11.lib`, `dxgi.lib`

These come with Windows SDK 10.0.19041.0 or later.

## Dependencies Summary

| Component | Required | Source | Purpose |
|-----------|----------|--------|---------|
| Visual Studio 2019+ | Yes | Microsoft | C++ compiler |
| CMake 3.16+ | Yes | cmake.org | Build system |
| OBS Studio | Yes | obsproject.com | Plugin API |
| Windows SDK | Yes | VS Installer | Media Foundation, D3D11 |
| Bonjour SDK | No | Apple Developer | mDNS discovery |
| FFmpeg | No | ffmpeg.org | Software decoder fallback |

## Architecture

The Windows build uses:
- **Media Foundation** for H.264 hardware decoding (GPU accelerated)
- **D3D11** for texture output to OBS
- **Winsock2** for UDP/WebSocket networking
- **Bonjour SDK** (dns-sd.dll) for mDNS camera discovery

All cross-platform code is already implemented in the source files with `#ifdef _WIN32` guards.
