#!/bin/bash
################################################################################
# Script: promote_agent_mr.sh
# Description: For MRs opened into main by an AI triage agent's service
#              account (@svc-ai-triage-agent), automatically opens the two
#              companion MRs required by the 3-branch promotion path:
#                story branch -> develop
#                story branch -> fullqa
#              Without these, agent-authored work only lands in main and
#              skips the Common Dev and Full QA sandboxes.
#
#              Idempotent: if an open MR from the same source branch into
#              develop or fullqa already exists, that target is skipped.
#
# Usage: Called automatically from GitLab CI/CD on merge_request_event
#        pipelines whose target branch is main and whose author is
#        the AI agent's service account.
#
# Environment Variables Required:
#   - MAINTAINER_PAT_VALUE: GitLab PAT with api scope (same one used by
#       auto_merge.sh, refresh_sandbox_branches.sh, etc.)
#   - CI_API_V4_URL or CI_SERVER_HOST: GitLab API base
#   - CI_PROJECT_ID
#   - CI_MERGE_REQUEST_IID
#   - CI_MERGE_REQUEST_SOURCE_BRANCH_NAME
#   - CI_MERGE_REQUEST_TARGET_BRANCH_NAME
#
# Optional Environment Variables:
#   - AI_AGENT_USERNAME (default: svc-ai-triage-agent)
#   - AI_AGENT_PROMOTION_TARGETS (default: "develop fullqa")
################################################################################

set -euo pipefail

AI_AGENT_USERNAME="${AI_AGENT_USERNAME:-svc-ai-triage-agent}"
AI_AGENT_PROMOTION_TARGETS="${AI_AGENT_PROMOTION_TARGETS:-develop fullqa}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

require_var() {
    if [[ -z "${!1:-}" ]]; then
        print_error "$1 is not set."
        exit 1
    fi
}

require_var "MAINTAINER_PAT_VALUE"
require_var "CI_PROJECT_ID"
require_var "CI_MERGE_REQUEST_IID"
require_var "CI_MERGE_REQUEST_SOURCE_BRANCH_NAME"
require_var "CI_MERGE_REQUEST_TARGET_BRANCH_NAME"

if ! command -v jq >/dev/null 2>&1; then
    print_error "jq is required but not installed."
    exit 1
fi

# Resolve API base. Prefer CI_API_V4_URL (set by GitLab automatically),
# fall back to building it from CI_SERVER_HOST for parity with other scripts.
if [[ -n "${CI_API_V4_URL:-}" ]]; then
    API_BASE="${CI_API_V4_URL%/}"
else
    require_var "CI_SERVER_HOST"
    API_BASE="https://${CI_SERVER_HOST}/api/v4"
fi

PROJECT_API="${API_BASE}/projects/${CI_PROJECT_ID}"
SOURCE_BRANCH="$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME"
TARGET_BRANCH="$CI_MERGE_REQUEST_TARGET_BRANCH_NAME"

# Only act on MRs into main. The CI rule already gates this, but guard the
# script too so manual invocations cannot misfire into protected branches.
DEFAULT_BRANCH="${CI_DEFAULT_BRANCH:-main}"
if [[ "$TARGET_BRANCH" != "$DEFAULT_BRANCH" ]]; then
    print_warn "Target branch is '$TARGET_BRANCH', not '$DEFAULT_BRANCH'. Nothing to promote."
    exit 0
fi

# Refuse to promote from a long-lived branch. Story branches only.
case "$SOURCE_BRANCH" in
    main|develop|fullqa)
        print_error "Refusing to promote: source branch '$SOURCE_BRANCH' is a long-lived branch."
        exit 1
        ;;
esac

################################################################################
# Verify the MR author is the AI agent's service account.
# Defense in depth: the CI rule checks $GITLAB_USER_LOGIN, but that reflects
# whoever triggered the current pipeline, not necessarily the MR author on
# subsequent pushes. Confirm via the API.
################################################################################
print_info "Fetching MR !${CI_MERGE_REQUEST_IID} to verify author..."

MR_JSON=$(curl -sS --fail-with-body \
    --header "PRIVATE-TOKEN: ${MAINTAINER_PAT_VALUE}" \
    "${PROJECT_API}/merge_requests/${CI_MERGE_REQUEST_IID}") || {
        print_error "Failed to fetch MR !${CI_MERGE_REQUEST_IID}."
        exit 1
    }

