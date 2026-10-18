#!/bin/bash
################################################################################
# Script: notify.sh
# Description: Provider-agnostic chat notifications. Builds a message from a
#              neutral structure (status, title, text, fields) and posts it to
#              an incoming webhook in the format the configured provider expects.
# Usage: Source this script, then either:
#          send_notification <success|failure> <title> <text> [name value]...
#        or pass a neutral JSON message to notify_send_message:
#          {"status": "...", "title": "...", "text": "...",
#           "fields": [{"name": "...", "value": "..."}]}
# Dependencies: curl, jq
# Environment Variables:
#   - NOTIFY_WEBHOOK_URL: Incoming webhook URL; notifications are skipped when empty
#   - NOTIFY_PROVIDER: slack (default), teams, discord, googlechat, mattermost
#                      or generic
# Notes: Sourced into job shells, so it doesn't change shell options, and a
#        failed post only prints a warning (notifications never fail a job).
################################################################################

# Build the provider-specific payload from a neutral JSON message.
function notify_build_payload() {
    local provider="$1"
    local message="$2"

    case "${provider}" in
        slack)
            # Block Kit: header, optional text section, then label/value fields
            jq -c '
                (if .status == "success" then "✅" else "❌" end) as $icon
                | {
                    text: "\($icon) \(.title)",
                    blocks: (
                        [{type: "header", text: {type: "plain_text", text: "\($icon) \(.title)", emoji: true}}]
                        + (if (.text // "") != "" then [{type: "section", text: {type: "mrkdwn", text: .text}}] else [] end)
                        + (if (.fields | length) > 0 then
                            [{type: "section", fields: [.fields[] | {type: "mrkdwn", text: "*\(.name):*\n\(.value)"}]}]
                          else [] end)
                    )
                }' <<<"${message}"
            ;;
        teams)
            # Teams Workflows (Power Automate) webhook: Adaptive Card attachment
            jq -c '
                (if .status == "success" then "✅" else "❌" end) as $icon
                | {
                    type: "message",
                    attachments: [{
                        contentType: "application/vnd.microsoft.card.adaptive",
                        contentUrl: null,
                        content: {
                            "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                            type: "AdaptiveCard",
                            version: "1.4",
                            body: (
                                [{type: "TextBlock", text: "\($icon) \(.title)", weight: "Bolder", size: "Medium", wrap: true,
                                  color: (if .status == "success" then "Good" else "Attention" end)}]
                                + (if (.text // "") != "" then [{type: "TextBlock", text: .text, wrap: true}] else [] end)
                                + (if (.fields | length) > 0 then
                                    [{type: "FactSet", facts: [.fields[] | {title: .name, value: .value}]}]
                                  else [] end)
                            )
                        }
                    }]
                }' <<<"${message}"
            ;;
        discord)
            # Discord embed; empty descriptions and field values are rejected
            jq -c '
                (if .status == "success" then "✅" else "❌" end) as $icon
                | {
                    embeds: [(
                        {
                            title: "\($icon) \(.title)",
                            color: (if .status == "success" then 3061373 else 14687834 end),
                            fields: [.fields[] | {name: .name, value: (if .value == "" then "-" else .value end), inline: true}]
                        }
                        + (if (.text // "") != "" then {description: .text} else {} end)
                    )]
                }' <<<"${message}"
            ;;
        googlechat)
            # Google Chat text message (supports *bold* and auto-linked URLs)
            jq -c '
                (if .status == "success" then "✅" else "❌" end) as $icon
                | {
                    text: (
                        ["*\($icon) \(.title)*"]
                        + (if (.text // "") != "" then [.text] else [] end)
                        + [.fields[] | "*\(.name):* \(.value)"]
                        | join("\n")
                    )
                }' <<<"${message}"
            ;;
        mattermost)
            # Slack-compatible attachments (also accepted by Rocket.Chat)
            jq -c '
                (if .status == "success" then "✅" else "❌" end) as $icon
                | {
                    text: "\($icon) **\(.title)**",
                    attachments: [{
                        color: (if .status == "success" then "#2EB67D" else "#E01E5A" end),
                        text: (.text // ""),
                        fields: [.fields[] | {title: .name, value: .value, short: true}]
                    }]
                }' <<<"${message}"
            ;;
        generic)
            # Neutral message as-is, for custom receivers
            jq -c '.' <<<"${message}"
            ;;
        *)
            echo "Unsupported NOTIFY_PROVIDER '${provider}' (expected slack, teams, discord, googlechat, mattermost or generic)." >&2
            return 1
            ;;
    esac
}

# Post a neutral JSON message to NOTIFY_WEBHOOK_URL.
function notify_send_message() {
    local message="$1"
    local webhook="${NOTIFY_WEBHOOK_URL:-}"
    local provider="${NOTIFY_PROVIDER:-slack}"
    provider="${provider,,}"

    if [[ -z "${webhook}" ]]; then
        echo "NOTIFY_WEBHOOK_URL not set, skipping notification."
        return 0
    fi

    local payload
    if ! payload=$(notify_build_payload "${provider}" "${message}"); then
        echo "Warning: could not build ${provider} notification payload."
        return 0
    fi

    if ! curl -sS --fail -X POST \
        -H "Content-Type: application/json" \
        --data "${payload}" \
        "${webhook}"; then
        echo "Warning: ${provider} notification failed."
    fi
    echo
}

# Build a neutral message from arguments and post it.
# Usage: send_notification <success|failure> <title> <text> [name value]...
function send_notification() {
    local status="$1"
    local title="$2"
    local text="$3"
    shift 3

    local fields="[]"
    while [[ $# -ge 2 ]]; do
        fields=$(jq -c --arg name "$1" --arg value "$2" '. + [{name: $name, value: $value}]' <<<"${fields}")
        shift 2
    done

    local message
    message=$(jq -n -c \
        --arg status "${status}" \
        --arg title "${title}" \
        --arg text "${text}" \
        --argjson fields "${fields}" \
        '{status: $status, title: $title, text: $text, fields: $fields}')

    notify_send_message "${message}"
}
