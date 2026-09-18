#!/bin/bash
################################################################################
# Script: delete_stale_branches.sh
# Description: Deletes stale Git branches that have been merged into the
#              default branch and haven't been updated in a specified time period.
#              - Branches merged into the default branch where HEAD commit is older than 1 month
#              - Any branches where HEAD commit is older than 3 months
# Usage: Called from scheduled CI/CD pipeline
# Note: Protected branches cannot be deleted via this script
# Environment Variables Required:
#   - MAINTAINER_PAT_NAME, MAINTAINER_PAT_VALUE
#   - CI_DEFAULT_BRANCH (predefined by GitLab)
################################################################################
set -euo pipefail

before_date='1 month ago'
stale_before_date='3 months ago'

git fetch -q

################################################################################
# Function: check_branch_last_commit_date
# Description: Checks if the last commit on a branch is older than the cutoff date.
# Arguments:
#   $1 - Branch reference (e.g., origin/branch-name)
#   $2 - Cutoff date (e.g., "1 month ago")
# Returns: 0 if last commit is older than cutoff date, 1 otherwise
################################################################################
check_branch_last_commit_date() {
    local branch_ref="$1"
    local cutoff_date="$2"
    local branch_name=$(echo "$branch_ref" | sed 's/origin\///')
    
    # Get the date of the last commit on this branch
    local last_commit_date=$(git log -1 --format=%ai "$branch_ref" 2>/dev/null)
    
    if [ -z "$last_commit_date" ]; then
        echo "WARNING: Could not get last commit date for $branch_name, skipping"
        return 1
    fi
    
    # Check if the last commit is older than the cutoff date
    # Use git log --before to check if last commit is before the cutoff
    local last_commit_hash=$(git log -1 --format=%H "$branch_ref" 2>/dev/null)
    local commits_before_cutoff=$(git log --before="$cutoff_date" --format=%H -1 "$branch_ref" 2>/dev/null)
    
    # If commits_before_cutoff matches last_commit_hash, the last commit is before cutoff
    if [ -n "$commits_before_cutoff" ] && [ "$commits_before_cutoff" = "$last_commit_hash" ]; then
        echo "Branch $branch_name last commit on $last_commit_date (older than $cutoff_date)"
        return 0
    else
        echo "Branch $branch_name last commit on $last_commit_date (newer than $cutoff_date, keeping)"
        return 1
    fi
}

################################################################################
# Delete merged branches where last commit is older than cutoff date
################################################################################
filter="git branch --merged origin/${CI_DEFAULT_BRANCH} -r"
echo "Deleting all branches merged into ${CI_DEFAULT_BRANCH} branch with last commit over $before_date"
for k in $(${filter} | grep --invert-match "origin/${CI_DEFAULT_BRANCH}" | sed /\*/d); do
    if check_branch_last_commit_date "$k" "$before_date"; then
        branch=$(echo $k | sed 's/origin\///')
        echo "Attempting to delete $branch"
        git push "https://${MAINTAINER_PAT_NAME}:${MAINTAINER_PAT_VALUE}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" --delete $branch
        # minor delay needed to prevent connection abort errors
        sleep 5
    fi
done

git fetch --prune -q

################################################################################
# Delete any stale branches (merged or not) where last commit is older than cutoff date
# Use git for-each-ref for better performance - it's faster than git branch -r
################################################################################
echo "Deleting all stale branches with last commit over $stale_before_date"

# Use git for-each-ref to get all remote branches - much faster than git branch -r
while IFS='|' read -r refname committerdate; do
    # Skip default branch
    if [[ "$refname" == "origin/${CI_DEFAULT_BRANCH}" ]] || [[ "$refname" == "origin/HEAD" ]]; then
        continue
    fi
    
    branch_name=$(echo "$refname" | sed 's|^origin/||')
    
    # Check if the last commit is older than the cutoff date using git log --before
    # This is more reliable than timestamp comparison
    last_commit_hash=$(git log -1 --format=%H "$refname" 2>/dev/null)
    commits_before_cutoff=$(git log --before="$stale_before_date" --format=%H -1 "$refname" 2>/dev/null)
    
    # If commits_before_cutoff matches last_commit_hash, the last commit is before cutoff
    if [ -n "$commits_before_cutoff" ] && [ -n "$last_commit_hash" ] && [ "$commits_before_cutoff" = "$last_commit_hash" ]; then
        echo "Branch $branch_name last commit on $committerdate (older than $stale_before_date)"
        echo "Attempting to delete $branch_name"
        git push "https://${MAINTAINER_PAT_NAME}:${MAINTAINER_PAT_VALUE}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" --delete "$branch_name"
        # minor delay needed to prevent connection abort errors
        sleep 5
    fi
done < <(git for-each-ref --format='%(refname:short)|%(committerdate:iso)' refs/remotes/origin 2>/dev/null)
