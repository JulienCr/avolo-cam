#!/bin/bash
#
# build.sh - Cross-platform build script for OBS AvoCam Plugin
#
# Usage: ./build.sh [debug|release] [--install]
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_TYPE="${1:-Release}"
DO_INSTALL=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        debug|Debug)
            BUILD_TYPE="Debug"
            ;;
        release|Release)
            BUILD_TYPE="Release"
            ;;
        --install)
            DO_INSTALL=true
            ;;
    esac
done

BUILD_DIR="${SCRIPT_DIR}/build-$(echo "${BUILD_TYPE}" | tr '[:upper:]' '[:lower:]')"

echo "=========================================="
echo "Building OBS AvoCam Plugin (${BUILD_TYPE})"
echo "=========================================="

# Configure
echo ""
echo "Configuring..."

CMAKE_ARGS="-DCMAKE_BUILD_TYPE=${BUILD_TYPE}"

# Platform-specific configuration
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS: Build Universal Binary
    CMAKE_ARGS="${CMAKE_ARGS} -DCMAKE_OSX_ARCHITECTURES=x86_64;arm64"
    CMAKE_ARGS="${CMAKE_ARGS} -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0"
fi

cmake -B "${BUILD_DIR}" ${CMAKE_ARGS} "${SCRIPT_DIR}"

# Build
echo ""
echo "Building..."
cmake --build "${BUILD_DIR}" --config "${BUILD_TYPE}" --parallel

# Install if requested
if [ "$DO_INSTALL" = true ]; then
    echo ""
    echo "Installing..."
    cmake --install "${BUILD_DIR}" --config "${BUILD_TYPE}"
fi

echo ""
echo "=========================================="
echo "Build complete!"
echo ""
echo "Output:"
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "  ${BUILD_DIR}/obs-avolocam.so"
else
    echo "  ${BUILD_DIR}/${BUILD_TYPE}/obs-avolocam.dll"
fi
echo "=========================================="

if [ "$DO_INSTALL" = false ]; then
    echo ""
    echo "Run with --install to install to OBS plugins directory"
fi
