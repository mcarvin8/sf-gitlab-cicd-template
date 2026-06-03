#!/bin/bash
################################################################################
# Script: retrieve_packages.sh
# Description: Retrieves Salesforce metadata from a specific org (sandbox or production)
#              into its Git branch based on package.xml definitions. Commits and
#              pushes changes.
#              Optionally pre-purges force-app folders for specific metadata
#              types to ensure clean retrieval and remove destroyed metadata files.
# Usage: Called from CI/CD pipeline (one job per branch for parallel runs).
# Environment Variables Required:
#   - ORG_BRANCH: Git branch / sf org alias
#   - PACKAGE_NAME: XML file name from scripts/packages/ folder
#   - PREPURGE: Set to "true" to enable pre-purge of metadata folders
#   - DEPLOY_TIMEOUT: Wait time for retrieval operation
#   - MAINTAINER_PAT_NAME, MAINTAINER_PAT_VALUE
#   - CI_COMMIT_SHORT_SHA
# Optional: GIT_REMOTE (default: origin), GIT_PUSH_MAX_ATTEMPTS (default: 5)
#
# Objects.xml: Before retrieve, builds manifest/package.xml from that branch's org
#   with only CustomObject (sf project generate manifest --metadata CustomObject) so the
#   CLI does not scan all org metadata types (avoids RegistryError on types like OAS Yaml Schema).
################################################################################
set -e

GIT_REMOTE="${GIT_REMOTE:-origin}"
branch_name="$ORG_BRANCH"
if [[ -z "$branch_name" ]]; then
    echo "ERROR: ORG_BRANCH must be set" >&2
    exit 1
fi

# Must fetch before checking out the git branch
git fetch -q
git config user.name "${MAINTAINER_PAT_NAME}"
git config user.email "${MAINTAINER_PAT_USER_NAME}@noreply.${CI_SERVER_HOST}"

# Function to map metadata types to force-app folder names using metadataRegistry.json
get_folder_for_metadata_type() {
    local metadata_type=$1
    local registry_file="scripts/registry/metadataRegistry.json"

    if [[ ! -f "$registry_file" ]]; then
        echo ""
        return
    fi

    if ! command -v jq &> /dev/null; then
        echo "Warning: jq not found, cannot lookup metadata type folder. Falling back to empty string." >&2
        echo ""
        return
    fi

    local folder_name
    folder_name=$(jq -r --arg type "$metadata_type" '
        .types | to_entries[] |
        select((.value.name | ascii_downcase) == ($type | ascii_downcase)) |
        .value.directoryName
    ' "$registry_file" 2>/dev/null | head -1)

    if [[ -n "$folder_name" && "$folder_name" != "null" ]]; then
        echo "$folder_name"
    else
        echo ""
    fi
}

git checkout -q "$branch_name"
git pull --ff -q
mkdir -p manifest
if [[ "$PACKAGE_NAME" == "Objects.xml" ]]; then
    echo "Objects.xml: generating manifest/package.xml (CustomObject only) from '${branch_name}'..."
    sf project generate manifest \
        --from-org "$branch_name" \
        --metadata CustomObject \
        --output-dir manifest \
        --type package
    if [[ ! -f manifest/package.xml ]]; then
        echo "ERROR: Expected manifest/package.xml after sf project generate manifest." >&2
        exit 1
    fi
else
    cp -f "scripts/packages/$PACKAGE_NAME" "manifest/package.xml"
fi

if [[ "$PREPURGE" == "true" ]]; then
    echo "Pre-purging force-app folders for metadata types in $PACKAGE_NAME..."

    metadata_types=$(grep -oP '(?<=<name>)[^<]+(?=</name>)' "scripts/packages/$PACKAGE_NAME" || true)

    while IFS= read -r metadata_type; do
        if [ -n "$metadata_type" ]; then
            folder=$(get_folder_for_metadata_type "$metadata_type")
            if [ -n "$folder" ]; then
                folder_path="force-app/main/default/$folder"
                if [ -d "$folder_path" ]; then
                    echo "  Removing $folder_path..."
                    rm -rf "$folder_path"
                fi
            fi
        fi
    done <<< "$metadata_types"
else
    echo "Skipping pre-purge for $PACKAGE_NAME"
fi

echo "Retrieving metadata defined in $PACKAGE_NAME from $branch_name..."
if [[ "$PACKAGE_NAME" == "Objects.xml" ]]; then
    sf project retrieve start --manifest manifest/package.xml --target-org "$branch_name" --ignore-conflicts --wait "$DEPLOY_TIMEOUT" 1>/dev/null
else
    sf project retrieve start --manifest manifest/package.xml --target-org "$branch_name" --ignore-conflicts --wait "$DEPLOY_TIMEOUT"
fi
git add --renormalize force-app/ 2>/dev/null || true
if [[ -n $(git status --porcelain force-app/) ]]; then
    echo "Changes found in the force-app directory..."
    git add force-app
    git commit -m "chore(metadata-retrieval): $PACKAGE_NAME @ $branch_name"

    # Job-only manifest changes must not block rebase; drop them (pipeline Git supports git restore).
    rm -rf manifest/

    max_push_attempts="${GIT_PUSH_MAX_ATTEMPTS:-5}"
    attempt=1
    while [[ "$attempt" -le "$max_push_attempts" ]]; do
        if git push "https://${MAINTAINER_PAT_NAME}:${MAINTAINER_PAT_VALUE}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"; then
            break
        fi
        if [[ "$attempt" -eq "$max_push_attempts" ]]; then
            echo "ERROR: git push failed after $max_push_attempts attempts." >&2
            exit 1
        fi
        echo "Push rejected; rebasing onto ${GIT_REMOTE}/${branch_name} and retrying ($attempt/$max_push_attempts)..." >&2
        git pull --rebase "$GIT_REMOTE" "$branch_name" || exit 1
        attempt=$((attempt + 1))
    done
else
    echo "There are no changes in the force-app directory on $branch_name."
fi
rm -rf manifest
git reset --hard

git -c advice.detachedHead=false checkout -q "$CI_COMMIT_SHORT_SHA"
git branch -D "$branch_name"
