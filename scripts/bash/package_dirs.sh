#!/bin/bash
################################################################################
# Script: package_dirs.sh
# Description: Reads the package directories declared in sfdx-project.json so
#              scripts don't hardcode force-app/main/default.
# Usage: Source this script, then call:
#          sf_package_dirs         - every packageDirectories[].path, one per line
#          sf_default_package_dir  - the default package directory (else the first)
#          sf_metadata_type_dir <package_dir> <directoryName>
#                                  - the folder for a metadata type inside a
#                                    package directory, checking the standard
#                                    <dir>/main/default/<type> layout then <dir>/<type>
# Dependencies: jq
# Environment Variables:
#   - SFDX_PROJECT_FILE: Project file to read (default: sfdx-project.json)
################################################################################

# tr strips the CRs a Windows jq build emits, so the helpers also work locally
function sf_package_dirs() {
    jq -r '.packageDirectories[].path | sub("/+$"; "")' "${SFDX_PROJECT_FILE:-sfdx-project.json}" | tr -d '\r'
}

function sf_default_package_dir() {
    jq -r '((.packageDirectories[] | select(.default == true) | .path) // .packageDirectories[0].path) | sub("/+$"; "")' \
        "${SFDX_PROJECT_FILE:-sfdx-project.json}" | tr -d '\r' | head -1
}

function sf_metadata_type_dir() {
    local package_dir="$1"
    local type_dir="$2"

    if [[ -d "${package_dir}/main/default/${type_dir}" ]]; then
        echo "${package_dir}/main/default/${type_dir}"
    elif [[ -d "${package_dir}/${type_dir}" ]]; then
        echo "${package_dir}/${type_dir}"
    fi
}
