#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="MacMute"
EXECUTABLE_NAME="MacMuteApp"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"
RELEASE_BUILD="${MACMUTE_RELEASE:-0}"
SIGNING_IDENTITY="${MACMUTE_SIGNING_IDENTITY:--}"
WORK_DIR=""
TEMP_APP_BUNDLE=""
BACKUP_APP_BUNDLE=""
PUBLISHED=0

cleanup() {
    if [[ "${PUBLISHED}" != "1" && ! -e "${APP_BUNDLE}" && -n "${BACKUP_APP_BUNDLE}" && -e "${BACKUP_APP_BUNDLE}" ]]; then
        mv "${BACKUP_APP_BUNDLE}" "${APP_BUNDLE}"
    fi
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
        rm -rf "${WORK_DIR}"
    fi
}
trap cleanup EXIT

if [[ "${RELEASE_BUILD}" == "1" ]]; then
    if [[ "${SIGNING_IDENTITY}" != "Developer ID Application:"* ]] \
        || { [[ "${SIGNING_IDENTITY}" != *"BreuSoftware LLC"* ]] \
            && [[ "${SIGNING_IDENTITY}" != *"Breu Software LLC"* ]]; }; then
        echo "error: release builds require BreuSoftware LLC's full Developer ID Application identity" >&2
        echo "set MACMUTE_SIGNING_IDENTITY to the exact identity shown by security find-identity" >&2
        exit 1
    fi
    if ! security find-identity -v -p codesigning | grep -F -- "\"${SIGNING_IDENTITY}\"" >/dev/null; then
        echo "error: the requested BreuSoftware LLC signing identity is not available in this keychain" >&2
        exit 1
    fi
fi

echo "==> Building release binary"
swift build -c release

WORK_DIR="$(mktemp -d "$(pwd)/.macmute-app-build.XXXXXX")"
TEMP_APP_BUNDLE="${WORK_DIR}/${APP_BUNDLE}"
BACKUP_APP_BUNDLE="${WORK_DIR}/${APP_NAME}.previous.app"

echo "==> Assembling verified temporary ${APP_BUNDLE}"
mkdir -p "${TEMP_APP_BUNDLE}/Contents/MacOS"
mkdir -p "${TEMP_APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${EXECUTABLE_NAME}" "${TEMP_APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

cp Resources/Info.plist "${TEMP_APP_BUNDLE}/Contents/Info.plist"
cp Resources/RaptorIcon.png "${TEMP_APP_BUNDLE}/Contents/Resources/RaptorIcon.png"

echo "==> Generating app icon"
ICON_WORK_DIR="${WORK_DIR}/icon-work"
ICONSET_DIR="${ICON_WORK_DIR}/AppIcon.iconset"
mkdir -p "${ICONSET_DIR}"
for size in 16 32 128 256 512; do
    sips -z "${size}" "${size}" Resources/RaptorIcon.png --out "${ICONSET_DIR}/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "${double}" "${double}" Resources/RaptorIcon.png --out "${ICONSET_DIR}/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "${ICONSET_DIR}" -o "${TEMP_APP_BUNDLE}/Contents/Resources/AppIcon.icns"
if [[ "${RELEASE_BUILD}" == "1" ]]; then
    echo "==> Signing with BreuSoftware LLC Developer ID and hardened runtime"
    codesign \
      --force \
      --options runtime \
      --timestamp \
      --sign "${SIGNING_IDENTITY}" \
      "${TEMP_APP_BUNDLE}"
else
    echo "==> Ad-hoc signing local development build"
    codesign --force --sign - "${TEMP_APP_BUNDLE}"
fi

codesign --verify --strict --verbose=2 "${TEMP_APP_BUNDLE}"

echo "==> Publishing ${APP_BUNDLE}"
if [[ -e "${APP_BUNDLE}" ]]; then
    mv "${APP_BUNDLE}" "${BACKUP_APP_BUNDLE}"
fi
mv "${TEMP_APP_BUNDLE}" "${APP_BUNDLE}"
rm -rf "${BACKUP_APP_BUNDLE}"
PUBLISHED=1

echo "==> Done: ${APP_BUNDLE}"
echo "Run with: open ${APP_BUNDLE}"
