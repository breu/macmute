#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=Scripts/artifact_publication.sh
source Scripts/artifact_publication.sh
trap 'publication_finish "$?"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

APP_NAME="Brute"
EXECUTABLE_NAME="BruteApp"
BUILD_ARGS=(-c release --arch arm64 --arch x86_64)
APP_BUNDLE="${BRUTE_APP_OUTPUT:-${MACMUTE_APP_OUTPUT:-${APP_NAME}.app}}"
RELEASE_BUILD="${BRUTE_RELEASE:-${MACMUTE_RELEASE:-0}}"
SIGNING_IDENTITY="${BRUTE_SIGNING_IDENTITY:-${MACMUTE_SIGNING_IDENTITY:--}}"
REQUESTED_TEAM_ID="${BRUTE_TEAM_ID:-${MACMUTE_TEAM_ID:-}}"
TEAM_ID_FILE="Resources/BreuSoftwareTeamID.txt"
VERSION_FILE="Resources/Version.xcconfig"
EXPECTED_TEAM_ID=""

repository_inputs_are_clean() {
    local status
    status=$(git status --porcelain --untracked-files=all -- \
        Package.swift ':(glob)Package@swift-*.swift' Package.resolved .swiftpm .gitattributes \
        README.md Sources Tests Scripts Resources) || return 1
    [[ -z "${status}" ]]
}

read_version_setting() {
    local key="$1"
    local version
    local pattern='^[0-9]+(\.[0-9]+){0,2}$'
    version=$(awk -v key="${key}" '$1 == key && $2 == "=" && NF == 3 { print $3 }' "${VERSION_FILE}") || return 1
    if [[ "${RELEASE_BUILD}" == 1 && "${key}" == MARKETING_VERSION ]]; then
        pattern='^[0-9]+\.[0-9]+\.[0-9]+$'
    fi
    if [[ ! "${version}" =~ ${pattern} ]]; then
        echo "error: expected one numeric ${key} in ${VERSION_FILE}" >&2
        if [[ "${RELEASE_BUILD}" == 1 && "${key}" == MARKETING_VERSION ]]; then
            echo "use three components for the release marketing version (major.minor.patch)" >&2
        fi
        return 1
    fi
    printf '%s\n' "${version}"
}

require_pristine_release_inputs() {
    if ! repository_inputs_are_clean; then
        echo "error: release builds require pristine tracked and untracked release inputs" >&2
        exit 1
    fi
    if ! git cat-file -e "${SOURCE_REVISION}:${TEAM_ID_FILE}" 2>/dev/null; then
        echo "error: the pinned BreuSoftware Team ID file must be committed" >&2
        exit 1
    fi
}

if [[ "${RELEASE_BUILD}" != "0" && "${RELEASE_BUILD}" != "1" ]]; then
    echo "error: BRUTE_RELEASE must be exactly 0 or 1" >&2
    exit 1
fi

SOURCE_REVISION=$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null || echo development)
if [[ "${RELEASE_BUILD}" == "1" ]]; then
    if [[ "${SOURCE_REVISION}" == development ]]; then
        echo "error: release builds require a committed source revision" >&2
        exit 1
    fi
    require_pristine_release_inputs
elif ! repository_inputs_are_clean 2>/dev/null; then
    SOURCE_REVISION="${SOURCE_REVISION}-dirty"
fi

publication_begin "${APP_BUNDLE}" brute-app-build
APP_BUNDLE="${publication_app}"
WORK_DIR="${publication_workspace}"
TEMP_APP_BUNDLE="${WORK_DIR}/${APP_NAME}.app"

