#!/bin/bash
################################################################################
# Script: destroy_metadata_sf.sh
# Description: Executes a standalone destructive changes deployment to Salesforce
#              (web destroy pipeline), removing the metadata components listed in
#              the destructive changes package. Runs tests for Apex-related
#              destructive changes in production. Git-tracked deletions are
#              deployed with the delta package instead (see deploy_metadata_sf.sh).
# Usage: Called from CI/CD pipeline during destroy stage
# Environment Variables Required:
#   - testclasses: space-separated test class names from DESTRUCTIVE_TESTS env var, or "not a test" for non-Apex or non-production
#   - DEPLOY_PACKAGE: Path to the destructive changes manifest
#   - DESTRUCTIVE_PACKAGE: Path to the (empty) deployment manifest
#   - DEPLOY_TIMEOUT
################################################################################
set -e

# Destructive apex deployments in production only require tests
if [ "$testclasses" == "not a test" ]; then
    sf project deploy start --pre-destructive-changes $DEPLOY_PACKAGE --manifest $DESTRUCTIVE_PACKAGE -w $DEPLOY_TIMEOUT --verbose
else
    sf project deploy start --pre-destructive-changes $DEPLOY_PACKAGE --manifest $DESTRUCTIVE_PACKAGE -l RunSpecifiedTests -t $testclasses -w $DEPLOY_TIMEOUT --verbose
fi
