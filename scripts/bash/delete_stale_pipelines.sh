#!/bin/bash
################################################################################
# Script: delete_stale_pipelines.sh
# Description: Deletes old GitLab CI/CD pipelines that are older than 1 month
#              to reduce clutter and storage usage. Uses GitLab REST API to
#              fetch all stale pipeline IDs first, then deletes them one by one
#              (deleting while paging would shift later pages).
# Usage: Called from scheduled CI/CD pipeline
# Dependencies: curl, jq
# Environment Variables Required:
#   - OWNER_PAT_VALUE: GitLab personal access token with API access
#   - CI_SERVER_HOST, CI_PROJECT_ID
################################################################################
set -euo pipefail

if [[ -z "${OWNER_PAT_VALUE:-}" ]]; then
    echo "ERROR: OWNER_PAT_VALUE is not set." >&2
    exit 1
fi

api_url="https://${CI_SERVER_HOST}/api/v4/projects/${CI_PROJECT_ID}/pipelines"
# 30 days ago, via jq rather than GNU-only `date -d`
updated_before=$(jq -rn 'now - 30 * 86400 | strftime("%Y-%m-%d")')
page=1
per_page=100
pipeline_ids=()

# Collect stale pipeline IDs. curl -f fails the job on any API error
# (401, 403, 429, ...) instead of looping forever on a non-array response.
while true; do
    response=$(curl -fsS --header "PRIVATE-TOKEN: ${OWNER_PAT_VALUE}" \
        "${api_url}?updated_before=${updated_before}T00:00:00Z&page=${page}&per_page=${per_page}")

    count=$(echo "$response" | jq 'length')
    if [[ "$count" -eq 0 ]]; then
        break
    fi

    while IFS= read -r id; do
        pipeline_ids+=("$id")
    done < <(echo "$response" | jq -r '.[].id')

    ((page++))
done

echo "Found ${#pipeline_ids[@]} pipeline(s) last updated before ${updated_before}."

failed=0
for id in "${pipeline_ids[@]}"; do
    echo "Attempting to delete pipeline $id"
    if ! curl -fsS --request DELETE --header "PRIVATE-TOKEN: ${OWNER_PAT_VALUE}" "${api_url}/${id}"; then
        echo "WARNING: Failed to delete pipeline $id" >&2
        failed=$((failed + 1))
    fi
done

if [[ "$failed" -gt 0 ]]; then
    echo "ERROR: Failed to delete $failed pipeline(s)." >&2
    exit 1
fi
