#!/bin/bash
################################################################################
# Script: metadata_audit.sh
# Description:
#   Weekly metadata audit: for each tracked team, runs the sf-git-ai-meta-insights
#   plugin (OpenAI-compatible LLM) against ALFA using environment variables, then
#   uploads the generated Markdown summary to Confluence.
#
#   One `git log origin/main` resolves the FROM ref (last commit strictly before
#   one week ago). The plugin is invoked once per team with --commit-message-include
#   set to that team's Jira project key pattern.
#
# Usage:
#   Called from a scheduled CI/CD pipeline (e.g., weekly)
#
# Dependencies:
#   - git
#   - Salesforce CLI (sf) with plugin: sf-git-ai-meta-insights
#   - Node.js 20+ (required by the plugin)
#   - curl
#   - jq
#
# Required Environment Variables:
#   # Confluence
#   - CONFLUENCE_USER
#   - CONFLUENCE_TOKEN
#   - CONFLUENCE_PAGE_ID      # e.g. 638886675099 (Metadata Manifest Audits 2026)
#
#   # ALFA → LLM_BASE_URL and LLM_DEFAULT_HEADERS for sf-git-ai-meta-insights
#   - ALFA_PROJECT_UUID       # inserted as Authorization: sk-<ALFA_PROJECT_UUID>
#   - ALFA_PAT_TOKEN          # inserted as x-alfa-rbac (RBAC token from ALFA)
#   - ALFA_PROXY_URL          # required unless LLM_BASE_URL is set; script uses <ALFA_PROXY_URL>/v1
#
# Optional:
#   - LLM_BASE_URL            # if set, used as-is (else ${ALFA_PROXY_URL}/v1)
#   - METADATA_AUDIT_FAIL_ON_ALFA_ERROR=1  # exit if the plugin fails for any team
#   - METADATA_AUDIT_TO=origin/main        # end ref for summarize (default: origin/main)
#
# Teams Tracked (Jira key patterns for -m):
#   q2c, leadz, sfxpro, storm, shield
################################################################################

# --- Required env var checks ---------------------------------------------------

: "${CONFLUENCE_USER:?Must set CONFLUENCE_USER}"
: "${CONFLUENCE_TOKEN:?Must set CONFLUENCE_TOKEN}"
: "${CONFLUENCE_PAGE_ID:?Must set CONFLUENCE_PAGE_ID}"
: "${CONFLUENCE_BASE_URL:?Must set CONFLUENCE_BASE_URL (e.g. https://yourorg.atlassian.net)}"

: "${ALFA_PROJECT_UUID:?Must set ALFA_PROJECT_UUID (Authorization sk-<uuid>)}"
: "${ALFA_PAT_TOKEN:?Must set ALFA_PAT_TOKEN (x-alfa-rbac)}"

# LLM_BASE_URL: explicit override, else ALFA proxy
if [[ -n "${LLM_BASE_URL:-}" ]]; then
  export LLM_BASE_URL="${LLM_BASE_URL%/}"
else
  : "${ALFA_PROXY_URL:?Must set ALFA_PROXY_URL or LLM_BASE_URL}"
  ALFA_PROXY_URL="${ALFA_PROXY_URL%/}"
  export LLM_BASE_URL="${ALFA_PROXY_URL}"
fi

# LLM_DEFAULT_HEADERS: Authorization sk-<project uuid>, RBAC token in x-alfa-rbac
# (matches PowerShell: '{"x-alfa-rbac":"<pat>","Authorization":"sk-<uuid>"}')
# When debugging in Bash, print with: printf '%s\n' "$LLM_DEFAULT_HEADERS"
# Do not use: echo $LLM_DEFAULT_HEADERS  (unquoted — JSON starts with { and Bash applies brace expansion)
export LLM_DEFAULT_HEADERS
LLM_DEFAULT_HEADERS="$(jq -nc --arg rbac "$ALFA_PAT_TOKEN" --arg uuid "$ALFA_PROJECT_UUID" '{"x-alfa-authorization": $rbac, "Authorization": ("Bearer sk-" + $uuid)}')"

METADATA_AUDIT_TO="${METADATA_AUDIT_TO:-origin/main}"

# Jira project key patterns (regex, OR within --commit-message-include per run)
declare -A TEAM_JIRA_REGEX=(
  ["q2c"]="q2c"
  ["leadz"]="leadz"
  ["sfxpro"]="sfxpro"
  ["storm"]="storm"
  ["shield"]="shield"
  ["avatechtdr"]="avatechtdr"
)

# --- Git setup ----------------------------------------------------------------

git fetch -q
git fetch origin main

# Single git log on origin/main: FROM = newest commit strictly older than 1 week ago
FROM=$(git log origin/main -1 --before="1 week ago" --pretty=format:%H)
if [[ -z "$FROM" ]]; then
  echo "ERROR: Could not resolve FROM via: git log origin/main -1 --before=\"1 week ago\""
  echo "       Check shallow clone depth or branch history."
  exit 1
fi

FROM_SUBJECT=$(git log -1 --pretty=format:%s "$FROM" 2>/dev/null || echo "")
echo "Resolved weekly window: FROM=${FROM}"
echo "  (subject: ${FROM_SUBJECT})"
echo "  TO=${METADATA_AUDIT_TO}"

timestamp=$(date +"%Y-%m-%d")

# --- Per-team: plugin summarize → Confluence ----------------------------------

for team in q2c leadz sfxpro storm shield avatechtdr; do
  jira_regex="${TEAM_JIRA_REGEX[$team]}"
  summary_file="${team}-summary-${timestamp}.md"

  echo
  echo "============================================================"
  echo "Processing team: ${team} (--commit-message-include '${jira_regex}')"
  echo "============================================================"

  if ! sf sgai metadata summarize \
    --from "$FROM" \
    --to "$METADATA_AUDIT_TO" \
    --commit-message-include "$jira_regex" \
    --team "$team" \
    --output "$summary_file" --ignore-whitespace \
    --model "o4-mini"; then
    echo "WARNING: sf sgai metadata summarize failed for team '${team}'." >&2
    if [[ "${METADATA_AUDIT_FAIL_ON_ALFA_ERROR:-}" == "1" ]]; then
      exit 1
    fi
    continue
  fi

  if [[ ! -s "$summary_file" ]]; then
    echo "WARNING: No summary output at ${summary_file} for team '${team}'; skipping Confluence upload."
    continue
  fi

  echo "Uploading AI summary ${summary_file} to Confluence page ${CONFLUENCE_PAGE_ID}..."
  curl -sS -u "$CONFLUENCE_USER:$CONFLUENCE_TOKEN" \
    -X PUT \
    -H "X-Atlassian-Token: nocheck" \
    -F "file=@${summary_file}" \
    -F 'minorEdit=true' \
    "${CONFLUENCE_BASE_URL}/wiki/rest/api/content/${CONFLUENCE_PAGE_ID}/child/attachment" \
    >/dev/null || echo "WARNING: Failed to upload ${summary_file} for team ${team}"
done

echo
echo "Metadata audit summaries complete."