if [[ "${RELEASE_BUILD}" == "1" ]]; then
    echo "==> Staging committed source ${SOURCE_REVISION}"
    mkdir -- "${WORK_DIR}/source"
    # A checkout's info/attributes can omit files from git archive. Use the
    # commit's attributes in an isolated repository with no local templates.
    git clone --quiet --shared --no-checkout --template= -- . "${WORK_DIR}/source-repository"
    GIT_ATTR_NOSYSTEM=1 git -C "${WORK_DIR}/source-repository" -c core.attributesFile=/dev/null \
        archive --format=tar "${SOURCE_REVISION}" | tar -xf - -C "${WORK_DIR}/source"
    cd -- "${WORK_DIR}/source"
    # Keep all SwiftPM products with the snapshot even if the invoking shell
    # configured a shared build directory.
    unset SWIFTPM_BUILD_DIR

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
        echo "error: BRUTE_TEAM_ID does not match the repository-pinned BreuSoftware Team ID" >&2
        exit 1
    fi
    identity_pattern='^Developer ID Application: [^[:cntrl:]"]+ \(([A-Z0-9]{10})\)$'
    if [[ ! "${SIGNING_IDENTITY}" =~ ${identity_pattern} || "${BASH_REMATCH[1]}" != "${EXPECTED_TEAM_ID}" ]]; then
        echo "error: release builds require a full Developer ID Application identity for the pinned team" >&2
        echo "set BRUTE_SIGNING_IDENTITY to the exact identity shown by security find-identity" >&2
        exit 1
    fi
    if ! security find-identity -v -p codesigning | grep -F -- "\"${SIGNING_IDENTITY}\"" >/dev/null; then
        echo "error: the requested Developer ID signing identity is not available in this keychain" >&2
        exit 1
    fi
fi

MARKETING_VERSION=$(read_version_setting MARKETING_VERSION)
CURRENT_PROJECT_VERSION=$(read_version_setting CURRENT_PROJECT_VERSION)

if [[ "${RELEASE_BUILD}" == "1" ]]; then
    echo "==> Running strict release tests"
    bash Scripts/check_release.sh
fi

echo "==> Building universal release binary"
BUILD_DIR=$(swift build "${BUILD_ARGS[@]}" --show-bin-path)
swift build "${BUILD_ARGS[@]}" -Xswiftc -warnings-as-errors

echo "==> Assembling verified temporary ${APP_BUNDLE}"
mkdir -p "${TEMP_APP_BUNDLE}/Contents/MacOS"
mkdir -p "${TEMP_APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${EXECUTABLE_NAME}" "${TEMP_APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
lipo "${TEMP_APP_BUNDLE}/Contents/MacOS/${APP_NAME}" -verify_arch arm64
lipo "${TEMP_APP_BUNDLE}/Contents/MacOS/${APP_NAME}" -verify_arch x86_64

cp Resources/BruteHelp.html "${TEMP_APP_BUNDLE}/Contents/Resources/BruteHelp.html"
cp Resources/BrutePrivacy.html "${TEMP_APP_BUNDLE}/Contents/Resources/BrutePrivacy.html"
cp Resources/Info.plist "${TEMP_APP_BUNDLE}/Contents/Info.plist"
cp Resources/RaptorIcon.png "${TEMP_APP_BUNDLE}/Contents/Resources/RaptorIcon.png"
if [[ "${RELEASE_BUILD}" == 0 && "${SOURCE_REVISION}" != *-dirty ]]; then
    if ! repository_inputs_are_clean 2>/dev/null ||
       [[ "$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null || echo development)" != "${SOURCE_REVISION}" ]]; then
        SOURCE_REVISION="${SOURCE_REVISION}-dirty"
    fi
fi
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString ${MARKETING_VERSION}" \
  -c "Set :CFBundleVersion ${CURRENT_PROJECT_VERSION}" \
  -c "Add :BruteSourceRevision string ${SOURCE_REVISION}" \
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
    ACTUAL_TEAM_ID=$(codesign -dv --verbose=4 "${TEMP_APP_BUNDLE}" 2>&1 \
      | awk -F= '/^TeamIdentifier=/{print $2}')
    if [[ "${ACTUAL_TEAM_ID}" != "${EXPECTED_TEAM_ID}" ]]; then
        echo "error: signed app TeamIdentifier '${ACTUAL_TEAM_ID}' does not match BRUTE_TEAM_ID" >&2
        exit 1
    fi
fi

echo "==> Publishing ${APP_BUNDLE}"
publish_artifact "${TEMP_APP_BUNDLE}" "${APP_BUNDLE}"
publication_committed=1

echo "==> Done: ${APP_BUNDLE}"
echo "Run with: open ${APP_BUNDLE}"
