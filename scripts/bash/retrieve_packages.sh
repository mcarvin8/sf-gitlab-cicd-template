#!/bin/bash
################################################################################
# Script: retrieve_packages.sh
# Description: Retrieves Salesforce metadata from a specific org (sandbox or production)
#              into its Git branch based on package.xml definitions. Commits and
#              pushes changes. Sandbox-branch pushes skip CI (the metadata came
#              from that org, so there is nothing to deploy); default-branch pushes
#              run CI so prodBackfill merges them into the sandbox branches
#              (deploy:prd skips chore(metadata-retrieval) commits).
#              Optionally pre-purges force-app folders for specific metadata
#              types to ensure clean retrieval and remove destroyed metadata files.
# Usage: Called from CI/CD pipeline (one job per branch for parallel runs).
# Environment Variables Required:
#   - ORG_BRANCH: Git branch to commit retrieved metadata to
#   - AUTH_ALIAS: sf org alias set by the .authenticate template
#   - PACKAGE_NAME: XML file name from scripts/packages/ folder
#   - PREPURGE: Set to "true" to enable pre-purge of metadata folders
#   - DEPLOY_TIMEOUT: Wait time for retrieval operation
#   - MAINTAINER_PAT_NAME, MAINTAINER_PAT_USER_NAME, MAINTAINER_PAT_VALUE
#   - CI_COMMIT_SHORT_SHA
# Optional: GIT_REMOTE (default: origin), GIT_PUSH_MAX_ATTEMPTS (default: 5)
#
# Objects.xml: Before retrieve, builds manifest/package.xml from that branch's org
#   with only CustomObject (sf project generate manifest --metadata CustomObject) so the
#   CLI does not scan all org metadata types (avoids RegistryError on types like OAS Yaml Schema).
# Prerequisite: maintainer_git.sh sourced and setup_maintainer_git called
#   (done by the .maintainer-git CI template's before_script)
################################################################################
set -e

GIT_REMOTE="${GIT_REMOTE:-origin}"
branch_name="$ORG_BRANCH"
if [[ -z "$branch_name" ]]; then
    echo "ERROR: ORG_BRANCH must be set" >&2
    exit 1
fi

target_org="${AUTH_ALIAS:-$branch_name}"

# Sandbox branches skip CI on push; the default branch keeps it (see header)
push_options=()
if [[ "$branch_name" != "${CI_DEFAULT_BRANCH:-}" ]]; then
    push_options=(-o ci.skip)
fi

# Must fetch before checking out the git branch
git fetch -q

# metadataRegistry.json from the source-deploy-retrieve library bundled with the
# sf CLI, so no project npm install is needed. Resolved once before pre-purge.
registry_file=""
find_metadata_registry() {
    local sf_root
    sf_root=$(sf version --verbose --json 2>/dev/null | jq -r '.rootPath // empty')
    if [[ -n "$sf_root" ]]; then
        find "$sf_root" -path '*/source-deploy-retrieve/lib/src/registry/metadataRegistry.json' -print -quit 2>/dev/null
    fi
}

# Function to map metadata types to force-app folder names using metadataRegistry.json
get_folder_for_metadata_type() {
    local metadata_type=$1

    if [[ ! -f "$registry_file" ]]; then
        echo "Warning: metadataRegistry.json not found in the sf CLI install. Cannot lookup metadata type folder. Skipping pre-purge for '$metadata_type'." >&2
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
        --from-org "$target_org" \
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
    registry_file=$(find_metadata_registry)

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
    sf project retrieve start --manifest manifest/package.xml --target-org "$target_org" --ignore-conflicts --wait "$DEPLOY_TIMEOUT" 1>/dev/null
else
    sf project retrieve start --manifest manifest/package.xml --target-org "$target_org" --ignore-conflicts --wait "$DEPLOY_TIMEOUT"
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
        if git push "${push_options[@]}" origin "$branch_name"; then
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
