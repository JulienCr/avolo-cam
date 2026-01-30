#!/bin/bash
# Build script for AvoloCam Ad Hoc IPA
set -e

cd "$(dirname "$0")"

echo "🧹 Cleaning previous build..."
rm -rf build

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
