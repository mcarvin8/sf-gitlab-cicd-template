#!/bin/bash
################################################################################
# Script: rollback.sh
# Description: Reverts a specific commit (regular or merge) on the current 
#              branch by creating a new revert commit. Validates that the commit
#              exists in the branch history and is less than 3 weeks old. 
#              Restores the original package.xml for correct redeployment.
# Usage: Called from CI/CD pipeline with SHA environment variable
# Environment Variables Required:
#   - SHA: Git commit SHA to revert (must be < 3 weeks old)
#   - CI_COMMIT_BRANCH: Branch to perform rollback on
#   - MAINTAINER_PAT_NAME, MAINTAINER_PAT_USER_NAME, MAINTAINER_PAT_VALUE
#   - GITLAB_USER_NAME
# Prerequisite: maintainer_git.sh sourced and setup_maintainer_git called
#   (done by the .maintainer-git CI template's before_script)
################################################################################
set -e

function check_commit_age() {
    COMMIT_TIMESTAMP=$(git show -s --format=%ct "$SHA")
    CURRENT_TIMESTAMP=$(date +%s)
    THREE_WEEKS_AGO=$(( CURRENT_TIMESTAMP - 21 * 24 * 60 * 60 ))

    if (( COMMIT_TIMESTAMP < THREE_WEEKS_AGO )); then
        echo "SHA $SHA is older than 3 weeks. Rollbacks are only allowed for SHAs made in the past 3 weeks."
        exit 1
    fi
}

# Must fetch before checking out branches
git fetch -q
git checkout -q $CI_COMMIT_BRANCH
git pull --ff -q

if git merge-base --is-ancestor "$SHA" HEAD; then
  echo "SHA $SHA is valid in the current branch."
else
  echo "SHA $SHA is not valid in the current branch. Confirm SHA and run a new rollback pipeline."
  exit 1
fi

check_commit_age

# Check if the commit is a merge commit - this command fails when it's not a merge commit, ignore the failure
IS_MERGE=$(git log --merges --pretty=format:"%H" | grep "$SHA" || true)

if [ -n "$IS_MERGE" ]; then
  echo "SHA $SHA is a merge commit."

  # Revert the merge commit with the first parent (-m 1)
  git revert -X ours --no-commit -m 1 "$SHA" || true
else
  echo "SHA $SHA is a regular commit."

  # Revert the regular commit
  git revert -X ours --no-commit "$SHA" || true
fi

# Commit changes
git commit -m "Reverts changes of $SHA, Triggered by: $GITLAB_USER_NAME"

# Push changes to remote
git push origin "$CI_COMMIT_BRANCH"
