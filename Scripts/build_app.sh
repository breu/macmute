#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="MacMute"
EXECUTABLE_NAME="MacMuteApp"
BUILD_DIR=".build/apple/Products/Release"
APP_BUNDLE="${MACMUTE_APP_OUTPUT:-${APP_NAME}.app}"
RELEASE_BUILD="${MACMUTE_RELEASE:-0}"
SIGNING_IDENTITY="${MACMUTE_SIGNING_IDENTITY:--}"
REQUESTED_TEAM_ID="${MACMUTE_TEAM_ID:-}"
TEAM_ID_FILE="Resources/BreuSoftwareTeamID.txt"
EXPECTED_TEAM_ID=""
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

repository_inputs_are_clean() {
    [[ -z "$(git status --porcelain --untracked-files=all -- Package.swift README.md Sources Tests Scripts Resources)" ]]
}

require_pristine_release_inputs() {
    if ! repository_inputs_are_clean; then
        echo "error: release builds require pristine tracked and untracked release inputs" >&2
        exit 1
    fi
    if ! git ls-files --error-unmatch -- "${TEAM_ID_FILE}" >/dev/null 2>&1; then
        echo "error: the pinned BreuSoftware Team ID file must be committed" >&2
        exit 1
    fi
}

if [[ "${RELEASE_BUILD}" != "0" && "${RELEASE_BUILD}" != "1" ]]; then
    echo "error: MACMUTE_RELEASE must be exactly 0 or 1" >&2
    exit 1
fi

if [[ "${RELEASE_BUILD}" == "1" ]]; then
    if [[ ! -f "${TEAM_ID_FILE}" ]]; then
        echo "error: missing pinned BreuSoftware Team ID file: ${TEAM_ID_FILE}" >&2
        exit 1
    fi
    EXPECTED_TEAM_ID=$(tr -d '[:space:]' < "${TEAM_ID_FILE}")
    if [[ ! "${EXPECTED_TEAM_ID}" =~ ^[A-Z0-9]{10}$ ]]; then
        echo "error: configure BreuSoftware's exact 10-character Team ID in ${TEAM_ID_FILE}" >&2
        exit 1
    fi
    if [[ -n "${REQUESTED_TEAM_ID}" && "${REQUESTED_TEAM_ID}" != "${EXPECTED_TEAM_ID}" ]]; then
        echo "error: MACMUTE_TEAM_ID does not match the repository-pinned BreuSoftware Team ID" >&2
        exit 1
    fi
    if [[ "${SIGNING_IDENTITY}" != "Developer ID Application: BreuSoftware LLC (${EXPECTED_TEAM_ID})" ]] \
        && [[ "${SIGNING_IDENTITY}" != "Developer ID Application: Breu Software LLC (${EXPECTED_TEAM_ID})" ]]; then
        echo "error: release builds require BreuSoftware LLC's full Developer ID Application identity" >&2
        echo "set MACMUTE_SIGNING_IDENTITY to the exact identity shown by security find-identity" >&2
        exit 1
    fi
    if ! security find-identity -v -p codesigning | grep -F -- "\"${SIGNING_IDENTITY}\"" >/dev/null; then
        echo "error: the requested BreuSoftware LLC signing identity is not available in this keychain" >&2
        exit 1
    fi
    require_pristine_release_inputs
fi

if [[ "${RELEASE_BUILD}" == "1" ]]; then
    echo "==> Running strict release tests"
    swift test --enable-code-coverage \
      -Xswiftc -strict-concurrency=complete \
      -Xswiftc -warn-concurrency \
      -Xswiftc -warnings-as-errors
    COVERAGE_JSON=$(swift test --show-codecov-path)
    swift Scripts/check_coverage.swift "${COVERAGE_JSON}" 45.0
    require_pristine_release_inputs
fi

echo "==> Building universal release binary"
swift build -c release --arch arm64 --arch x86_64 \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warn-concurrency \
  -Xswiftc -warnings-as-errors

if [[ "${RELEASE_BUILD}" == "1" ]]; then
    require_pristine_release_inputs
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macmute-app-build.XXXXXX")"
TEMP_APP_BUNDLE="${WORK_DIR}/${APP_NAME}.app"
BACKUP_APP_BUNDLE="${WORK_DIR}/${APP_NAME}.previous.app"
mkdir -p "$(dirname "${APP_BUNDLE}")"

echo "==> Assembling verified temporary ${APP_BUNDLE}"
mkdir -p "${TEMP_APP_BUNDLE}/Contents/MacOS"
mkdir -p "${TEMP_APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${EXECUTABLE_NAME}" "${TEMP_APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
lipo "${TEMP_APP_BUNDLE}/Contents/MacOS/${APP_NAME}" -verify_arch arm64 x86_64

cp Resources/Info.plist "${TEMP_APP_BUNDLE}/Contents/Info.plist"
cp Resources/RaptorIcon.png "${TEMP_APP_BUNDLE}/Contents/Resources/RaptorIcon.png"
SOURCE_REVISION=$(git rev-parse --verify HEAD 2>/dev/null || echo development)
if ! repository_inputs_are_clean 2>/dev/null; then
    SOURCE_REVISION="${SOURCE_REVISION}-dirty"
fi
/usr/libexec/PlistBuddy -c "Add :MacMuteSourceRevision string ${SOURCE_REVISION}" \
  "${TEMP_APP_BUNDLE}/Contents/Info.plist"

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
if [[ "${RELEASE_BUILD}" == "1" ]]; then
    require_pristine_release_inputs
    ACTUAL_TEAM_ID=$(codesign -dv --verbose=4 "${TEMP_APP_BUNDLE}" 2>&1 \
      | awk -F= '/^TeamIdentifier=/{print $2; exit}')
    if [[ "${ACTUAL_TEAM_ID}" != "${EXPECTED_TEAM_ID}" ]]; then
        echo "error: signed app TeamIdentifier '${ACTUAL_TEAM_ID}' does not match MACMUTE_TEAM_ID" >&2
        exit 1
    fi
fi

echo "==> Publishing ${APP_BUNDLE}"
if [[ -e "${APP_BUNDLE}" ]]; then
    mv "${APP_BUNDLE}" "${BACKUP_APP_BUNDLE}"
fi
mv "${TEMP_APP_BUNDLE}" "${APP_BUNDLE}"
PUBLISHED=1
rm -rf "${BACKUP_APP_BUNDLE}"

echo "==> Done: ${APP_BUNDLE}"
echo "Run with: open ${APP_BUNDLE}"
