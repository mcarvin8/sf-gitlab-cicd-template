#!/bin/bash
################################################################################
# Script: authenticate.sh
# Description: Authorizes the job's Salesforce org with the method in
#              AUTH_METHOD and sets it as the default org under AUTH_ALIAS.
#                jwt          - JWT bearer flow (external client app / connected
#                               app with a certificate)
#                sfdx-url     - Salesforce DX auth URL
#                               (force://<clientId>:<clientSecret>:<refreshToken>@<instanceUrl>,
#                               from `sf org display --verbose`)
#                access-token - existing access token, e.g. issued by an external
#                               secret manager; expires with the session
# Usage: Sourced by the .authenticate CI template
# Dependencies: Salesforce CLI (sf)
# Environment Variables (set per org by orgs/org.yml):
#   - AUTH_METHOD: jwt (default), sfdx-url or access-token
#   - AUTH_ALIAS: sf org alias
#   - jwt:          AUTH_CLIENT_ID, AUTH_JWT_KEY_FILE, AUTH_USERNAME, AUTH_INSTANCE_URL
#   - sfdx-url:     AUTH_SFDX_URL (File variable path, or the URL itself)
#   - access-token: AUTH_ACCESS_TOKEN, AUTH_INSTANCE_URL
################################################################################

function require_auth_vars() {
    local missing=()
    local name
    for name in "$@"; do
        if [[ -z "${!name:-}" ]]; then
            missing+=("${name}")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: AUTH_METHOD '${AUTH_METHOD:-jwt}' requires ${missing[*]} (set the org's <ALIAS>_* CI/CD variables, see .gitlab/workflows/orgs/README.md)." >&2
        return 1
    fi
}

function authenticate_org() {
    local method="${AUTH_METHOD:-jwt}"

    case "${method}" in
        jwt)
            require_auth_vars AUTH_CLIENT_ID AUTH_JWT_KEY_FILE AUTH_USERNAME AUTH_INSTANCE_URL || return 1
            sf org login jwt --client-id "${AUTH_CLIENT_ID}" --jwt-key-file "${AUTH_JWT_KEY_FILE}" \
                --username "${AUTH_USERNAME}" --instance-url "${AUTH_INSTANCE_URL}" \
                --set-default --alias "${AUTH_ALIAS}"
            ;;
        sfdx-url)
            require_auth_vars AUTH_SFDX_URL || return 1
            if [[ -f "${AUTH_SFDX_URL}" ]]; then
                sf org login sfdx-url --sfdx-url-file "${AUTH_SFDX_URL}" --set-default --alias "${AUTH_ALIAS}"
            else
                # Variable holds the URL itself: hand it to the CLI via a private temp file
                local url_file status
                url_file=$(mktemp)
                chmod 600 "${url_file}"
                printf '%s' "${AUTH_SFDX_URL}" > "${url_file}"
                sf org login sfdx-url --sfdx-url-file "${url_file}" --set-default --alias "${AUTH_ALIAS}"
                status=$?
                rm -f "${url_file}"
                return "${status}"
            fi
            ;;
        access-token)
            require_auth_vars AUTH_ACCESS_TOKEN AUTH_INSTANCE_URL || return 1
            SF_ACCESS_TOKEN="${AUTH_ACCESS_TOKEN}" sf org login access-token \
                --instance-url "${AUTH_INSTANCE_URL}" --no-prompt \
                --set-default --alias "${AUTH_ALIAS}"
            ;;
        *)
            echo "ERROR: Unsupported AUTH_METHOD '${method}' (expected jwt, sfdx-url or access-token)." >&2
            return 1
            ;;
    esac
}

authenticate_org
