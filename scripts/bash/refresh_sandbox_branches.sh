#!/bin/bash
################################################################################
# Script: refresh_sandbox_branches.sh
# Description: Performs sandbox refresh operations:
#              1. Creates backup tags from DEV_BRANCH and FULLQA_BRANCH branches
#              2. Deletes DEV_BRANCH and FULLQA_BRANCH protected branches
#              3. Clears DEV_AUTH_URL_VAR and FULLQA_AUTH_URL_VAR CI/CD variables
#              4. Recreates FULLQA_BRANCH from CI_DEFAULT_BRANCH
#              5. Recreates DEV_BRANCH from FULLQA_BRANCH
# Usage:
#   ./refresh_sandbox_branches.sh
# Environment Variables Required:
#   - MAINTAINER_PAT_NAME, MAINTAINER_PAT_USER_NAME, MAINTAINER_PAT_VALUE: GitLab personal access token with api scope
#   - CI_PROJECT_ID: GitLab project ID (or will be derived from CI_PROJECT_PATH)
#   - CI_PROJECT_PATH: Project path (e.g., group/project)
#   - CI_SERVER_HOST: GitLab server hostname
#   - CI_COMMIT_SHORT_SHA: used when cleaning up local branches after recreation
# Configurable (with defaults):
#   DEV_BRANCH (develop), FULLQA_BRANCH (fullqa)
#   DEV_AUTH_URL_VAR (SANDBOX_AUTH_URL), FULLQA_AUTH_URL_VAR (FULLQA_AUTH_URL)
################################################################################

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

git config user.name "${MAINTAINER_PAT_NAME}"
git config user.email "${MAINTAINER_PAT_USER_NAME}@noreply.${CI_SERVER_HOST}"

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check required environment variables
check_required_var() {
    if [[ -z "${!1}" ]]; then
        print_error "$1 is not set."
        exit 1
    fi
}

check_required_var "MAINTAINER_PAT_VALUE"
check_required_var "MAINTAINER_PAT_NAME"
check_required_var "MAINTAINER_PAT_USER_NAME"
check_required_var "CI_SERVER_HOST"

# Configurable branch and CI/CD variable names
DEV_BRANCH="${DEV_BRANCH:-develop}"
FULLQA_BRANCH="${FULLQA_BRANCH:-fullqa}"
DEV_AUTH_URL_VAR="${DEV_AUTH_URL_VAR:-SANDBOX_AUTH_URL}"
FULLQA_AUTH_URL_VAR="${FULLQA_AUTH_URL_VAR:-FULLQA_AUTH_URL}"

