#!/bin/bash

# Script to build WaxOn and create a DMG file
# Usage: ./create_dmg.sh

set -e  # Exit on error

# Configuration
APP_NAME="WaxOn"
PROJECT_PATH="WaxOn/WaxOn.xcodeproj"
SCHEME="WaxOn"
BUILD_DIR="build"
DMG_NAME="${APP_NAME}-v1.4.dmg"
DMG_TEMP_DIR="${BUILD_DIR}/dmg_temp"
DMG_VOLUME_NAME="${APP_NAME}"

echo "Building ${APP_NAME}..."

# Clean and build the app in Release configuration
xcodebuild clean -project "${PROJECT_PATH}" -scheme "${SCHEME}" -configuration Release
xcodebuild build -project "${PROJECT_PATH}" -scheme "${SCHEME}" -configuration Release -derivedDataPath "${BUILD_DIR}"

# Find the built app
APP_PATH=$(find "${BUILD_DIR}/Build/Products/Release" -name "${APP_NAME}.app" -type d | head -n 1)

if [ -z "$APP_PATH" ]; then
    echo "Error: Could not find built app"
    exit 1
fi

echo "Found app at: ${APP_PATH}"

# Create temporary directory for DMG contents
echo "Preparing DMG contents..."
rm -rf "${DMG_TEMP_DIR}"
mkdir -p "${DMG_TEMP_DIR}"

# Copy app to DMG directory
cp -R "${APP_PATH}" "${DMG_TEMP_DIR}/"

# Copy README.txt to DMG directory
if [ -f "README.md" ]; then
    cp "README.md" "${DMG_TEMP_DIR}/"
else
    echo "Warning: README.md not found"
fi

# Create a symbolic link to Applications folder (optional, for convenience)
ln -s /Applications "${DMG_TEMP_DIR}/Applications"

# Remove existing DMG if it exists
if [ -f "${DMG_NAME}" ]; then
    echo "Removing existing DMG..."
    rm "${DMG_NAME}"
fi

# Create the DMG
echo "Creating DMG file..."
hdiutil create -volname "${DMG_VOLUME_NAME}" -srcfolder "${DMG_TEMP_DIR}" -ov -format UDZO "${DMG_NAME}"

# Clean up temporary directory
rm -rf "${DMG_TEMP_DIR}"

echo "Done! DMG created: ${DMG_NAME}"

