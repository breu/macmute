#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="MacMute"
APP_BUNDLE="${APP_NAME}.app"
STAGING_DIR=".dmg_staging"

echo "==> Building ${APP_BUNDLE}"
./Scripts/build_app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_BUNDLE}/Contents/Info.plist")
DMG_NAME="${APP_NAME}-${VERSION}.dmg"

echo "==> Assembling installer image"
rm -rf "${STAGING_DIR}" "${DMG_NAME}"
mkdir -p "${STAGING_DIR}"

cp -R "${APP_BUNDLE}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

echo "==> Creating ${DMG_NAME}"
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov -format UDZO \
  "${DMG_NAME}"

rm -rf "${STAGING_DIR}"

echo "==> Done: ${DMG_NAME}"
echo "Open it and drag ${APP_BUNDLE} into Applications to install."