# Determine project ID and ensure CI_PROJECT_PATH is set (needed for git operations)
if [[ -z "$CI_PROJECT_ID" ]]; then
    if [[ -z "$CI_PROJECT_PATH" ]]; then
        print_error "Either CI_PROJECT_ID or CI_PROJECT_PATH must be set."
        exit 1
    fi
    # Encode the project path for API usage
    PROJECT_PATH_ENCODED=$(echo "$CI_PROJECT_PATH" | sed 's/\//%2F/g')
    print_info "Fetching project ID from CI_PROJECT_PATH: $CI_PROJECT_PATH"
    CI_PROJECT_ID=$(curl -s --header "PRIVATE-TOKEN: ${MAINTAINER_PAT_VALUE}" \
        "https://${CI_SERVER_HOST}/api/v4/projects/${PROJECT_PATH_ENCODED}" | \
        grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
    
    if [[ -z "$CI_PROJECT_ID" ]]; then
        print_error "Failed to retrieve project ID from CI_PROJECT_PATH."
        exit 1
    fi
    print_info "Retrieved project ID: $CI_PROJECT_ID"
fi

# CI_PROJECT_PATH is required for git operations (branch recreation)
if [[ -z "$CI_PROJECT_PATH" ]]; then
    print_error "CI_PROJECT_PATH must be set for branch recreation operations."
    exit 1
fi

# Base API URL
API_BASE="https://${CI_SERVER_HOST}/api/v4/projects/${CI_PROJECT_ID}"

# Function to get current date in MM.DD.YY format
get_date_string() {
    date +"%m.%d.%y"
}

# Function to create a tag
create_tag() {
    local branch=$1
    local tag_name=$2
    local ref=$3
    
    print_info "Creating tag '$tag_name' from branch '$branch' (ref: $ref)"
    
    local response=$(curl -s -w "\n%{http_code}" --request POST \
        --header "PRIVATE-TOKEN: ${MAINTAINER_PAT_VALUE}" \
        --header "Content-Type: application/json" \
        --data "{\"tag_name\":\"${tag_name}\",\"ref\":\"${ref}\",\"message\":\"Backup tag created from ${branch} branch\"}" \
        "${API_BASE}/repository/tags")
    
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" == "201" ]]; then
        print_info "Successfully created tag: $tag_name"
        return 0
    elif [[ "$http_code" == "400" ]] && echo "$body" | grep -q "already exists"; then
        print_warn "Tag '$tag_name' already exists. Skipping creation."
        return 0
    else
        print_error "Failed to create tag '$tag_name'. HTTP $http_code"
        echo "$body" | head -20
        return 1
    fi
}

# Function to get protection rules for a branch
get_protection_rules() {
    local branch=$1
    local response=$(curl -s --header "PRIVATE-TOKEN: ${MAINTAINER_PAT_VALUE}" \
        "${API_BASE}/protected_branches/${branch}")
    
    # Check if branch is protected
    if echo "$response" | grep -q '"name"'; then
        echo "$response"
        return 0
    else
        return 1
    fi
}

# Function to apply protection rules to a branch (preserves original rules including user IDs and groups)
apply_protection_rules() {
    local branch=$1
    local rules_json=$2
    
    if [[ -z "$rules_json" ]]; then
        print_warn "No protection rules provided for branch: $branch"
        return 1
    fi
    
    print_info "Applying protection rules to branch: $branch"
    
    # Use jq if available to properly reconstruct the protection rules
    if command -v jq &> /dev/null; then
        # Build the protection request using jq to properly handle arrays and nested objects
        # Filter arrays to only include fields needed for API: user_id, group_id, or access_level
        # Remove id, access_level_description, deploy_key_id, etc. as they're not needed for creation
        # Use allowed_to_push and allowed_to_merge (not push_access_levels/merge_access_levels)
        # Each entry should have only one field: user_id, group_id, or access_level
        local protect_data=$(echo "$rules_json" | jq -c --arg branch_name "$branch" '{
            name: $branch_name,
            allowed_to_push: [
                .push_access_levels[]? | 
                if .user_id != null then {user_id: .user_id}
                elif .group_id != null then {group_id: .group_id}
                elif .deploy_key_id != null then {deploy_key_id: .deploy_key_id}
                else {access_level: .access_level}
                end
            ],
            allowed_to_merge: [
                .merge_access_levels[]? | 
                if .user_id != null then {user_id: .user_id}
                elif .group_id != null then {group_id: .group_id}
                else {access_level: .access_level}
                end
            ],
            allow_force_push: (.allow_force_push // false),
            code_owner_approval_required: (.code_owner_approval_required // false)
        }' 2>/dev/null)
        
        if [[ -z "$protect_data" ]]; then
            print_error "Failed to parse protection rules JSON with jq"
            return 1
        fi
        
        # Debug: Count user IDs in original rules
        local original_push_users=$(echo "$rules_json" | jq -r '.push_access_levels[]? | select(.user_id != null) | .user_id' 2>/dev/null | wc -l | tr -d ' ')
        local original_merge_users=$(echo "$rules_json" | jq -r '.merge_access_levels[]? | select(.user_id != null) | .user_id' 2>/dev/null | wc -l | tr -d ' ')
        print_info "Original rules - Push users: $original_push_users, Merge users: $original_merge_users"
        
        # Debug: Show what we're sending (first 500 chars)
        print_info "Protection data preview (first 500 chars): $(echo "$protect_data" | head -c 500)..."
        
        # Debug: Count user IDs in push and merge access levels (using allowed_to_push/allowed_to_merge)
        local push_user_count=$(echo "$protect_data" | jq -r '.allowed_to_push[]? | select(.user_id != null) | .user_id' 2>/dev/null | wc -l | tr -d ' ')
        local merge_user_count=$(echo "$protect_data" | jq -r '.allowed_to_merge[]? | select(.user_id != null) | .user_id' 2>/dev/null | wc -l | tr -d ' ')
        print_info "Filtered data - Push access levels with user_id: $push_user_count"
        print_info "Filtered data - Merge access levels with user_id: $merge_user_count"
        
        if [[ "$push_user_count" != "$original_push_users" ]] || [[ "$merge_user_count" != "$original_merge_users" ]]; then
            print_warn "WARNING: User count mismatch! Original: push=$original_push_users, merge=$original_merge_users | Filtered: push=$push_user_count, merge=$merge_user_count"
        fi
    else
        # Fallback: manually extract and build JSON (less reliable but works without jq)
        print_warn "jq not available, using fallback method (may not preserve all user/group-specific rules)"
        
        local allow_force_push=$(echo "$rules_json" | grep -o '"allow_force_push":[^,}]*' | cut -d':' -f2 | tr -d ' ' || echo "false")
        local code_owner_approval_required=$(echo "$rules_json" | grep -o '"code_owner_approval_required":[^,}]*' | cut -d':' -f2 | tr -d ' ' || echo "false")
        
        # Extract push and merge access levels (simplified - may miss user/group-specific access)
        local push_access_level=$(echo "$rules_json" | grep -o '"push_access_levels":\[{[^}]*"access_level":[0-9]*' | grep -o '"access_level":[0-9]*' | cut -d':' -f2 | head -1 || echo "40")
        local merge_access_level=$(echo "$rules_json" | grep -o '"merge_access_levels":\[{[^}]*"access_level":[0-9]*' | grep -o '"access_level":[0-9]*' | cut -d':' -f2 | head -1 || echo "40")
        
        local protect_data="{"
        protect_data="${protect_data}\"name\":\"${branch}\""
        protect_data="${protect_data},\"push_access_levels\":[{\"access_level\":${push_access_level}}]"
        protect_data="${protect_data},\"merge_access_levels\":[{\"access_level\":${merge_access_level}}]"
        protect_data="${protect_data},\"allow_force_push\":${allow_force_push}"
        protect_data="${protect_data},\"code_owner_approval_required\":${code_owner_approval_required}"
        protect_data="${protect_data}}"
    fi
    
    local response=$(curl -s -w "\n%{http_code}" --request POST \
        --header "PRIVATE-TOKEN: ${MAINTAINER_PAT_VALUE}" \
        --header "Content-Type: application/json" \
        --data "$protect_data" \
        "${API_BASE}/protected_branches")
    
    local http_code=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" == "201" ]] || [[ "$http_code" == "200" ]]; then
        print_info "Successfully applied protection rules to branch: $branch"
        
        # Verify what was actually applied by fetching the rules back
        print_info "Verifying applied protection rules..."
        sleep 1  # Brief delay to ensure rules are saved
        local verify_rules=$(get_protection_rules "$branch" 2>/dev/null)
        if [[ -n "$verify_rules" ]] && command -v jq &> /dev/null; then
            local verified_push_users=$(echo "$verify_rules" | jq -r '.push_access_levels[]? | select(.user_id != null) | .user_id' 2>/dev/null | wc -l | tr -d ' ')
            local verified_merge_users=$(echo "$verify_rules" | jq -r '.merge_access_levels[]? | select(.user_id != null) | .user_id' 2>/dev/null | wc -l | tr -d ' ')
            print_info "Verified - Push access levels with user_id: $verified_push_users"
            print_info "Verified - Merge access levels with user_id: $verified_merge_users"
        fi
        return 0
    else
        print_error "Failed to apply protection rules to branch '$branch'. HTTP $http_code"
        print_error "API Response:"
        echo "$response_body" | head -20
        return 1
    fi
}

# Function to delete a protected branch (tries direct deletion first to preserve rules)
delete_branch() {
    local branch=$1
    local protection_rules_var=$2  # Variable name to store protection rules
    
    print_info "Deleting protected branch: $branch"
    # First, fetch protection rules before unprotecting
    print_info "Fetching protection rules before unprotecting"
    local protection_rules=$(get_protection_rules "$branch" 2>&1)
    local get_rules_status=$?
    
    if [[ $get_rules_status -eq 0 ]] && [[ -n "$protection_rules" ]]; then
        print_info "Retrieved protection rules for branch: $branch"
        print_info "Protection rules length: ${#protection_rules} characters"
        # Store protection rules in the provided variable name
        # Use declare -g to set the global variable (works in bash 4.2+)
        declare -g "$protection_rules_var"="$protection_rules"
        # Verify the variable was set
        local stored_rules="${!protection_rules_var}"
        if [[ -n "$stored_rules" ]]; then
            print_info "Successfully stored protection rules in $protection_rules_var"
        else
            print_error "Failed to store protection rules in $protection_rules_var"
        fi
    else
        print_warn "Could not retrieve protection rules for branch: $branch (may not be protected)"
        if [[ -n "$protection_rules" ]]; then
            print_warn "API response: $(echo "$protection_rules" | head -3)"
        fi
    fi
    
    # Now unprotect the branch
    print_info "Unprotecting branch: $branch"
    local unprotect_response=$(curl -s -w "\n%{http_code}" --request DELETE \
        --header "PRIVATE-TOKEN: ${MAINTAINER_PAT_VALUE}" \
        "${API_BASE}/protected_branches/${branch}")
    
    local unprotect_code=$(echo "$unprotect_response" | tail -n1)
    if [[ "$unprotect_code" != "204" ]] && [[ "$unprotect_code" != "404" ]]; then
        print_warn "Failed to unprotect branch '$branch' (HTTP $unprotect_code). Attempting to delete anyway."
    fi
    
    # Now delete the branch
    local response=$(curl -s -w "\n%{http_code}" --request DELETE \
        --header "PRIVATE-TOKEN: ${MAINTAINER_PAT_VALUE}" \
        "${API_BASE}/repository/branches/${branch}")
    
    local http_code=$(echo "$response" | tail -n1)
    
    if [[ "$http_code" == "204" ]]; then
        print_info "Successfully deleted branch: $branch"
        return 0
    elif [[ "$http_code" == "404" ]]; then
        print_warn "Branch '$branch' does not exist. Skipping deletion."
        return 0
    else
        print_error "Failed to delete branch '$branch'. HTTP $http_code"
        echo "$response" | sed '$d' | head -20
        return 1
    fi
}

# Function to update a CI/CD variable
update_variable() {
    local var_key=$1
    local var_value=$2
    
    print_info "Updating CI/CD variable: $var_key"
    
    local response=$(curl -s -w "\n%{http_code}" --request PUT \
        --header "PRIVATE-TOKEN: ${MAINTAINER_PAT_VALUE}" \
        --header "Content-Type: application/json" \
        --data "{\"key\":\"${var_key}\",\"value\":\"${var_value}\"}" \
        "${API_BASE}/variables/${var_key}")
    
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" == "200" ]]; then
        print_info "Successfully updated variable: $var_key"
        return 0
    elif [[ "$http_code" == "404" ]]; then
        print_warn "Variable '$var_key' does not exist. Creating it."
        # Try to create the variable
        local create_response=$(curl -s -w "\n%{http_code}" --request POST \
            --header "PRIVATE-TOKEN: ${MAINTAINER_PAT_VALUE}" \
            --header "Content-Type: application/json" \
            --data "{\"key\":\"${var_key}\",\"value\":\"${var_value}\"}" \
            "${API_BASE}/variables")
        
        local create_code=$(echo "$create_response" | tail -n1)
        if [[ "$create_code" == "201" ]]; then
            print_info "Successfully created variable: $var_key"
            return 0
        else
            print_error "Failed to create variable '$var_key'. HTTP $create_code"
            return 1
        fi
    else
        print_error "Failed to update variable '$var_key'. HTTP $http_code"
        echo "$body" | head -20
        return 1
    fi
}

# Function to recreate a branch from another branch
recreate_branch() {
    local new_branch=$1
    local source_branch=$2
    
    print_info "Recreating branch '$new_branch' from '$source_branch'"
    
    # Fetch latest from origin
    git fetch -q origin
    
    # Check if source branch exists
    if ! git ls-remote --exit-code --heads origin "$source_branch" > /dev/null 2>&1; then
        print_error "Source branch '$source_branch' does not exist on origin."
        return 1
    fi
    
    # Checkout the source branch
    git fetch origin "$source_branch"
    git checkout -b "$new_branch" "origin/$source_branch" 2>/dev/null || {
        # If branch already exists locally, delete it first
        git branch -D "$new_branch" 2>/dev/null || true
        git checkout -b "$new_branch" "origin/$source_branch"
    }
    
    # Push the new branch with ci.skip option
    print_info "Pushing branch '$new_branch' to origin (skipping CI pipeline)"
    git push -u "https://${MAINTAINER_PAT_NAME}:${MAINTAINER_PAT_VALUE}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" "$new_branch" -o ci.skip
    
    if [[ $? -eq 0 ]]; then
        print_info "Successfully recreated branch: $new_branch"
        # Clean up local branch
        git checkout -q "$CI_COMMIT_SHORT_SHA" 2>/dev/null || git checkout -q main 2>/dev/null || true
        git branch -D "$new_branch" 2>/dev/null || true
        return 0
    else
        print_error "Failed to push branch '$new_branch'"
        # Clean up local branch
        git checkout -q "$CI_COMMIT_SHORT_SHA" 2>/dev/null || git checkout -q main 2>/dev/null || true
        git branch -D "$new_branch" 2>/dev/null || true
        return 1
    fi
}

# Main execution
print_info "Starting sandbox refresh process..."

# Get current date for tag names
DATE_STRING=$(get_date_string)
print_info "Using date string for tags: $DATE_STRING"

# Step 1: Create tags from develop and fullqa branches
print_info "=== Step 1: Creating backup tags ==="

# Create tag from DEV_BRANCH using branch name as ref
if git ls-remote --exit-code --heads origin "$DEV_BRANCH" > /dev/null 2>&1; then
    create_tag "$DEV_BRANCH" "${DEV_BRANCH}Backup${DATE_STRING}" "$DEV_BRANCH"
else
    print_warn "Skipping $DEV_BRANCH tag creation - branch not found or inaccessible"
fi

# Create tag from FULLQA_BRANCH using branch name as ref
if git ls-remote --exit-code --heads origin "$FULLQA_BRANCH" > /dev/null 2>&1; then
    create_tag "$FULLQA_BRANCH" "${FULLQA_BRANCH}Backup${DATE_STRING}" "$FULLQA_BRANCH"
else
    print_warn "Skipping $FULLQA_BRANCH tag creation - branch not found or inaccessible"
fi

# Step 2: Delete protected branches (preserving protection rules)
print_info "=== Step 2: Deleting protected branches ==="

# Variables to store protection rules
DEVELOP_PROTECTION_RULES=""
FULLQA_PROTECTION_RULES=""

delete_branch "$DEV_BRANCH" "DEVELOP_PROTECTION_RULES"
delete_branch "$FULLQA_BRANCH" "FULLQA_PROTECTION_RULES"

# Step 3: Clear CI/CD variables
print_info "=== Step 3: Clearing CI/CD variables ==="

update_variable "$FULLQA_AUTH_URL_VAR" ""
update_variable "$DEV_AUTH_URL_VAR" ""

# Step 4: Recreate FULLQA_BRANCH from CI_DEFAULT_BRANCH
print_info "=== Step 4: Recreating $FULLQA_BRANCH branch from ${CI_DEFAULT_BRANCH:-main} ==="

recreate_branch "$FULLQA_BRANCH" "${CI_DEFAULT_BRANCH:-main}"

# Reapply protection rules to FULLQA_BRANCH if we have them
if [[ -n "$FULLQA_PROTECTION_RULES" ]]; then
    print_info "Reapplying protection rules to $FULLQA_BRANCH branch"
    print_info "$FULLQA_BRANCH protection rules length: ${#FULLQA_PROTECTION_RULES} characters"
    apply_protection_rules "$FULLQA_BRANCH" "$FULLQA_PROTECTION_RULES"
else
    print_warn "No protection rules to reapply for $FULLQA_BRANCH branch"
    print_warn "FULLQA_PROTECTION_RULES variable is empty"
fi

# Step 5: Recreate DEV_BRANCH from FULLQA_BRANCH
print_info "=== Step 5: Recreating $DEV_BRANCH branch from $FULLQA_BRANCH ==="

recreate_branch "$DEV_BRANCH" "$FULLQA_BRANCH"

# Reapply protection rules to DEV_BRANCH if we have them
if [[ -n "$DEVELOP_PROTECTION_RULES" ]]; then
    print_info "Reapplying protection rules to $DEV_BRANCH branch"
    print_info "$DEV_BRANCH protection rules length: ${#DEVELOP_PROTECTION_RULES} characters"
    apply_protection_rules "$DEV_BRANCH" "$DEVELOP_PROTECTION_RULES"
else
    print_warn "No protection rules to reapply for $DEV_BRANCH branch"
    print_warn "DEVELOP_PROTECTION_RULES variable is empty"
fi

print_info "=== GitLab Sandbox refresh process completed ==="
