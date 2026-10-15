#!/bin/bash
################################################################################
# Script: maintainer_git.sh
# Description: Shared git setup for jobs that push to the repo with the
#              maintainer PAT. Sourced by the .maintainer-git CI template
#              before the job script runs; scripts then push with plain
#              `git push origin <ref>`.
#              Config is passed through GIT_CONFIG_* env vars (git >= 2.31),
#              so nothing is written to .git/config and the token is never
#              expanded into config or command-line arguments.
# Usage:
#   source ./scripts/bash/maintainer_git.sh
#   setup_maintainer_git
#   source ./scripts/bash/<job-script>.sh
# Environment Variables Required:
#   - MAINTAINER_PAT_NAME, MAINTAINER_PAT_USER_NAME, MAINTAINER_PAT_VALUE
#   - CI_SERVER_HOST, CI_PROJECT_PATH
################################################################################

# Set git identity and route pushes to origin through the maintainer PAT.
# Fetches keep using origin's URL (the runner's job token).
setup_maintainer_git() {
    local v
    for v in MAINTAINER_PAT_NAME MAINTAINER_PAT_USER_NAME MAINTAINER_PAT_VALUE CI_SERVER_HOST CI_PROJECT_PATH; do
        if [[ -z "${!v:-}" ]]; then
            echo "ERROR: $v is not set." >&2
            return 1
        fi
    done

    local host_url="https://${CI_SERVER_HOST}"
    export GIT_CONFIG_COUNT=5
    export GIT_CONFIG_KEY_0="user.name"
    export GIT_CONFIG_VALUE_0="${MAINTAINER_PAT_NAME}"
    export GIT_CONFIG_KEY_1="user.email"
    export GIT_CONFIG_VALUE_1="${MAINTAINER_PAT_USER_NAME}@noreply.${CI_SERVER_HOST}"
    # Credential-free push URL, so git asks the credential helper below
    export GIT_CONFIG_KEY_2="remote.origin.pushurl"
    export GIT_CONFIG_VALUE_2="${host_url}/${CI_PROJECT_PATH}.git"
    # Empty value clears any helper configured earlier (e.g. by the runner)
    export GIT_CONFIG_KEY_3="credential.${host_url}.helper"
    export GIT_CONFIG_VALUE_3=""
    # Helper reads the token from the environment when git calls it
    export GIT_CONFIG_KEY_4="credential.${host_url}.helper"
    export GIT_CONFIG_VALUE_4='!f() { if [ "$1" = get ]; then echo username=oauth2; echo "password=${MAINTAINER_PAT_VALUE}"; fi; }; f'
}
