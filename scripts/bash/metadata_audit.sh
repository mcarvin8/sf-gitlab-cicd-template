#!/bin/bash
################################################################################
# Script: metadata_audit.sh
# Description:
#   Weekly metadata audit: for each configured team, runs the sf-git-ai-meta-insights
#   plugin (OpenAI-compatible LLM) against the past week of commits filtered by
#   Jira key pattern, then uploads the generated Markdown summary to Confluence.
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
#   # Teams (space-separated; each entry is "team" or "team:jira-regex")
#   - METADATA_AUDIT_TEAMS    # e.g. "backend frontend:fe- platform" — team name is
#                             # used as the output filename; jira-regex filters commits.
#                             # When no colon is given, team name is used as the regex.
#
#   # Confluence
#   - CONFLUENCE_USER
#   - CONFLUENCE_TOKEN
#   - CONFLUENCE_PAGE_ID
#   - CONFLUENCE_BASE_URL     # e.g. https://yourorg.atlassian.net
#
#   # LLM — set credentials for your chosen provider; the plugin auto-detects from env vars.
#   #        Set LLM_PROVIDER explicitly to force a specific provider.
#   #
#   #  Provider              Credential env var(s)
#   #  openai                OPENAI_API_KEY or LLM_API_KEY
#   #  openai-compatible     LLM_BASE_URL (required); LLM_DEFAULT_HEADERS (optional)
#   #  anthropic             ANTHROPIC_API_KEY
#   #  google                GOOGLE_GENERATIVE_AI_API_KEY or GOOGLE_API_KEY
#   #  bedrock               Standard AWS credential chain (env / profile / role)
#   #  mistral               MISTRAL_API_KEY
#   #  cohere                COHERE_API_KEY
#   #  groq                  GROQ_API_KEY
#   #  xai                   XAI_API_KEY
#   #  deepseek              DEEPSEEK_API_KEY
#
# Optional:
#   - LLM_PROVIDER                    # force a specific provider (see table above)
#   - METADATA_AUDIT_FAIL_ON_ERROR=1  # exit if the plugin fails for any team (default: warn and continue)
#   - METADATA_AUDIT_TO=origin/main   # end ref for summarize (default: origin/main)
################################################################################

# --- Required env var checks ---------------------------------------------------

: "${METADATA_AUDIT_TEAMS:?Must set METADATA_AUDIT_TEAMS (space-separated team or team:regex entries)}"

: "${CONFLUENCE_USER:?Must set CONFLUENCE_USER}"
: "${CONFLUENCE_TOKEN:?Must set CONFLUENCE_TOKEN}"
: "${CONFLUENCE_PAGE_ID:?Must set CONFLUENCE_PAGE_ID}"
: "${CONFLUENCE_BASE_URL:?Must set CONFLUENCE_BASE_URL (e.g. https://yourorg.atlassian.net)}"


METADATA_AUDIT_TO="${METADATA_AUDIT_TO:-origin/main}"

# Parse METADATA_AUDIT_TEAMS into an associative array of team -> jira regex.
# Each entry is "team" (regex defaults to team name) or "team:regex".
declare -A TEAM_JIRA_REGEX=()
for entry in $METADATA_AUDIT_TEAMS; do
  if [[ "$entry" == *:* ]]; then
    TEAM_JIRA_REGEX["${entry%%:*}"]="${entry#*:}"
  else
    TEAM_JIRA_REGEX["$entry"]="$entry"
  fi
done

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

for team in "${!TEAM_JIRA_REGEX[@]}"; do
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
    if [[ "${METADATA_AUDIT_FAIL_ON_ERROR:-}" == "1" ]]; then
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
