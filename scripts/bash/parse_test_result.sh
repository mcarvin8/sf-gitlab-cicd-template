#!/bin/bash
################################################################################
# Script: parse_test_result.sh
# Description: Parses Salesforce test results from JSON output and generates
#              a provider-neutral notification message with the test outcome,
#              including failures and success notifications. Prepares
#              testResultMessage.json for post_test_result.sh.
# Usage: Called from CI/CD pipeline after test execution completes
# Dependencies: jq
# Environment Variables Required:
#   - TEST_RUN_ID: Salesforce test run identifier
#   - CI_JOB_URL: Link to the CI job for downloading artifacts
# Input: coverage/test-result-{TEST_RUN_ID}.json
# Output: testResultMessage.json
################################################################################

# Check if TEST_RUN_ID environment variable is set
if [[ -z "$TEST_RUN_ID" ]]; then
    echo "Error: Environment variable TEST_RUN_ID is not set."
    exit 1
fi

# Construct the file name using the ID
TEST_RESULT_FILE="coverage/test-result-${TEST_RUN_ID}.json"

# Check if the file exists
if [[ ! -f "$TEST_RESULT_FILE" ]]; then
    echo "Error: File $TEST_RESULT_FILE does not exist."
    exit 1
fi

# Read the JSON file and extract the summary
SUMMARY=$(jq '.summary' "$TEST_RESULT_FILE")

# Extract hostname and clean it
HOSTNAME=$(echo "$SUMMARY" | jq -r '.hostname')
FIRST_PART=$(echo "$HOSTNAME" | sed -nE 's#^[^:]*://([^./:]+)\..*#\1#p')

if [[ -n "$FIRST_PART" ]]; then
    HOSTNAME="$FIRST_PART"
fi

# Determine the summary text
OUTCOME=$(echo "$SUMMARY" | jq -r '.outcome')
TESTS_RAN=$(echo "$SUMMARY" | jq -r '.testsRan')
FAILING=$(echo "$SUMMARY" | jq -r '.failing')

if [[ "$OUTCOME" == "Failed" ]]; then
    STATUS="failure"
    TITLE="Apex tests failed on ${HOSTNAME}"
    SUMMARY_TEXT="Automated unit testing for ${HOSTNAME} has ${OUTCOME} with ${TESTS_RAN} test runs and ${FAILING} failure(s). Download pipeline artifacts from the job."
else
    STATUS="success"
    TITLE="Apex tests passed on ${HOSTNAME}"
    SUMMARY_TEXT="Automated unit testing for ${HOSTNAME} has ${OUTCOME} with ${TESTS_RAN} test runs."
fi

# Construct the provider-neutral notification message (see notify.sh)
jq -n \
    --arg status "$STATUS" \
    --arg title "$TITLE" \
    --arg text "$SUMMARY_TEXT" \
    --arg org "$HOSTNAME" \
    --arg testsRan "$TESTS_RAN" \
    --arg failing "$FAILING" \
    --arg testRunId "$TEST_RUN_ID" \
    --arg jobUrl "${CI_JOB_URL:-}" \
    '{
        status: $status,
        title: $title,
        text: $text,
        fields: [
            {name: "Org", value: $org},
            {name: "Tests Ran", value: $testsRan},
            {name: "Failing", value: $failing},
            {name: "Test Run ID", value: $testRunId},
            {name: "Job URL", value: $jobUrl}
        ]
    }' > testResultMessage.json
echo "Notification message written to testResultMessage.json"
