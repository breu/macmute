#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="MacMute"
EXECUTABLE_NAME="MacMuteApp"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"

echo "==> Building release binary"
swift build -c release

echo "==> Assembling ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${EXECUTABLE_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

cp Resources/Info.plist "${APP_BUNDLE}/Contents/Info.plist"
cp Resources/RaptorIcon.png "${APP_BUNDLE}/Contents/Resources/RaptorIcon.png"

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "==> Done: ${APP_BUNDLE}"
echo "Run with: open ${APP_BUNDLE}"
