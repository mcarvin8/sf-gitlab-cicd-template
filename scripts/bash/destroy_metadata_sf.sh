#!/bin/bash
################################################################################
# Script: destroy_metadata_sf.sh
# Description: Executes a standalone destructive changes deployment to Salesforce
#              (web destroy pipeline), removing the metadata components listed in
#              the destructive changes package. Runs DESTRUCTIVE_TESTS for Apex
#              destructive changes in production. Git-tracked deletions are
#              deployed with the delta package instead (see deploy_metadata_sf.sh).
# Usage: Called from CI/CD pipeline during destroy stage
# Environment Variables Required:
#   - DEPLOY_PACKAGE: Path to the destructive changes manifest
#   - DESTRUCTIVE_PACKAGE: Path to the (empty) deployment manifest
#   - DEPLOY_TIMEOUT
#   - DESTRUCTIVE_TESTS: space-separated test class names; required only when
#     destroying ApexClass/ApexTrigger in production
#   - CI_ENVIRONMENT_NAME
################################################################################
set -e

# Destructive Apex deployments in production require tests
test_flags=""
if [ "$CI_ENVIRONMENT_NAME" == "production" ] && grep -qE '<name>(ApexClass|ApexTrigger)</name>' "$DEPLOY_PACKAGE" 2>/dev/null; then
    test_flags="-l RunSpecifiedTests --tests ${DESTRUCTIVE_TESTS:?Set DESTRUCTIVE_TESTS to a space-separated list of test classes before destroying Apex in production.}"
fi

sf project deploy start --pre-destructive-changes $DEPLOY_PACKAGE --manifest $DESTRUCTIVE_PACKAGE $test_flags -w $DEPLOY_TIMEOUT --verbose
