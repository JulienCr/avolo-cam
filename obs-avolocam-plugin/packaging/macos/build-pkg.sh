#!/bin/bash
#
# build-pkg.sh - Build macOS installer package for OBS AvoCam plugin
#
# Usage: ./build-pkg.sh [version]
#
# Requires:
# - CMake
# - Xcode Command Line Tools
# - OBS SDK installed or LIBOBS_INCLUDE_DIR/LIBOBS_LIB set
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="${PROJECT_ROOT}/build-release"
PKG_ROOT="${BUILD_DIR}/pkg-root"

# Version from argument or default
VERSION="${1:-1.0.0}"
IDENTIFIER="com.avolocam.obs-plugin"
PLUGIN_NAME="obs-avolocam"

echo "=========================================="
echo "Building OBS AvoCam Plugin v${VERSION}"
echo "=========================================="

# Clean previous build
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Configure CMake
echo ""
echo "Configuring CMake..."
cmake -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="x86_64;arm64" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
    "${PROJECT_ROOT}"

# Build
echo ""
echo "Building..."
cmake --build "${BUILD_DIR}" --config Release --parallel

# Check if build succeeded
if [ ! -f "${BUILD_DIR}/obs-avolocam.so" ]; then
    echo "ERROR: Build failed - obs-avolocam.so not found"
    exit 1
fi

echo ""
echo "Creating package structure..."

# Create OBS plugin directory structure
PLUGIN_DIR="${PKG_ROOT}/Library/Application Support/obs-studio/plugins/${PLUGIN_NAME}.plugin/Contents/MacOS"
mkdir -p "${PLUGIN_DIR}"

# Copy the plugin
cp "${BUILD_DIR}/obs-avolocam.so" "${PLUGIN_DIR}/"

# Create data directory if we have data files
DATA_DIR="${PKG_ROOT}/Library/Application Support/obs-studio/plugins/${PLUGIN_NAME}.plugin/Contents/Resources"
if [ -d "${PROJECT_ROOT}/data" ]; then
    mkdir -p "${DATA_DIR}"
    cp -R "${PROJECT_ROOT}/data/"* "${DATA_DIR}/" 2>/dev/null || true
fi

# Create Info.plist for the plugin bundle
cat > "${PKG_ROOT}/Library/Application Support/obs-studio/plugins/${PLUGIN_NAME}.plugin/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>obs-avolocam.so</string>
    <key>CFBundleIdentifier</key>
    <string>${IDENTIFIER}</string>
    <key>CFBundleName</key>
    <string>OBS AvoCam Plugin</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright 2024 AvoCam Team</string>
</dict>
</plist>
EOF

echo ""
echo "Building installer package..."

# Create the .pkg installer
PKG_OUTPUT="${BUILD_DIR}/${PLUGIN_NAME}-${VERSION}.pkg"
pkgbuild \
    --root "${PKG_ROOT}" \
    --identifier "${IDENTIFIER}" \
    --version "${VERSION}" \
    --install-location "/" \
    "${PKG_OUTPUT}"

echo ""
echo "=========================================="
echo "Package created: ${PKG_OUTPUT}"
echo "=========================================="

# Calculate checksums
echo ""
echo "Checksums:"
shasum -a 256 "${PKG_OUTPUT}"

# Create a .zip for manual installation
echo ""
echo "Creating ZIP archive..."
ZIP_OUTPUT="${BUILD_DIR}/${PLUGIN_NAME}-${VERSION}-macos.zip"
cd "${PKG_ROOT}/Library/Application Support/obs-studio/plugins"
zip -r "${ZIP_OUTPUT}" "${PLUGIN_NAME}.plugin"
echo "ZIP created: ${ZIP_OUTPUT}"
shasum -a 256 "${ZIP_OUTPUT}"

echo ""
echo "Installation instructions:"
echo "  Option 1 (PKG installer):"
echo "    Double-click ${PKG_OUTPUT}"
echo ""
echo "  Option 2 (Manual):"
echo "    unzip ${ZIP_OUTPUT}"
echo "    mv ${PLUGIN_NAME}.plugin ~/Library/Application\\ Support/obs-studio/plugins/"
echo ""
echo "Done!"
