#!/bin/bash
################################################################################
# Script: deploy_metadata_sf.sh
# Description: Deploys Salesforce metadata with intelligent test handling based
#              on package type and environment. Validates for non-push pipelines,
#              uses quick-deploy for production, and direct deployment for other
#              environments. Handles both Apex and non-Apex packages.
# Usage: Called from CI/CD pipeline during deployment stages
# Environment Variables Required:
#   - testclasses: "--tests Class1 --tests Class2 ..." from apextestlist, or "not a test" for non-Apex packages
#   - CI_PIPELINE_SOURCE: Pipeline trigger type (push, merge_request, etc.)
#   - CI_ENVIRONMENT_NAME: Target environment (production, sandbox, etc.)
#   - DEPLOY_PACKAGE, DEPLOY_TIMEOUT
################################################################################
set -e

# Handle non-Apex packages (no tests)
if [ "$testclasses" == "not a test" ]; then
    if [ "$CI_PIPELINE_SOURCE" != "push" ]; then
        sf project deploy start --dry-run -x $DEPLOY_PACKAGE -w $DEPLOY_TIMEOUT --verbose --ignore-conflicts
    else
        sf project deploy start -x $DEPLOY_PACKAGE -w $DEPLOY_TIMEOUT --verbose --ignore-conflicts
    fi
else
    # Apex package with tests — $testclasses is "--tests Class1 --tests Class2 ..."
    if [ "$CI_PIPELINE_SOURCE" != "push" ]; then
        # Always validate on non-push pipelines
        sf project deploy validate -l RunSpecifiedTests $testclasses \
            --coverage-formatters json --results-dir coverage \
            -x $DEPLOY_PACKAGE -w $DEPLOY_TIMEOUT --verbose
    else
        if [ "$CI_ENVIRONMENT_NAME" == "production" ]; then
            # Production: validate then quick-deploy
            sf project deploy validate -l RunSpecifiedTests $testclasses \
                --coverage-formatters json --results-dir coverage \
                -x $DEPLOY_PACKAGE -w $DEPLOY_TIMEOUT --verbose

            echo "Running the quick-deployment..."
            sf project deploy quick --use-most-recent -w $DEPLOY_TIMEOUT
        else
            # Other environments: deploy directly with tests
            sf project deploy start -l RunSpecifiedTests $testclasses \
                --coverage-formatters json --results-dir coverage \
                -x $DEPLOY_PACKAGE -w $DEPLOY_TIMEOUT --verbose --ignore-conflicts
        fi
    fi
fi
