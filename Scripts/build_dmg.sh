#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=Scripts/artifact_publication.sh
source Scripts/artifact_publication.sh

APP_NAME="Brute"
APP_BUNDLE="${APP_NAME}.app"
RELEASE_BUILD="${BRUTE_RELEASE:-${MACMUTE_RELEASE:-0}}"
SIGNING_IDENTITY="${BRUTE_SIGNING_IDENTITY:-${MACMUTE_SIGNING_IDENTITY:--}}"
NOTARY_PROFILE="${BRUTE_NOTARY_PROFILE:-${MACMUTE_NOTARY_PROFILE:-}}"
WORK_DIR=""
STAGING_DIR=""
TEMP_DMG=""
TEMP_APP_BUNDLE=""
MOUNT_DIR=""
DMG_MOUNTED=0

cleanup() {
    local status=$? preserve_workspace=0
    if [[ "${DMG_MOUNTED}" == "1" && -n "${MOUNT_DIR}" ]]; then
        if ! hdiutil detach "${MOUNT_DIR}" >/dev/null; then
            preserve_workspace=1
        fi
    fi
    publication_finish "${status}" "${preserve_workspace}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

verify_installer_contents() {
    local image="$1"
    local assess_gatekeeper="${2:-0}"
    local mounted_revision
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
    lipo "${MOUNT_DIR}/${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" -verify_arch arm64
    lipo "${MOUNT_DIR}/${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" -verify_arch x86_64
    mounted_revision=$(/usr/libexec/PlistBuddy -c "Print :BruteSourceRevision" \
      "${MOUNT_DIR}/${APP_BUNDLE}/Contents/Info.plist")
    if [[ "${mounted_revision}" != "${APP_SOURCE_REVISION}" ]]; then
        echo "error: installer app revision does not match the staged app" >&2
        return 1
    fi
    hdiutil detach "${MOUNT_DIR}" >/dev/null
    DMG_MOUNTED=0
    rmdir "${MOUNT_DIR}"
    MOUNT_DIR=""
}

if [[ "${RELEASE_BUILD}" != "0" && "${RELEASE_BUILD}" != "1" ]]; then
    echo "error: BRUTE_RELEASE must be exactly 0 or 1" >&2
    exit 1
fi

if [[ "${RELEASE_BUILD}" == "1" && -z "${NOTARY_PROFILE}" ]]; then
    echo "error: release builds require BRUTE_NOTARY_PROFILE" >&2
    exit 1
fi

publication_begin "${APP_BUNDLE}" brute-dmg-build
WORK_DIR="${publication_workspace}"
TEMP_APP_BUNDLE="${WORK_DIR}/${APP_BUNDLE}"
STAGING_DIR="${WORK_DIR}/staging"

echo "==> Building verified temporary ${APP_BUNDLE}"
BRUTE_APP_OUTPUT="${TEMP_APP_BUNDLE}" ./Scripts/build_app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${TEMP_APP_BUNDLE}/Contents/Info.plist")
APP_SOURCE_REVISION=$(/usr/libexec/PlistBuddy -c "Print :BruteSourceRevision" "${TEMP_APP_BUNDLE}/Contents/Info.plist")
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
TEMP_DMG="${WORK_DIR}/${DMG_NAME}"

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
publish_artifact "${TEMP_APP_BUNDLE}" "${publication_app}"
publish_artifact "${TEMP_DMG}" "${publication_directory}/${DMG_NAME}"
publication_committed=1

echo "==> Done: ${DMG_NAME}"
echo "Open it and drag ${APP_BUNDLE} into Applications to install."
