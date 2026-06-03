#!/bin/bash
################################################################################
# Script: generate_delta_package.sh
# Description: Generates an incremental deployment package.xml from the git
#              delta between BEFORE_SHA and HEAD. Optionally merges extra
#              metadata declared in a <Package> block within $COMMIT_MSG
#              (MR description or merge commit message) using sf-package-list
#              and sf-package-combiner. Prints the final package in list format.
# Usage: Sourced from .authenticate before_script for test and deploy stages.
# Environment Variables:
#   BEFORE_SHA    - git SHA to diff from (CI_MERGE_REQUEST_DIFF_BASE_SHA or
#                   CI_COMMIT_BEFORE_SHA depending on validate vs deploy)
#   COMMIT_MSG    - MR description or commit message; may contain <Package> block
#   DEPLOY_PACKAGE - destination path for the combined package.xml
################################################################################
set -e

mkdir -p package manifest

# Resolve base SHA. CI_COMMIT_BEFORE_SHA is all-zeros on first push to a branch.
FROM_SHA="${BEFORE_SHA:-}"
if [ "$FROM_SHA" = "0000000000000000000000000000000000000000" ] || [ -z "$FROM_SHA" ]; then
    echo "No previous commit SHA. Using origin/${CI_DEFAULT_BRANCH:-main} as delta base."
    FROM_SHA=$(git rev-parse "origin/${CI_DEFAULT_BRANCH:-main}" 2>/dev/null || echo "")
    if [ -z "$FROM_SHA" ]; then
        echo "Could not resolve base SHA. Writing empty package."
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<Package xmlns="http://soap.sforce.com/2006/04/metadata">\n</Package>\n' > "$DEPLOY_PACKAGE"
        exit 0
    fi
fi

# Generate incremental package from git delta.
sf sgd source delta --from "$FROM_SHA" --output-dir .

DELTA_PKG="package/package.xml"
EXTRA_LIST="extra_package.txt"
EXTRA_XML="extra_package.xml"
HAS_EXTRA=false

# Extract content between <Package>...</Package> from commit/MR message.
if echo "${COMMIT_MSG:-}" | grep -q '<Package>'; then
    echo "${COMMIT_MSG}" | sed -n '/<Package>/,/<\/Package>/p' | sed '1d;$d' > "$EXTRA_LIST"
    if [ -s "$EXTRA_LIST" ]; then
        sf sfpl xml -l "$EXTRA_LIST" -x "$EXTRA_XML" -n
        HAS_EXTRA=true
    fi
fi

# Combine delta and extra packages when both have types; otherwise copy whichever exists.
DELTA_HAS_TYPES=false
if grep -q '<types>' "$DELTA_PKG" 2>/dev/null; then
    DELTA_HAS_TYPES=true
fi

if [ "$DELTA_HAS_TYPES" = "true" ] && [ "$HAS_EXTRA" = "true" ]; then
    sf sfpc combine -f "$DELTA_PKG" -f "$EXTRA_XML" -c "$DEPLOY_PACKAGE" -n
elif [ "$HAS_EXTRA" = "true" ]; then
    cp "$EXTRA_XML" "$DEPLOY_PACKAGE"
else
    cp "$DELTA_PKG" "$DEPLOY_PACKAGE"
fi

rm -f "$EXTRA_LIST" "$EXTRA_XML"

echo "=== Deployment Package ==="
sf sfpl list -x "$DEPLOY_PACKAGE" || true
echo "=========================="
