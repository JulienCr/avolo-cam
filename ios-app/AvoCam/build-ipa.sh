#!/bin/bash
# Build script for AvoloCam Ad Hoc IPA
set -e

cd "$(dirname "$0")"

echo "🧹 Cleaning previous build..."
rm -rf build

echo "🔢 Incrementing build number..."
# Get current build number and increment it
CURRENT_BUILD=$(agvtool what-version -terse)
NEW_BUILD=$((CURRENT_BUILD + 1))
agvtool new-version -all $NEW_BUILD > /dev/null
# Extract marketing version from project file
MARKETING_VERSION=$(grep -m1 'MARKETING_VERSION' AvoCam.xcodeproj/project.pbxproj | sed -E 's/.*= *(.+);/\1/')
echo "   Version: $MARKETING_VERSION ($NEW_BUILD)"

echo "📦 Archiving..."
xcodebuild -project AvoCam.xcodeproj \
  -scheme AvoCam \
  -configuration Release \
  -archivePath ./build/AvoCam.xcarchive \
  archive \
  -allowProvisioningUpdates \
  -quiet

echo "📱 Exporting IPA..."
xcodebuild -exportArchive \
  -archivePath ./build/AvoCam.xcarchive \
  -exportPath ./build/ipa \
  -exportOptionsPlist ExportOptions.plist \
  -allowProvisioningUpdates

echo ""
echo "✅ Build complete!"
echo "📍 IPA: $(pwd)/build/ipa/AvoloCam.ipa"
echo "📌 Version: $MARKETING_VERSION ($NEW_BUILD)"
