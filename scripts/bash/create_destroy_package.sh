#!/bin/bash
################################################################################
# Script: create_destroy_package.sh
# Description: Creates deployment and destructive change package.xml files
#              from a semicolon-separated list of metadata components.
#              Used for preparing destructive deployments to Salesforce.
# Usage: Called from CI/CD pipeline with $PACKAGE environment variable
# Environment Variables Required:
#   - PACKAGE: Semicolon-separated list of metadata components
#   - DEPLOY_PACKAGE: Output path for deployment package.xml
#   - DESTRUCTIVE_PACKAGE: Output path for destructive package.xml
################################################################################
set -e
# Create directory if it don't exist
mkdir -p "destructiveChanges"

PACKAGE_LIST_FILE="package.txt"

# Save the package list to a text file
echo "$PACKAGE" | tr ';' '\n' > "$PACKAGE_LIST_FILE"

# convert package list to XML
sf sfpl xml -l "$PACKAGE_LIST_FILE" -x "$DEPLOY_PACKAGE" -n

# need an empty package.xml for destructive deployments
# suppress output to avoid warning
sf sfpl xml -x "$DESTRUCTIVE_PACKAGE" > /dev/null 2>&1
