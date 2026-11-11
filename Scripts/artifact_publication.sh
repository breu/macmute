#!/bin/bash

# Sourced by the app and DMG builders. Each publication holds the lock for its
# app destination and keeps candidates and backups on the destination volume.
publication_workspace=""
publication_lock=""
publication_count=0
publication_committed=0
publication_targets=()
publication_backups=()
publication_install_started=()

publication_path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

publication_begin() {
    local destination="$1" staging_prefix="$2"
    local parent name lock
    parent=$(dirname -- "${destination}")
    name=$(basename -- "${destination}")
    case "${name}" in
        ''|.|..|/) echo "error: invalid app output path: ${destination}" >&2; return 1 ;;
    esac
    mkdir -p -- "${parent}"
    publication_directory=$(cd -- "${parent}" && pwd -P)
    # Read by the scripts sourcing this helper.
    # shellcheck disable=SC2034
    publication_app="${publication_directory}/${name}"
    lock="${publication_directory}/brute-app-build.${name}.lock"
    if ! mkdir -- "${lock}"; then
        echo "error: could not acquire publication lock at ${lock}" >&2
        return 1
    fi
    publication_lock="${lock}"
    publication_workspace=$(mktemp -d "${publication_directory}/${staging_prefix}.XXXXXX")
    mkdir -- "${publication_workspace}/previous"
}

publish_artifact() {
    local candidate="$1" target="$2"
    local index="${publication_count}" backup
    backup="${publication_workspace}/previous/$(basename -- "${target}")"
    publication_targets[index]="${target}"
    publication_backups[index]="${backup}"
    publication_install_started[index]=0
    publication_count=$((publication_count + 1))
    if publication_path_exists "${target}"; then
        mv -- "${target}" "${backup}"
    fi
    publication_install_started[index]=1
    mv -- "${candidate}" "${target}"
}

publication_finish() {
    local status="$1" preserve_workspace="${2:-0}"
    local index target backup
    if [[ "${publication_committed}" == 0 ]]; then
        for ((index=publication_count - 1; index >= 0; index--)); do
            target="${publication_targets[index]}"
            backup="${publication_backups[index]}"
            if [[ "${publication_install_started[index]}" == 1 ]] &&
               publication_path_exists "${target}" &&
               ! rm -rf -- "${target}"; then
                preserve_workspace=1
            fi
            if publication_path_exists "${backup}" &&
               { publication_path_exists "${target}" || ! mv -- "${backup}" "${target}"; }; then
                echo "error: could not restore ${target}; backup retained at ${backup}" >&2
                preserve_workspace=1
            fi
        done
    fi
    if [[ "${preserve_workspace}" == 1 ]]; then
        echo "error: publication staging retained at ${publication_workspace}" >&2
        status=1
    elif [[ -n "${publication_workspace}" ]]; then
        rm -rf -- "${publication_workspace}" || status=1
    fi
    if [[ -n "${publication_lock}" ]]; then
        rmdir -- "${publication_lock}" || status=1
    fi
    exit "${status}"
}