MR_AUTHOR=$(echo "$MR_JSON" | jq -r '.author.username // empty')

if [[ -z "$MR_AUTHOR" ]]; then
    print_error "Could not determine MR author from API response."
    exit 1
fi

if [[ "$MR_AUTHOR" != "$AI_AGENT_USERNAME" ]]; then
    print_info "MR author is '$MR_AUTHOR', not '$AI_AGENT_USERNAME'. Skipping promotion."
    exit 0
fi

print_info "Confirmed MR author '$MR_AUTHOR'. Promoting '$SOURCE_BRANCH' to: $AI_AGENT_PROMOTION_TARGETS"

# Pull title/description from the original MR so the companions are recognizable.
ORIG_TITLE=$(echo "$MR_JSON" | jq -r '.title // ""')
ORIG_WEB_URL=$(echo "$MR_JSON" | jq -r '.web_url // ""')

################################################################################
# For each promotion target, ensure an open MR exists from SOURCE_BRANCH.
################################################################################
create_promotion_mr() {
    local target="$1"

    # Strip any team prefix like "[develop]" / "[fullqa]" that we may have
    # added on a prior run, then add the correct one for this target.
    local clean_title
    clean_title=$(echo "$ORIG_TITLE" | sed -E 's/^\[(develop|fullqa|main)\][[:space:]]*//I')
    local new_title="[${target}] ${clean_title}"

    # Look for an existing open MR from SOURCE_BRANCH -> target.
    local existing
    existing=$(curl -sS \
        --header "PRIVATE-TOKEN: ${MAINTAINER_PAT_VALUE}" \
        --get \
        --data-urlencode "state=opened" \
        --data-urlencode "source_branch=${SOURCE_BRANCH}" \
        --data-urlencode "target_branch=${target}" \
        "${PROJECT_API}/merge_requests")

    local existing_iid
    existing_iid=$(echo "$existing" | jq -r '.[0].iid // empty')

    if [[ -n "$existing_iid" ]]; then
        local existing_url
        existing_url=$(echo "$existing" | jq -r '.[0].web_url // empty')
        print_info "Promotion MR already exists for ${SOURCE_BRANCH} -> ${target}: !${existing_iid} (${existing_url})"
        return 0
    fi

    local description
    description=$(cat <<EOF
Automated companion MR for the 3-branch promotion path.

This MR was opened automatically because @${AI_AGENT_USERNAME} opened
${ORIG_WEB_URL} into \`${DEFAULT_BRANCH}\`. Per the repo's promotion model,
the same story branch must also be merged into \`develop\` and \`fullqa\`.

- Source: \`${SOURCE_BRANCH}\`
- Target: \`${target}\`
- Originating MR: ${ORIG_WEB_URL}

See \`AGENTS.md\` -> "Merge Request (MR) workflow requirements".
EOF
)

    print_info "Creating MR ${SOURCE_BRANCH} -> ${target}..."

    local payload
    payload=$(jq -n \
        --arg source "$SOURCE_BRANCH" \
        --arg target "$target" \
        --arg title  "$new_title" \
        --arg desc   "$description" \
        '{source_branch:$source, target_branch:$target, title:$title, description:$desc, remove_source_branch:false, squash:false}')

    local response http_code body
    response=$(curl -sS -w "\n%{http_code}" \
        --header "PRIVATE-TOKEN: ${MAINTAINER_PAT_VALUE}" \
        --header "Content-Type: application/json" \
        --request POST \
        --data "$payload" \
        "${PROJECT_API}/merge_requests")

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "201" ]]; then
        local new_iid new_url
        new_iid=$(echo "$body" | jq -r '.iid // empty')
        new_url=$(echo "$body" | jq -r '.web_url // empty')
        print_info "Created promotion MR !${new_iid}: ${new_url}"
        return 0
    fi

    # If branches are identical there's nothing to merge into that target yet;
    # that's not a failure for this automation.
    if echo "$body" | jq -e '.message | tostring | test("identical|already exists"; "i")' >/dev/null 2>&1; then
        print_warn "Skipping ${target}: ${body}"
        return 0
    fi

    print_error "Failed to create MR ${SOURCE_BRANCH} -> ${target} (HTTP ${http_code})"
    echo "$body" | head -20
    return 1
}

exit_code=0
for target in $AI_AGENT_PROMOTION_TARGETS; do
    if ! create_promotion_mr "$target"; then
        exit_code=1
    fi
done

exit $exit_code
