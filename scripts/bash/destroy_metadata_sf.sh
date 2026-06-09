#!/bin/bash
################################################################################
# Script: destroy_metadata_sf.sh
# Description: Executes destructive changes deployment to Salesforce, removing
#              metadata components specified in the destructive changes package.
#              Runs tests for Apex-related destructive changes in production.
# Usage: Called from CI/CD pipeline during destroy stage
# Environment Variables Required:
#   - testclasses: space-separated test class names from DESTRUCTIVE_TESTS env var, or "not a test" for non-Apex/non-production
#   - DEPLOY_PACKAGE: Path to deployment package (pre-destructive changes)
#   - DESTRUCTIVE_PACKAGE: Path to destructive changes manifest
#   - DEPLOY_TIMEOUT
################################################################################
set -e

# Destructive apex deployments in production only require tests
if [ "$testclasses" == "not a test" ]; then
    sf project deploy start --pre-destructive-changes $DEPLOY_PACKAGE --manifest $DESTRUCTIVE_PACKAGE -w $DEPLOY_TIMEOUT --verbose
else
    sf project deploy start --pre-destructive-changes $DEPLOY_PACKAGE --manifest $DESTRUCTIVE_PACKAGE -l RunSpecifiedTests -t $testclasses -w $DEPLOY_TIMEOUT --verbose
fi
