#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="MacMute"
APP_BUNDLE="${APP_NAME}.app"
RELEASE_BUILD="${MACMUTE_RELEASE:-0}"
SIGNING_IDENTITY="${MACMUTE_SIGNING_IDENTITY:--}"
NOTARY_PROFILE="${MACMUTE_NOTARY_PROFILE:-}"
WORK_DIR=""
STAGING_DIR=""
TEMP_DMG=""
BACKUP_DMG=""
PUBLISHED=0

cleanup() {
    if [[ "${PUBLISHED}" != "1" && -n "${DMG_NAME:-}" && ! -e "${DMG_NAME}" && -n "${BACKUP_DMG}" && -e "${BACKUP_DMG}" ]]; then
        mv "${BACKUP_DMG}" "${DMG_NAME}"
    fi
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
        rm -rf "${WORK_DIR}"
    fi
}
trap cleanup EXIT

if [[ "${RELEASE_BUILD}" == "1" && -z "${NOTARY_PROFILE}" ]]; then
    echo "error: release builds require MACMUTE_NOTARY_PROFILE" >&2
    exit 1
fi

echo "==> Building ${APP_BUNDLE}"
./Scripts/build_app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_BUNDLE}/Contents/Info.plist")
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
WORK_DIR="$(mktemp -d "$(pwd)/.macmute-dmg-build.XXXXXX")"
STAGING_DIR="${WORK_DIR}/staging"
TEMP_DMG="${WORK_DIR}/${DMG_NAME}"
BACKUP_DMG="${WORK_DIR}/${DMG_NAME}.previous"

echo "==> Assembling installer image"
mkdir -p "${STAGING_DIR}"

cp -R "${APP_BUNDLE}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

echo "==> Creating ${DMG_NAME}"
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov -format UDZO \
  "${TEMP_DMG}"

if [[ "${RELEASE_BUILD}" == "1" ]]; then
    echo "==> Signing installer with BreuSoftware LLC Developer ID"
    codesign --force --timestamp --sign "${SIGNING_IDENTITY}" "${TEMP_DMG}"
    codesign --verify --strict --verbose=2 "${TEMP_DMG}"

    echo "==> Notarizing installer"
    xcrun notarytool submit "${TEMP_DMG}" \
      --keychain-profile "${NOTARY_PROFILE}" \
      --wait
    xcrun stapler staple "${TEMP_DMG}"
    xcrun stapler validate "${TEMP_DMG}"
    spctl --assess --type open --context context:primary-signature --verbose=2 "${TEMP_DMG}"
fi

echo "==> Publishing ${DMG_NAME}"
if [[ -e "${DMG_NAME}" ]]; then
    mv "${DMG_NAME}" "${BACKUP_DMG}"
fi
mv "${TEMP_DMG}" "${DMG_NAME}"
rm -f "${BACKUP_DMG}"
PUBLISHED=1

echo "==> Done: ${DMG_NAME}"
echo "Open it and drag ${APP_BUNDLE} into Applications to install."
