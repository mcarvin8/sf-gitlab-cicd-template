#!/bin/bash
################################################################################
# Script: backfill_prod_into_sbx.sh
# Description: Automatically merges changes from the default (production) branch
#              into sandbox branches ($FULLQA_BRANCH and $DEV_BRANCH). Resolves conflicts
#              by preferring the default branch version. Skips CI pipeline on push.
# Usage: Called from CI/CD pipeline after successful production deployment
# Environment Variables Required:
#   - MAINTAINER_PAT_NAME, MAINTAINER_PAT_USER_NAME, MAINTAINER_PAT_VALUE
#   - CI_SERVER_HOST, CI_PROJECT_PATH, CI_COMMIT_SHORT_SHA, CI_DEFAULT_BRANCH
# Configurable (with defaults): DEV_BRANCH (develop), FULLQA_BRANCH (fullqa)
# Prerequisite: maintainer_git.sh sourced and setup_maintainer_git called
#   (done by the .maintainer-git CI template's before_script)
################################################################################
set -e

function handle_delete_conflicts() {
    # Manually resolve remaining conflicts: always favor the source branch (theirs)
    git ls-files -u | cut -f2 | sort -u | while read -r file; do
        git checkout --theirs "$file" 2>/dev/null || {
            echo "No 'theirs' version for '$file', assuming it was deleted in source."
            git rm -f "$file"
        }
        git add "$file" 2>/dev/null || true
    done
}

# Must fetch before checking out the sandbox branches
git fetch -q

# Update the sandbox branches with changes from production
for branch_name in "${FULLQA_BRANCH:-fullqa}" "${DEV_BRANCH:-develop}"
do
    git checkout -q $branch_name
    git pull --ff -q
    # Merge changes from the default branch, using "theirs" strategy to deal with conflicts
    git merge --no-ff -X theirs --no-commit "origin/${CI_DEFAULT_BRANCH}" || true
    handle_delete_conflicts
    git commit -m "Merge remote-tracking branch 'origin/${CI_DEFAULT_BRANCH}' into $branch_name"
    # Push changes to remote, skipping CI pipeline
    git push origin "$branch_name" -o ci.skip
done
