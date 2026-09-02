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
TEMP_APP_BUNDLE=""
BACKUP_DMG=""
BACKUP_APP_BUNDLE=""
APP_REPLACED=0
DMG_REPLACED=0
PUBLISHED=0
MOUNT_DIR=""
DMG_MOUNTED=0

cleanup() {
    if [[ "${DMG_MOUNTED}" == "1" && -n "${MOUNT_DIR}" ]]; then
        hdiutil detach "${MOUNT_DIR}" >/dev/null 2>&1 || true
        DMG_MOUNTED=0
    fi
    if [[ "${PUBLISHED}" != "1" ]]; then
        if [[ "${APP_REPLACED}" == "1" && -e "${APP_BUNDLE}" ]]; then
            rm -rf "${APP_BUNDLE}"
        fi
        if [[ ! -e "${APP_BUNDLE}" && -n "${BACKUP_APP_BUNDLE}" && -e "${BACKUP_APP_BUNDLE}" ]]; then
            mv "${BACKUP_APP_BUNDLE}" "${APP_BUNDLE}"
        fi
        if [[ "${DMG_REPLACED}" == "1" && -n "${DMG_NAME:-}" && -e "${DMG_NAME}" ]]; then
            rm -f "${DMG_NAME}"
        fi
        if [[ -n "${DMG_NAME:-}" && ! -e "${DMG_NAME}" && -n "${BACKUP_DMG}" && -e "${BACKUP_DMG}" ]]; then
            mv "${BACKUP_DMG}" "${DMG_NAME}"
        fi
    fi
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
        rm -rf "${WORK_DIR}"
    fi
}
trap cleanup EXIT

verify_installer_contents() {
    local image="$1"
    local assess_gatekeeper="${2:-0}"
    MOUNT_DIR="${WORK_DIR}/mounted"
    mkdir -p "${MOUNT_DIR}"
    hdiutil attach -readonly -nobrowse -mountpoint "${MOUNT_DIR}" "${image}" >/dev/null
    DMG_MOUNTED=1
    [[ -d "${MOUNT_DIR}/${APP_BUNDLE}" ]] || {
        echo "error: installer is missing ${APP_BUNDLE}" >&2
        return 1
    }
    [[ -L "${MOUNT_DIR}/Applications" && "$(readlink "${MOUNT_DIR}/Applications")" == "/Applications" ]] || {
        echo "error: installer Applications link is missing or unsafe" >&2
        return 1
    }
    codesign --verify --strict --verbose=2 "${MOUNT_DIR}/${APP_BUNDLE}"
    if [[ "${assess_gatekeeper}" == "1" ]]; then
        spctl --assess --type execute --verbose=2 "${MOUNT_DIR}/${APP_BUNDLE}"
    fi
    lipo "${MOUNT_DIR}/${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" -verify_arch arm64 x86_64
    /usr/libexec/PlistBuddy -c "Print :MacMuteSourceRevision" \
      "${MOUNT_DIR}/${APP_BUNDLE}/Contents/Info.plist" >/dev/null
    hdiutil detach "${MOUNT_DIR}" >/dev/null
    DMG_MOUNTED=0
    rmdir "${MOUNT_DIR}"
    MOUNT_DIR=""
}

if [[ "${RELEASE_BUILD}" != "0" && "${RELEASE_BUILD}" != "1" ]]; then
    echo "error: MACMUTE_RELEASE must be exactly 0 or 1" >&2
    exit 1
fi

if [[ "${RELEASE_BUILD}" == "1" && -z "${NOTARY_PROFILE}" ]]; then
    echo "error: release builds require MACMUTE_NOTARY_PROFILE" >&2
    exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macmute-dmg-build.XXXXXX")"
TEMP_APP_BUNDLE="${WORK_DIR}/${APP_BUNDLE}"
STAGING_DIR="${WORK_DIR}/staging"

echo "==> Building verified temporary ${APP_BUNDLE}"
MACMUTE_APP_OUTPUT="${TEMP_APP_BUNDLE}" ./Scripts/build_app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${TEMP_APP_BUNDLE}/Contents/Info.plist")
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
TEMP_DMG="${WORK_DIR}/${DMG_NAME}"
BACKUP_DMG="${WORK_DIR}/${DMG_NAME}.previous"
BACKUP_APP_BUNDLE="${WORK_DIR}/${APP_NAME}.previous.app"

echo "==> Assembling installer image"
mkdir -p "${STAGING_DIR}"

cp -R "${TEMP_APP_BUNDLE}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

echo "==> Creating ${DMG_NAME}"
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov -format UDZO \
  "${TEMP_DMG}"
hdiutil verify "${TEMP_DMG}"
verify_installer_contents "${TEMP_DMG}"

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
    codesign --verify --strict --verbose=2 "${TEMP_DMG}"
    hdiutil verify "${TEMP_DMG}"
    verify_installer_contents "${TEMP_DMG}" 1
    spctl --assess --type open --context context:primary-signature --verbose=2 "${TEMP_DMG}"
fi

echo "==> Publishing ${DMG_NAME}"
if [[ -e "${APP_BUNDLE}" ]]; then
    mv "${APP_BUNDLE}" "${BACKUP_APP_BUNDLE}"
fi
if [[ -e "${DMG_NAME}" ]]; then
    mv "${DMG_NAME}" "${BACKUP_DMG}"
fi
mv "${TEMP_APP_BUNDLE}" "${APP_BUNDLE}"
APP_REPLACED=1
mv "${TEMP_DMG}" "${DMG_NAME}"
DMG_REPLACED=1
PUBLISHED=1
rm -rf "${BACKUP_APP_BUNDLE}"
rm -f "${BACKUP_DMG}"

echo "==> Done: ${DMG_NAME}"
echo "Open it and drag ${APP_BUNDLE} into Applications to install."
