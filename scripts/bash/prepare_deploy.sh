#!/bin/bash
################################################################################
# Script: prepare_deploy.sh
# Description: Prepares a deploy/validate job. Generates the delta package with
#              sfdx-git-delta, strips ConnectedApp secrets, discovers test classes
#              via apextestlist annotations and builds the destructive flags.
#              Sourced, so $testclasses and $destructive_flags reach
#              deploy_metadata_sf.sh.
#              Delta base:
#              - MR pipelines: merge-base with origin/$CI_MERGE_REQUEST_TARGET_BRANCH_NAME
#                (three-dot semantics; CI_MERGE_REQUEST_DIFF_BASE_SHA can go stale
#                after a rebase/force-push).
#              - Push pipelines with DELTA_BASE_BRANCH (release branching model):
#                merge-base with origin/$DELTA_BASE_BRANCH, so every deploy carries
#                the whole release and a skipped/failed/manual run can't leave
#                earlier pushes undeployed.
#              - Other push pipelines: CI_COMMIT_BEFORE_SHA (linear history).
#              Deletions in the same delta ride along in the same deployment when
#              AUTO_DESTROY is "true", so additions, changes and deletions succeed
#              or fail together. Post-destructive by default; "[pre-destructive]"
#              in the commit message or MR title, or DESTRUCTIVE_MODE=pre, deletes
#              first instead. Apex deletions in production with no Apex in the
#              constructive package run DESTRUCTIVE_TESTS, since apextestlist has
#              nothing to resolve tests from.
# Usage: Sourced from .prepare-deploy in .gitlab/workflows/base-templates.yml
# Environment Variables Required:
#   - DEPLOY_PACKAGE: sfdx-git-delta output (package/package.xml)
#   - DESTRUCTIVE_CHANGES: sfdx-git-delta destructive output
#   - CI_COMMIT_BEFORE_SHA: on push pipelines without DELTA_BASE_BRANCH
# Optional:
#   - CI_MERGE_REQUEST_TARGET_BRANCH_NAME, DELTA_BASE_BRANCH
#   - AUTO_DESTROY, DESTRUCTIVE_MODE, DESTRUCTIVE_TESTS
#   - IS_PRODUCTION: "true" for the production org (set by the org's production input)
# Requires: sfdx-git-delta >= 7.3.0 (--merge-base), apextestlist >= 1.15.0
#           (--fail-on-empty fails the job when the manifest has Apex but no
#           resolvable tests)
################################################################################
set -e

base="${CI_MERGE_REQUEST_TARGET_BRANCH_NAME:-${DELTA_BASE_BRANCH:-}}"
if [ -n "$base" ]; then
    sf sgd source delta --from "origin/$base" --merge-base --output-dir .
else
    sf sgd source delta --from "$CI_COMMIT_BEFORE_SHA" --output-dir .
fi
echo "=== Deployment Package ==="
sf sfpl list -x "$DEPLOY_PACKAGE" || true
echo "=========================="

# Strip ConnectedApp secrets (prints each file it touches). `sed -i.bak` works
# with GNU, BSD and BusyBox sed; the backups are removed right after.
find . -path '*/connectedApps/*.connectedApp-meta.xml' -type f -print -exec sed -i.bak '/<consumerKey>/d' {} +
find . -path '*/connectedApps/*.connectedApp-meta.xml.bak' -type f -delete

# Empty for non-Apex packages
testclasses=$(sf apextests list --format sf -x "$DEPLOY_PACKAGE" --no-warnings --fail-on-empty)

destructive_flags=""
if [ "$AUTO_DESTROY" == "true" ] && grep -q '<types>' "$DESTRUCTIVE_CHANGES" 2>/dev/null; then
    mode="${DESTRUCTIVE_MODE:-post}"
    [[ "${CI_COMMIT_MESSAGE:-} ${CI_MERGE_REQUEST_TITLE:-}" == *"[pre-destructive]"* ]] && mode=pre
    case "$mode" in
        pre|post) ;;
        *) echo "ERROR: DESTRUCTIVE_MODE must be \"pre\" or \"post\", got \"$mode\"."; exit 1 ;;
    esac
    destructive_flags="--${mode}-destructive-changes $DESTRUCTIVE_CHANGES"
    echo "=== Destructive Changes (${mode}-destructive) ==="
    sf sfpl list -x "$DESTRUCTIVE_CHANGES" || true
    echo "=========================="
    # Applies to production validations and deploys alike
    if [ -z "$testclasses" ] && [ "${IS_PRODUCTION:-false}" == "true" ] && grep -qE '<name>(ApexClass|ApexTrigger)</name>' "$DESTRUCTIVE_CHANGES"; then
        testclasses="--tests ${DESTRUCTIVE_TESTS:?Set DESTRUCTIVE_TESTS to a space-separated list of test classes before destroying Apex in production.}"
    fi
fi
