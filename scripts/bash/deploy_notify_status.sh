#!/bin/bash
################################################################################
# Script: deploy_notify_status.sh
# Description: Sends a chat notification for deployment status (success or
#              failure) with details about the deployment including
#              environment, user, and links to job/commit.
# Usage: Source this script and call share_deploy_status function
# Dependencies: curl, jq, scripts/bash/notify.sh
# Environment Variables Required:
#   - NOTIFY_WEBHOOK_URL: Incoming webhook URL (empty skips the notification)
#   - NOTIFY_PROVIDER: slack (default), teams, discord, googlechat, mattermost, generic
#   - CI_ENVIRONMENT_NAME, CI_JOB_STATUS, CI_JOB_STAGE
#   - GITLAB_USER_NAME, CI_COMMIT_MESSAGE
#   - CI_JOB_URL, CI_PROJECT_URL, CI_COMMIT_SHA
################################################################################

source ./scripts/bash/notify.sh

# Function to send the deployment status notification
function share_deploy_status() {
    local status
    local title
    local pipeline_description
    local triggered_by
    local environment_name="${CI_ENVIRONMENT_NAME:-}"
    local pushed_by_user="${GITLAB_USER_NAME:-}"

    # Look for "Triggered By: <name>" if job isn't destroy
    triggered_by=$(echo "${CI_COMMIT_MESSAGE:-}" | sed -nE 's/.*[Tt]riggered [Bb]y:[[:space:]]*(.*)/\1/p')
    if [[ -n "${triggered_by}" && "${CI_JOB_STAGE:-}" != "destroy" ]]; then
        pushed_by_user="${triggered_by}"
    fi

    if [[ "${CI_JOB_STAGE:-}" == "test" ]]; then
        environment_name="${environment_name/validate-/}"
        pipeline_description="Validation against ${environment_name}"
    elif [[ "${CI_JOB_STAGE:-}" == "destroy" ]]; then
        pipeline_description="Destructive Deployment to ${environment_name}"
    else
        pipeline_description="Deployment to ${environment_name}"
    fi

    if [[ "${CI_JOB_STATUS:-}" == "success" ]]; then
        status="success"
        title="${pipeline_description} succeeded"
    else
        status="failure"
        title="${pipeline_description} failed"
    fi

    send_notification "${status}" "${title}" "" \
        "Environment" "${environment_name}" \
        "Pushed By" "${pushed_by_user}" \
        "Job URL" "${CI_JOB_URL:-}" \
        "Commit URL" "${CI_PROJECT_URL:-}/-/commit/${CI_COMMIT_SHA:-}"
}
