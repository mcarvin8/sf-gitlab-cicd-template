#!/bin/bash
################################################################################
# Script: verify_branch_compliance.sh
# Description: Unified MR branch compliance for default branch, fullqa, and develop.
#              - Default-branch MRs: merge-conflict check vs main, fullqa/develop
#                merge + deploy verification, one predeploy job (org-specific),
#                package.xml check, lineage rules.
#              - fullqa/develop MRs: same lineage + package + predeploy for that
#                org only (no merge-conflict trial merge; no fullqa/develop deploy gates).
# Usage: Sourced from GitLab CI (pre-merge-check jobs).
# Dependencies: git, curl, jq (optional)
# Environment: CI_COMMIT_SHA, CI_MERGE_REQUEST_*, CI_MERGE_REQUEST_DIFF_BASE_SHA,
#              CI_PROJECT_ID, CI_SERVER_HOST, CI_PROJECT_PATH, MAINTAINER_PAT_VALUE,
#              CI_DEFAULT_BRANCH
# Optional: sf CLI + python3 for sfdx-git-delta manifest vs git-delta recommendation.
################################################################################
set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to check if a variable is set
check_required_var() {
    local var_name=$1
    if [[ -z "${!var_name:-}" ]]; then
        print_status "$RED" "Error: Required environment variable $var_name is not set"
        exit 1
    fi
}

print_status "$YELLOW" "Validating required environment variables..."
check_required_var "CI_COMMIT_SHA"
check_required_var "CI_MERGE_REQUEST_IID"
check_required_var "CI_MERGE_REQUEST_SOURCE_BRANCH_NAME"
check_required_var "CI_MERGE_REQUEST_TARGET_BRANCH_NAME"
check_required_var "CI_PROJECT_ID"
check_required_var "CI_SERVER_HOST"
check_required_var "CI_PROJECT_PATH"
check_required_var "MAINTAINER_PAT_VALUE"
check_required_var "CI_DEFAULT_BRANCH"

# Only run for MRs targeting default branch, fullqa, or develop
if [[ "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME" != "$CI_DEFAULT_BRANCH" && \
      "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME" != "fullqa" && \
      "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME" != "develop" ]]; then
    print_status "$YELLOW" "Skipping: MR target is not default branch, fullqa, or develop ($CI_MERGE_REQUEST_TARGET_BRANCH_NAME)"
    exit 0
fi

if [[ "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME" == "$CI_DEFAULT_BRANCH" ]]; then
    MR_MODE=main
else
    MR_MODE=sandbox
fi

# One predeploy validation job name per MR target (each org has its own job in the MR pipeline)
case "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME" in
    "$CI_DEFAULT_BRANCH") PREDEPLOY_JOB_NAME="test:predeploy:prd" ;;
    fullqa)               PREDEPLOY_JOB_NAME="test:predeploy:fullqa" ;;
    develop)              PREDEPLOY_JOB_NAME="test:predeploy:dev" ;;
    *)                    PREDEPLOY_JOB_NAME="test:predeploy:prd" ;;
esac

if [[ "$MR_MODE" == "main" ]]; then
    print_status "$GREEN" "Starting branch deployment verification (default branch MR)..."
else
    print_status "$GREEN" "Starting MR branch compliance (fullqa/develop MR)..."
fi
print_status "$YELLOW" "Source branch: $CI_MERGE_REQUEST_SOURCE_BRANCH_NAME"
print_status "$YELLOW" "Target branch: $CI_MERGE_REQUEST_TARGET_BRANCH_NAME"
print_status "$YELLOW" "Merge Request IID: $CI_MERGE_REQUEST_IID"

print_status "$YELLOW" "Fetching all branches..."
git fetch --all --quiet
if [[ -n "${MAINTAINER_PAT_NAME:-}" ]]; then
    git config user.name "${MAINTAINER_PAT_NAME}"
fi
if [[ -n "${MAINTAINER_PAT_USER_NAME:-}" ]]; then
    git config user.email "${MAINTAINER_PAT_USER_NAME}@noreply.${CI_SERVER_HOST}"
fi

# Use CI_COMMIT_SHA (commit that triggered this pipeline) to avoid race condition:
# if a user pushes a new commit while this pipeline runs, we must verify THIS commit, not the latest.
SOURCE_BRANCH_SHA="${CI_COMMIT_SHA}"
if ! git rev-parse --verify "$SOURCE_BRANCH_SHA" >/dev/null 2>&1; then
    print_status "$RED" "Error: Commit $SOURCE_BRANCH_SHA (CI_COMMIT_SHA) not found in repository"
    exit 1
fi

print_status "$YELLOW" "Source commit SHA: $SOURCE_BRANCH_SHA (pipeline-triggered commit)"

# Save current branch/HEAD position for later restoration (needed for package check)
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")

# Package check settings
PACKAGE_CHECK_STAGE="deploy"  # deploy or destroy
PACKAGE_CHECK_ENVIRONMENT="production"  # production or sandbox
PACKAGE_XML_PATH="manifest/package.xml"
PACKAGE_CHECK_SCRIPT="scripts/python/package_check.py"
PACKAGE_CHECK_STATUS=""
PACKAGE_CHECK_OUTPUT=""
PACKAGE_CHECK_WARNINGS=""

# Function to check how old the source commit is relative to the default branch
# Returns: "status|age_days|merge_base_sha" format
# status: "recent" if <= 30 days, "old" if > 30 days, "error" if unable to determine
# source_rev: commit SHA or ref (e.g. CI_COMMIT_SHA)
check_branch_age() {
    local source_rev=$1
    local default_branch=$2
    local max_age_days=${3:-30}  # Default to 30 days
    
    # Find the merge base (common ancestor) between source commit and default branch
    local merge_base_sha
    merge_base_sha=$(git merge-base "$source_rev" "origin/$default_branch" 2>/dev/null || echo "")
    
    if [[ -z "$merge_base_sha" ]]; then
        echo "error|0|"
        return
    fi
    
    # Get the commit timestamp (Unix timestamp in seconds)
    local commit_timestamp
    commit_timestamp=$(git log -1 --format="%ct" "$merge_base_sha" 2>/dev/null || echo "")
    
    if [[ -z "$commit_timestamp" ]]; then
        echo "error|0|$merge_base_sha"
        return
    fi
    
    # Get current timestamp (Unix timestamp in seconds)
    # Works on Linux, macOS, and Git Bash on Windows
    local current_timestamp
    if command -v date &> /dev/null; then
        # Try UTC first (more reliable), fallback to local time
        current_timestamp=$(date -u +%s 2>/dev/null || date +%s 2>/dev/null || echo "")
    else
        # Fallback: use epoch time calculation if date command is not available
        echo "error|0|$merge_base_sha"
        return
    fi
    
    if [[ -z "$current_timestamp" ]]; then
        echo "error|0|$merge_base_sha"
        return
    fi
    
    # Calculate age in days
    local age_seconds=$((current_timestamp - commit_timestamp))
    local age_days=$((age_seconds / 86400))  # 86400 seconds in a day
    
    # Determine status
    local status="recent"
    if [[ $age_days -gt $max_age_days ]]; then
        status="old"
    fi
    
    echo "$status|$age_days|$merge_base_sha"
}

# Check branch age relative to default branch
print_status "$YELLOW" "Checking source branch age relative to default branch..."
BRANCH_AGE_RESULT=$(check_branch_age "$SOURCE_BRANCH_SHA" "$CI_DEFAULT_BRANCH" 30)
BRANCH_AGE_STATUS=$(echo "$BRANCH_AGE_RESULT" | cut -d'|' -f1)
BRANCH_AGE_DAYS=$(echo "$BRANCH_AGE_RESULT" | cut -d'|' -f2)
BRANCH_MERGE_BASE_SHA=$(echo "$BRANCH_AGE_RESULT" | cut -d'|' -f3)

if [[ "$BRANCH_AGE_STATUS" == "recent" ]]; then
    print_status "$GREEN" "✓ Source branch is recent (created from default branch $BRANCH_AGE_DAYS days ago)"
elif [[ "$BRANCH_AGE_STATUS" == "old" ]]; then
    print_status "$RED" "✗ Source branch is old (created from default branch $BRANCH_AGE_DAYS days ago)"
else
    print_status "$YELLOW" "⚠ Could not determine branch age"
fi

# Check if branch name contains any of the configured prefixes.
# Set VALID_BRANCH_PREFIXES (space-separated) as a CI/CD variable to enable.
# If unset the check is skipped and all branch names pass.
check_branch_name() {
    local branch_name=$1
    local branch_lower=$(echo "$branch_name" | tr '[:upper:]' '[:lower:]')

    if [[ -z "${VALID_BRANCH_PREFIXES:-}" ]]; then
        echo "skipped"
        return
    fi

    read -ra valid_keys <<< "$VALID_BRANCH_PREFIXES"
    for key in "${valid_keys[@]}"; do
        local key_lower=$(echo "$key" | tr '[:upper:]' '[:lower:]')
        if [[ "$branch_lower" == *"$key_lower"* ]]; then
            echo "valid"
            return
        fi
    done

    echo "invalid"
}

# Check branch name against VALID_BRANCH_PREFIXES (skipped if variable unset).
print_status "$YELLOW" "Checking source branch name against VALID_BRANCH_PREFIXES..."
BRANCH_NAME_STATUS=$(check_branch_name "$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME")

if [[ "$BRANCH_NAME_STATUS" == "valid" ]]; then
    print_status "$GREEN" "✓ Branch name matches a configured prefix"
elif [[ "$BRANCH_NAME_STATUS" == "invalid" ]]; then
    print_status "$RED" "✗ Branch name does not match any prefix in VALID_BRANCH_PREFIXES (${VALID_BRANCH_PREFIXES})"
else
    print_status "$YELLOW" "⚠ Branch name check skipped (VALID_BRANCH_PREFIXES not set)"
fi

# Check if source contains merge commits that merged something INTO develop or fullqa.
# Such commits only exist on develop/fullqa; main should not have them.
# If source has them, it was branched from develop/fullqa instead of main.
# Returns: "status|offending_commits"
# Note: Old merge commits into develop/fullqa may exist on main history; we only check
# commits in origin/main..source (new commits), so no new branch should introduce them.
check_source_not_from_develop_fullqa() {
    local source_rev=$1
    local default_branch=$2
    local offending_commits=()

    local matching_commits
    matching_commits=$(git log --format="%H" --merges \
        --grep="[Mm]erge.*into.*develop\|[Mm]erge.*into.*fullqa\|[Mm]erge.*into.*origin/develop\|[Mm]erge.*into.*origin/fullqa" \
        "origin/$default_branch..$source_rev" 2>/dev/null || echo "")
    if [[ -n "$matching_commits" ]]; then
        while IFS= read -r commit; do
            [[ -n "$commit" ]] && offending_commits+=("$commit")
        done <<< "$matching_commits"
    fi

    if [[ ${#offending_commits[@]} -gt 0 ]]; then
        echo "branch_from_sandbox|$(IFS=','; echo "${offending_commits[*]}")"
    else
        echo "clean|"
    fi
}

# Function to check if source commit contains merges from fullqa or develop branches
# Returns: "status|offending_commits" format
# status: "clean" if no forbidden merges found, "forbidden_merge" if found, "error" if unable to check
# source_rev: commit SHA (e.g. CI_COMMIT_SHA)
check_forbidden_merges() {
    local source_rev=$1
    local default_branch=$2
    local forbidden_branches=("fullqa" "develop")
    local offending_commits=()
    
    # Check commit messages on the source commit's history for forbidden merge patterns
    # Only check commits that are on the source commit but NOT on the default branch
    # This avoids flagging old commits that were already merged into default
    # Look for patterns like "Merge fullqa into", "merge origin/fullqa into", etc.
    # We only want to catch merges FROM fullqa/develop INTO the source branch, not the reverse
    for forbidden_branch in "${forbidden_branches[@]}"; do
        # Search for merge commits that mention the forbidden branch being merged INTO something
        # Patterns: "Merge fullqa into", "merge origin/fullqa into", "Merge branch 'fullqa' into"
        # We use --merges to only check actual merge commits
        # The pattern ensures the forbidden branch comes before "into" (meaning it's being merged in)
        # Use "origin/$default_branch..$source_rev" to only check commits unique to source
        local matching_commits
        matching_commits=$(git log --format="%H" --merges --grep="[Mm]erge.*$forbidden_branch.*into\|[Mm]erge.*origin/$forbidden_branch.*into\|[Mm]erge.*branch.*['\"]$forbidden_branch.*into" "origin/$default_branch..$source_rev" 2>/dev/null || echo "")
        
        if [[ -n "$matching_commits" ]]; then
            # Add matching commits to offending commits list
            while IFS= read -r commit; do
                if [[ -n "$commit" ]]; then
                    offending_commits+=("$commit")
                fi
            done <<< "$matching_commits"
        fi
    done
    
    # Return results
    if [[ ${#offending_commits[@]} -gt 0 ]]; then
        # Join offending commits with comma
        local commits_str
        commits_str=$(IFS=','; echo "${offending_commits[*]}")
        echo "forbidden_merge|$commits_str"
    else
        echo "clean|"
    fi
}

# Check for forbidden merges (fullqa/develop into source branch)
print_status "$YELLOW" "Checking for forbidden merges (fullqa/develop into source branch)..."
FORBIDDEN_MERGE_RESULT=$(check_forbidden_merges "$SOURCE_BRANCH_SHA" "$CI_DEFAULT_BRANCH")
FORBIDDEN_MERGE_STATUS=$(echo "$FORBIDDEN_MERGE_RESULT" | cut -d'|' -f1)
FORBIDDEN_MERGE_COMMITS=$(echo "$FORBIDDEN_MERGE_RESULT" | cut -d'|' -f2)

if [[ "$FORBIDDEN_MERGE_STATUS" == "clean" ]]; then
    print_status "$GREEN" "✓ No forbidden merges found (source branch does not merge fullqa/develop)"
elif [[ "$FORBIDDEN_MERGE_STATUS" == "forbidden_merge" ]]; then
    print_status "$RED" "✗ Forbidden merges detected! Source branch contains merge commits from fullqa/develop"
    if [[ -n "$FORBIDDEN_MERGE_COMMITS" ]]; then
        print_status "$RED" "  Offending commit(s): $FORBIDDEN_MERGE_COMMITS"
    fi
else
    print_status "$YELLOW" "⚠ Could not check for forbidden merges"
fi

print_status "$YELLOW" "Checking source was not branched from develop/fullqa (no merge-into-sandbox commits)..."
SOURCE_ORIGIN_RESULT=$(check_source_not_from_develop_fullqa "$SOURCE_BRANCH_SHA" "$CI_DEFAULT_BRANCH")
SOURCE_ORIGIN_STATUS=$(echo "$SOURCE_ORIGIN_RESULT" | cut -d'|' -f1)
SOURCE_ORIGIN_COMMITS=$(echo "$SOURCE_ORIGIN_RESULT" | cut -d'|' -f2)

if [[ "$SOURCE_ORIGIN_STATUS" == "clean" ]]; then
    print_status "$GREEN" "✓ Source branch does not contain merge-into-develop/fullqa commits (branched from main)"
elif [[ "$SOURCE_ORIGIN_STATUS" == "branch_from_sandbox" ]]; then
    print_status "$RED" "✗ Source branch contains merge(s) into develop/fullqa - likely branched from sandbox, not main"
    [[ -n "$SOURCE_ORIGIN_COMMITS" ]] && print_status "$RED" "  Commit(s): $SOURCE_ORIGIN_COMMITS"
else
    print_status "$YELLOW" "⚠ Could not check source branch origin"
fi

# Function to check for merge conflicts between source branch and target branch
# Returns: "status|conflicted_files" format
# status: "no_conflicts" if no conflicts, "acceptable_conflicts" if only manifest/package.xml, "conflicts" if other conflicts, "error" if unable to check
# source_ref: branch ref (e.g. origin/source_branch) - use branch name, not SHA, for reliable merge in shallow clones
check_merge_conflicts() {
    local source_branch=$1
    local target_branch=$2
    local current_branch=""
    local conflicted_files=()
    
    # Save current branch/HEAD position
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")
    
    # Check if source branch exists
    if ! git show-ref --verify --quiet "refs/remotes/origin/$source_branch" 2>/dev/null; then
        echo "error|Source branch not found"
        return
    fi
    
    # Check if target branch exists
    if ! git show-ref --verify --quiet "refs/remotes/origin/$target_branch" 2>/dev/null; then
        echo "error|Target branch not found"
        return
    fi
    
    # Checkout target branch (detached HEAD is fine for testing)
    # This simulates merging source branch INTO target branch (main/default)
    if ! git checkout -q "origin/$target_branch" 2>/dev/null; then
        echo "error|Could not checkout target branch"
        return
    fi
    
    # Attempt merge with --no-commit and --no-ff to detect conflicts without committing
    # Merge source branch INTO target branch (simulating the actual MR merge)
    # Use branch ref (not SHA) for reliable merge in shallow clones
    local merge_output
    merge_output=$(git merge --no-commit --no-ff "origin/$source_branch" 2>&1)
    local merge_exit_code=$?
    
    # Check if merge succeeded (exit code 0 means success, no conflicts)
    if [[ $merge_exit_code -eq 0 ]]; then
        # Merge succeeded, no conflicts
        git merge --abort 2>/dev/null || true
        # Restore original position
        git checkout -q "$current_branch" 2>/dev/null || true
        echo "no_conflicts|"
        return
    fi
    
    # Merge failed, check for conflicts
    # Get list of unmerged (conflicted) files
    # git ls-files -u shows unmerged files (conflicts)
    local unmerged_files
    unmerged_files=$(git ls-files -u 2>/dev/null | awk '{print $4}' | sort -u 2>/dev/null || echo "")
    
    # If no unmerged files found, check if we're in a merge state
    if [[ -z "$unmerged_files" ]]; then
        # Check if we're actually in a merge state
        if [[ -f ".git/MERGE_HEAD" ]]; then
            # We're in a merge state but no conflicts detected - this shouldn't happen
            # Abort and return error
            git merge --abort 2>/dev/null || true
            git checkout -q "$current_branch" 2>/dev/null || true
            echo "error|Merge failed but no conflicts detected"
            return
        else
            # Not in merge state, might be a different error
            git merge --abort 2>/dev/null || true
            git checkout -q "$current_branch" 2>/dev/null || true
            echo "error|Merge failed: $merge_output"
            return
        fi
    fi
    
    # Check if conflicts are only in manifest/package.xml
    local only_package_xml=true
    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            conflicted_files+=("$file")
            # If file is not manifest/package.xml, mark as not acceptable
            if [[ "$file" != "manifest/package.xml" ]]; then
                only_package_xml=false
            fi
        fi
    done <<< "$unmerged_files"
    
    # Abort the merge
    git merge --abort 2>/dev/null || true
    
    # Restore original position
    git checkout -q "$current_branch" 2>/dev/null || true
    
    # Return results
    if [[ "$only_package_xml" == "true" && ${#conflicted_files[@]} -gt 0 ]]; then
        # Join conflicted files with comma
        local files_str
        files_str=$(IFS=','; echo "${conflicted_files[*]}")
        echo "acceptable_conflicts|$files_str"
    elif [[ ${#conflicted_files[@]} -gt 0 ]]; then
        # Join conflicted files with comma
        local files_str
        files_str=$(IFS=','; echo "${conflicted_files[*]}")
        echo "conflicts|$files_str"
    else
        echo "no_conflicts|"
    fi
}

# Merge-conflict trial merge: only for default-branch MRs (sandbox MRs conflict often by design)
if [[ "$MR_MODE" == "main" ]]; then
    print_status "$YELLOW" "Checking for merge conflicts between source and target branch..."
    MERGE_CONFLICT_RESULT=$(check_merge_conflicts "$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME" "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME")
    MERGE_CONFLICT_STATUS=$(echo "$MERGE_CONFLICT_RESULT" | cut -d'|' -f1)
    MERGE_CONFLICT_FILES=$(echo "$MERGE_CONFLICT_RESULT" | cut -d'|' -f2)

    if [[ "$MERGE_CONFLICT_STATUS" == "no_conflicts" ]]; then
        print_status "$GREEN" "✓ No merge conflicts between source and target branch"
    elif [[ "$MERGE_CONFLICT_STATUS" == "acceptable_conflicts" ]]; then
        print_status "$GREEN" "✓ Merge conflicts found, but only in manifest/package.xml (acceptable)"
    elif [[ "$MERGE_CONFLICT_STATUS" == "conflicts" ]]; then
        print_status "$RED" "✗ Merge conflicts detected between source and target branch"
        if [[ -n "$MERGE_CONFLICT_FILES" ]]; then
            print_status "$RED" "  Conflicted file(s): $MERGE_CONFLICT_FILES"
        fi
    else
        print_status "$YELLOW" "⚠ Could not check for merge conflicts: $MERGE_CONFLICT_FILES"
    fi
else
    MERGE_CONFLICT_STATUS=""
    MERGE_CONFLICT_FILES=""
fi

# ============================================================================
# PACKAGE.XML CHECK
# ============================================================================
print_status "$YELLOW" ""
print_status "$YELLOW" "=== Running Package.xml Compliance Check ==="

# Checkout the latest commit on the source branch for package check
print_status "$YELLOW" "Checking out latest commit on source branch ($SOURCE_BRANCH_SHA) for package check..."
if ! git rev-parse --verify "$SOURCE_BRANCH_SHA" >/dev/null 2>&1; then
    print_status "$RED" "Error: Source branch commit $SOURCE_BRANCH_SHA no longer available"
    git checkout -q "$CURRENT_BRANCH" 2>/dev/null || true
    exit 1
fi

# Checkout source branch commit
if ! git checkout -q "$SOURCE_BRANCH_SHA" 2>/dev/null; then
    print_status "$RED" "Error: Could not checkout source branch commit $SOURCE_BRANCH_SHA"
    git checkout -q "$CURRENT_BRANCH" 2>/dev/null || true
    exit 1
fi

# Verify we're on the correct commit
CURRENT_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
if [[ "$CURRENT_SHA" != "$SOURCE_BRANCH_SHA" ]]; then
    print_status "$RED" "Error: Failed to checkout source branch commit. Expected $SOURCE_BRANCH_SHA, got $CURRENT_SHA"
    git checkout -q "$CURRENT_BRANCH" 2>/dev/null || true
    exit 1
fi
print_status "$GREEN" "✓ Checked out source branch commit $SOURCE_BRANCH_SHA"

# Generate incremental deployment package from git delta + optional MR description extra metadata.
# The combined package is written to $PACKAGE_XML_PATH for the compliance package check below.
if [[ -n "${CI_MERGE_REQUEST_DIFF_BASE_SHA:-}" ]] && command -v sf &>/dev/null; then
    if ! git cat-file -e "${CI_MERGE_REQUEST_DIFF_BASE_SHA}^{commit}" 2>/dev/null; then
        print_status "$YELLOW" "Fetching merge-request diff base ${CI_MERGE_REQUEST_DIFF_BASE_SHA:0:8}..."
        git fetch -q origin "${CI_MERGE_REQUEST_DIFF_BASE_SHA}" 2>/dev/null || true
    fi
    if git cat-file -e "${CI_MERGE_REQUEST_DIFF_BASE_SHA}^{commit}" 2>/dev/null; then
        rm -rf package destructiveChanges
        mkdir -p manifest
        print_status "$YELLOW" "Running sf sgd source delta (from diff base to HEAD)..."
        set +e
        sgd_out=$(sf sgd source delta --from "$CI_MERGE_REQUEST_DIFF_BASE_SHA" --output-dir . 2>&1)
        sgd_rc=$?
        set -e
        if [[ $sgd_rc -ne 0 ]]; then
            print_status "$YELLOW" "⚠ sfdx-git-delta failed: $(echo "$sgd_out" | tail -c 400)"
        else
            DELTA_PKG="package/package.xml"
            EXTRA_LIST="_compliance_extra_package.txt"
            EXTRA_XML="_compliance_extra_package.xml"
            HAS_EXTRA=false
            if echo "${CI_MERGE_REQUEST_DESCRIPTION:-}" | grep -q '<Package>'; then
                echo "${CI_MERGE_REQUEST_DESCRIPTION}" | sed -n '/<Package>/,/<\/Package>/p' | sed '1d;$d' > "$EXTRA_LIST"
                if [[ -s "$EXTRA_LIST" ]]; then
                    sf sfpl xml -l "$EXTRA_LIST" -x "$EXTRA_XML" -n 2>/dev/null && HAS_EXTRA=true
                fi
            fi
            DELTA_HAS_TYPES=false
            grep -q '<types>' "$DELTA_PKG" 2>/dev/null && DELTA_HAS_TYPES=true
            if [[ "$DELTA_HAS_TYPES" == "true" ]] && [[ "$HAS_EXTRA" == "true" ]]; then
                sf sfpc combine -f "$DELTA_PKG" -f "$EXTRA_XML" -c "$PACKAGE_XML_PATH" -n
            elif [[ "$HAS_EXTRA" == "true" ]]; then
                cp "$EXTRA_XML" "$PACKAGE_XML_PATH"
            else
                cp "$DELTA_PKG" "$PACKAGE_XML_PATH"
            fi
            rm -f "$EXTRA_LIST" "$EXTRA_XML"
            print_status "$GREEN" "✓ Generated deployment package for compliance check"
        fi
        rm -rf package destructiveChanges
    else
        print_status "$YELLOW" "⚠ Could not resolve CI_MERGE_REQUEST_DIFF_BASE_SHA — skipping package generation"
    fi
else
    if [[ -z "${CI_MERGE_REQUEST_DIFF_BASE_SHA:-}" ]]; then
        print_status "$YELLOW" "⚠ CI_MERGE_REQUEST_DIFF_BASE_SHA not set — skipping package generation"
    else
        print_status "$YELLOW" "⚠ sf CLI not found — skipping package generation"
    fi
fi

# Check if package.xml exists
if [[ ! -f "$PACKAGE_XML_PATH" ]]; then
    print_status "$RED" "✗ Package.xml not found at $PACKAGE_XML_PATH"
    PACKAGE_CHECK_STATUS="error"
    PACKAGE_CHECK_OUTPUT="Package.xml file not found"
else
    print_status "$YELLOW" "Found package.xml at $PACKAGE_XML_PATH"
    
    # Check if package_check.py script exists
    if [[ ! -f "$PACKAGE_CHECK_SCRIPT" ]]; then
        print_status "$RED" "✗ Package check script not found at $PACKAGE_CHECK_SCRIPT"
        PACKAGE_CHECK_STATUS="error"
        PACKAGE_CHECK_OUTPUT="Package check script not found"
    else
        # Check if python3 is available
        if ! command -v python3 &> /dev/null; then
            print_status "$RED" "✗ python3 not found in PATH"
            PACKAGE_CHECK_STATUS="error"
            PACKAGE_CHECK_OUTPUT="python3 not available"
        else
            # Run package_check.py
            print_status "$YELLOW" "Running package_check.py..."
            print_status "$YELLOW" "  Manifest: $PACKAGE_XML_PATH"
            print_status "$YELLOW" "  Stage: $PACKAGE_CHECK_STAGE"
            print_status "$YELLOW" "  Environment: $PACKAGE_CHECK_ENVIRONMENT"
            
            # Capture both stdout and stderr
            PACKAGE_CHECK_OUTPUT=$(python3 "$PACKAGE_CHECK_SCRIPT" \
                -x "$PACKAGE_XML_PATH" \
                -s "$PACKAGE_CHECK_STAGE" \
                -e "$PACKAGE_CHECK_ENVIRONMENT" 2>&1)
            PACKAGE_CHECK_EXIT_CODE=$?
            
            # Extract warnings from output (especially test annotation warnings)
            PACKAGE_CHECK_WARNINGS=$(echo "$PACKAGE_CHECK_OUTPUT" | grep -i "WARNING:" || echo "")
            
            if [[ $PACKAGE_CHECK_EXIT_CODE -eq 0 ]]; then
                print_status "$GREEN" "✓ Package.xml compliance check passed"
                print_status "$YELLOW" "Package check output:"
                echo "$PACKAGE_CHECK_OUTPUT" | while IFS= read -r line; do
                    # Highlight warnings in yellow
                    if echo "$line" | grep -qi "WARNING:"; then
                        print_status "$YELLOW" "  ⚠ $line"
                    else
                        print_status "$YELLOW" "  $line"
                    fi
                done
                
                # Show warnings separately if present
                if [[ -n "$PACKAGE_CHECK_WARNINGS" ]]; then
                    print_status "$YELLOW" "⚠ Package check completed with warnings:"
                    echo "$PACKAGE_CHECK_WARNINGS" | while IFS= read -r warning; do
                        print_status "$YELLOW" "  $warning"
                    done
                fi
                PACKAGE_CHECK_STATUS="success"
            else
                print_status "$RED" "✗ Package.xml compliance check failed"
                print_status "$RED" "Package check output:"
                echo "$PACKAGE_CHECK_OUTPUT" | while IFS= read -r line; do
                    print_status "$RED" "  $line"
                done
                PACKAGE_CHECK_STATUS="failed"
            fi
        fi
    fi
fi

# Restore original branch position
print_status "$YELLOW" "Restoring original branch position..."
git checkout -q "$CURRENT_BRANCH" 2>/dev/null || true

# Check if source branch commits exist in fullqa and develop branches
check_branch_merged() {
    local target_branch=$1
    local source_sha=$2
    local branch_exists=false
    local is_merged=false
    local merge_commit_sha=""
    
    # Check if branch exists
    if git show-ref --verify --quiet "refs/remotes/origin/$target_branch"; then
        branch_exists=true
        # Check if the source commit exists in the target branch
        if git merge-base --is-ancestor "$source_sha" "origin/$target_branch" 2>/dev/null; then
            is_merged=true
            # Find the merge commit that first introduced the source SHA
            # We need to find the actual merge commit that contains the source SHA
            # First try to find merge commits, then fall back to any commit that contains the source SHA
            merge_commit_sha=$(git log --format="%H" --merges "origin/$target_branch" --ancestry-path "$source_sha" 2>/dev/null | tail -1 || \
                git log --format="%H" "origin/$target_branch" --ancestry-path "$source_sha" 2>/dev/null | tail -1 || \
                git rev-parse "origin/$target_branch" 2>/dev/null || echo "")
        fi
    fi
    
    echo "$branch_exists|$is_merged|$merge_commit_sha"
}

# Function to check deployment job status via GitLab API
check_deployment_job_status() {
    local commit_sha=$1
    local job_name=$2
    local access_token=$3
    local project_id=$4
    local server_host=$5
    
    if [[ -z "$commit_sha" ]]; then
        echo "unknown"
        return
    fi
    
    # Remove trailing slash from server host
    local server_host_clean=$(echo "$server_host" | sed 's|/$||')
    local api_url="https://${server_host_clean}/api/v4/projects/${project_id}/pipelines"
    
    # Get pipelines for this commit SHA
    local pipelines_response
    pipelines_response=$(curl -s -w "\n%{http_code}" \
        -H "PRIVATE-TOKEN: ${access_token}" \
        "${api_url}?sha=${commit_sha}&per_page=10" 2>/dev/null)
    
    local pipelines_body=$(echo "$pipelines_response" | sed '$d')
    local pipelines_status=$(echo "$pipelines_response" | tail -n1)
    
    if [[ "$pipelines_status" -lt 200 || "$pipelines_status" -ge 300 ]]; then
        echo "api_error"
        return
    fi
    
    # Find the most recent pipeline that has the deploy job
    if command -v jq &> /dev/null; then
        local pipeline_count
        pipeline_count=$(echo "$pipelines_body" | jq 'length' 2>/dev/null || echo "0")
        
        if [[ "$pipeline_count" -eq 0 ]]; then
            echo "no_pipeline"
            return
        fi
        
        # Check each pipeline (up to 10) to find one with the deploy job
        local pipeline_index=0
        local job_status=""
        while [[ $pipeline_index -lt $pipeline_count && $pipeline_index -lt 10 ]]; do
            local pipeline_id
            pipeline_id=$(echo "$pipelines_body" | jq -r ".[$pipeline_index].id // empty" 2>/dev/null)
            
            if [[ -z "$pipeline_id" ]]; then
                ((pipeline_index++))
                continue
            fi
            
            # Get jobs for this pipeline
            local jobs_url="https://${server_host_clean}/api/v4/projects/${project_id}/pipelines/${pipeline_id}/jobs"
            local jobs_response
            jobs_response=$(curl -s -w "\n%{http_code}" \
                -H "PRIVATE-TOKEN: ${access_token}" \
                "${jobs_url}" 2>/dev/null)
            
            local jobs_body=$(echo "$jobs_response" | sed '$d')
            local jobs_status=$(echo "$jobs_response" | tail -n1)
            
            if [[ "$jobs_status" -ge 200 && "$jobs_status" -lt 300 ]]; then
                # Find the specific job
                job_status=$(echo "$jobs_body" | jq -r ".[] | select(.name == \"${job_name}\") | .status // empty" 2>/dev/null)
                
                if [[ -n "$job_status" ]]; then
                    # Found the job, return its status
                    echo "$job_status"
                    return
                fi
            fi
            
            ((pipeline_index++))
        done
        
        # If we checked all pipelines and didn't find the job
        if [[ -z "$job_status" ]]; then
            echo "job_not_found"
        else
            echo "$job_status"
        fi
    else
        # Fallback without jq - try to parse JSON manually (basic check)
        if echo "$pipelines_body" | grep -q "\"id\""; then
            echo "unknown"  # Can't parse without jq
        else
            echo "no_pipeline"
        fi
    fi
}

if [[ "$MR_MODE" == "main" ]]; then
    print_status "$YELLOW" "Checking fullqa branch..."
    FULLQA_RESULT=$(check_branch_merged "fullqa" "$SOURCE_BRANCH_SHA")
    FULLQA_EXISTS=$(echo "$FULLQA_RESULT" | cut -d'|' -f1)
    FULLQA_MERGED=$(echo "$FULLQA_RESULT" | cut -d'|' -f2)
    FULLQA_MERGE_COMMIT=$(echo "$FULLQA_RESULT" | cut -d'|' -f3)

    print_status "$YELLOW" "Checking develop branch..."
    DEVELOP_RESULT=$(check_branch_merged "develop" "$SOURCE_BRANCH_SHA")
    DEVELOP_EXISTS=$(echo "$DEVELOP_RESULT" | cut -d'|' -f1)
    DEVELOP_MERGED=$(echo "$DEVELOP_RESULT" | cut -d'|' -f2)
    DEVELOP_MERGE_COMMIT=$(echo "$DEVELOP_RESULT" | cut -d'|' -f3)
else
    FULLQA_EXISTS=false
    FULLQA_MERGED=false
    FULLQA_MERGE_COMMIT=""
    DEVELOP_EXISTS=false
    DEVELOP_MERGED=false
    DEVELOP_MERGE_COMMIT=""
fi

CI_SERVER_HOST_CLEAN=$(echo "$CI_SERVER_HOST" | sed 's|/$||')

print_status "$YELLOW" "Checking predeploy validation job ($PREDEPLOY_JOB_NAME) for source branch commit..."
PREDEPLOY_STATUS=$(check_deployment_job_status "$SOURCE_BRANCH_SHA" "$PREDEPLOY_JOB_NAME" "$MAINTAINER_PAT_VALUE" "$CI_PROJECT_ID" "$CI_SERVER_HOST_CLEAN")

if [[ "$PREDEPLOY_STATUS" == "success" ]]; then
    print_status "$GREEN" "✓ Predeploy validation ($PREDEPLOY_JOB_NAME) passed"
elif [[ "$PREDEPLOY_STATUS" == "failed" ]]; then
    print_status "$RED" "✗ Predeploy validation ($PREDEPLOY_JOB_NAME) failed"
elif [[ "$PREDEPLOY_STATUS" == "running" || "$PREDEPLOY_STATUS" == "pending" ]]; then
    print_status "$YELLOW" "⏳ Predeploy validation ($PREDEPLOY_JOB_NAME) in progress"
elif [[ "$PREDEPLOY_STATUS" == "job_not_found" ]]; then
    print_status "$YELLOW" "⚠ Predeploy validation ($PREDEPLOY_JOB_NAME) job not found"
elif [[ "$PREDEPLOY_STATUS" == "no_pipeline" ]]; then
    print_status "$YELLOW" "⚠ Predeploy validation ($PREDEPLOY_JOB_NAME) - no pipeline found"
elif [[ "$PREDEPLOY_STATUS" == "api_error" ]]; then
    print_status "$YELLOW" "⚠ Predeploy validation ($PREDEPLOY_JOB_NAME) - API error"
else
    print_status "$YELLOW" "? Predeploy validation ($PREDEPLOY_JOB_NAME) status unknown ($PREDEPLOY_STATUS)"
fi

# Function to find commits with successful deploy jobs
# Checks multiple commits that contain the source SHA until we find one with a successful deploy
# Returns: "status|commit_sha" format
find_deploy_job_status() {
    local target_branch=$1
    local source_sha=$2
    local job_name=$3
    local access_token=$4
    local project_id=$5
    local server_host=$6
    local source_branch_name=$7  # Source branch name for matching commit messages
    
    # Get commits on the target branch and check if they contain the source SHA
    local commits
    commits=$(git log --format="%H" "origin/$target_branch" 2>/dev/null || echo "")
    
    if [[ -z "$commits" ]]; then
        echo "no_commits|"
        return
    fi
    
    # First pass: Check merge commits that mention the source branch in the commit message
    # These are the commits that actually merged the source branch
    while IFS= read -r commit_sha; do
        if [[ -z "$commit_sha" ]]; then
            continue
        fi
        
        # Check if this commit contains the source SHA and is a merge commit
        if git merge-base --is-ancestor "$source_sha" "$commit_sha" 2>/dev/null; then
            # Check if it's a merge commit (has more than one parent)
            local parent_count
            parent_count=$(git cat-file -p "$commit_sha" 2>/dev/null | grep -c "^parent " || echo "0")
            if [[ "$parent_count" -gt 1 ]]; then
                # Check if commit message mentions the source branch name
                # Match the branch name more precisely to avoid matching similar branch names
                # Look for patterns like "origin/branch" or "'branch'" in commit messages
                local commit_msg
                commit_msg=$(git log -1 --format="%B" "$commit_sha" 2>/dev/null || echo "")
                # Escape special characters in branch name for regex matching
                local escaped_branch
                escaped_branch=$(printf '%s\n' "$source_branch_name" | sed 's/[[\.*^$()+?{|]/\\&/g')
                # Match branch name as part of "origin/branch" pattern (most common in merge commits)
                # or as a whole word (using word boundaries, but handle hyphens specially)
                if echo "$commit_msg" | grep -qiE "origin/${escaped_branch}(['\"]| |\$|/)" || \
                   echo "$commit_msg" | grep -qiE "(^|[^0-9A-Za-z-])${escaped_branch}([^0-9A-Za-z-]|\$)"; then
                    print_status "$YELLOW" "  Checking merge commit $commit_sha (merged source branch)..." >&2
                    local job_status
                    job_status=$(check_deployment_job_status "$commit_sha" "$job_name" "$access_token" "$project_id" "$server_host" 2>/dev/null)
                    
                    # If we found the job (regardless of status), return it with the commit SHA
                    if [[ "$job_status" != "job_not_found" && "$job_status" != "no_pipeline" && "$job_status" != "api_error" && "$job_status" != "unknown" && -n "$job_status" ]]; then
                        echo "$job_status|$commit_sha"
                        return
                    fi
                fi
            fi
        fi
    done <<< "$commits"
    
    # Second pass: Check all merge commits that contain the source SHA
    while IFS= read -r commit_sha; do
        if [[ -z "$commit_sha" ]]; then
            continue
        fi
        
        # Check if this commit contains the source SHA and is a merge commit
        if git merge-base --is-ancestor "$source_sha" "$commit_sha" 2>/dev/null; then
            # Check if it's a merge commit (has more than one parent)
            local parent_count
            parent_count=$(git cat-file -p "$commit_sha" 2>/dev/null | grep -c "^parent " || echo "0")
            if [[ "$parent_count" -gt 1 ]]; then
                print_status "$YELLOW" "  Checking merge commit $commit_sha (contains source SHA)..." >&2
                local job_status
                job_status=$(check_deployment_job_status "$commit_sha" "$job_name" "$access_token" "$project_id" "$server_host" 2>/dev/null)
                
                # If we found the job (regardless of status), return it with the commit SHA
                if [[ "$job_status" != "job_not_found" && "$job_status" != "no_pipeline" && "$job_status" != "api_error" && "$job_status" != "unknown" && -n "$job_status" ]]; then
                    echo "$job_status|$commit_sha"
                    return
                fi
            fi
        fi
    done <<< "$commits"
    
    # Third pass: If no merge commit had the deploy job, check all commits that contain the source SHA
    while IFS= read -r commit_sha; do
        if [[ -z "$commit_sha" ]]; then
            continue
        fi
        
        # Check if this commit contains the source SHA
        if git merge-base --is-ancestor "$source_sha" "$commit_sha" 2>/dev/null; then
            print_status "$YELLOW" "  Checking commit $commit_sha (contains source SHA)..." >&2
            local job_status
            job_status=$(check_deployment_job_status "$commit_sha" "$job_name" "$access_token" "$project_id" "$server_host" 2>/dev/null)
            
            # If we found the job (regardless of status), return it with the commit SHA
            if [[ "$job_status" != "job_not_found" && "$job_status" != "no_pipeline" && "$job_status" != "api_error" && "$job_status" != "unknown" && -n "$job_status" ]]; then
                echo "$job_status|$commit_sha"
                return
            fi
        fi
    done <<< "$commits"
    
    # If we checked all commits and didn't find the job
    echo "job_not_found|"
}

FULLQA_DEPLOY_STATUS=""
DEVELOP_DEPLOY_STATUS=""
FULLQA_DEPLOY_COMMIT=""
DEVELOP_DEPLOY_COMMIT=""

if [[ "$MR_MODE" == "main" ]]; then
    if [[ "$FULLQA_EXISTS" == "true" && "$FULLQA_MERGED" == "true" ]]; then
        print_status "$YELLOW" "Searching for deploy:fullqa job in commits containing source SHA..."
        FULLQA_RESULT=$(find_deploy_job_status "fullqa" "$SOURCE_BRANCH_SHA" "deploy:fullqa" "$MAINTAINER_PAT_VALUE" "$CI_PROJECT_ID" "$CI_SERVER_HOST" "$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME" 2>&1 | grep -v "Checking commit" | tail -1)
        FULLQA_DEPLOY_STATUS=$(echo "$FULLQA_RESULT" | cut -d'|' -f1)
        FULLQA_DEPLOY_COMMIT=$(echo "$FULLQA_RESULT" | cut -d'|' -f2)
        print_status "$YELLOW" "  deploy:fullqa status: $FULLQA_DEPLOY_STATUS"
        if [[ -n "$FULLQA_DEPLOY_COMMIT" ]]; then
            print_status "$YELLOW" "  deploy:fullqa commit: $FULLQA_DEPLOY_COMMIT"
        fi
    fi

    if [[ "$DEVELOP_EXISTS" == "true" && "$DEVELOP_MERGED" == "true" ]]; then
        print_status "$YELLOW" "Searching for deploy:dev job in commits containing source SHA..."
        DEVELOP_RESULT=$(find_deploy_job_status "develop" "$SOURCE_BRANCH_SHA" "deploy:dev" "$MAINTAINER_PAT_VALUE" "$CI_PROJECT_ID" "$CI_SERVER_HOST" "$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME" 2>&1 | grep -v "Checking commit" | tail -1)
        DEVELOP_DEPLOY_STATUS=$(echo "$DEVELOP_RESULT" | cut -d'|' -f1)
        DEVELOP_DEPLOY_COMMIT=$(echo "$DEVELOP_RESULT" | cut -d'|' -f2)
        print_status "$YELLOW" "  deploy:dev status: $DEVELOP_DEPLOY_STATUS"
        if [[ -n "$DEVELOP_DEPLOY_COMMIT" ]]; then
            print_status "$YELLOW" "  deploy:dev commit: $DEVELOP_DEPLOY_COMMIT"
        fi
    fi
fi

# ============================================================================
# RELEASE BRANCH — PER-STORY DEPLOYMENT VERIFICATION
# ============================================================================
# A release branch is any branch that contains merge commits bringing story
# branches INTO it. We support multiple creation styles:
#   - create_release_branch.sh             : "Merging <story> into <release>"
#   - git CLI / VS Code (default)          : "Merge branch '<story>' into <release>"
#   - git CLI remote-tracking              : "Merge remote-tracking branch 'origin/<story>' into <release>"
#   - merging into main/master on CLI      : "Merge branch '<story>'"          (no "into" clause)
#   - GitHub-style PR merge                : "Merge pull request #N from user/<story>"
#
# Detection: scan ALL merge commits on the first-parent path from the main-
# merge-base to the source HEAD. Each such commit is, by construction, a
# merge INTO this branch, so we only need the **second parent** as the story
# HEAD. The subject line is used on a best-effort basis to recover a human-
# readable story name; when we can't parse it we fall back to the short SHA.
#
# Fast-forward merges (no merge commit) and squash merges cannot be detected
# because no merge commit exists to recover the story HEAD from.
#
# If every story HEAD discovered this way was deployed successfully to fullqa
# and develop individually, the release branch is considered compliant even
# if the release-branch HEAD itself was never pushed backwards to those envs.

RELEASE_STORIES=()               # story branch names (best-effort, for display)
RELEASE_STORY_SHAS=()            # story HEAD commit SHAs (authoritative)
RELEASE_STORY_FULLQA=()          # per-story fullqa deploy status
RELEASE_STORY_FULLQA_COMMIT=()   # per-story commit where fullqa deploy was found
RELEASE_STORY_DEVELOP=()         # per-story develop deploy status
RELEASE_STORY_DEVELOP_COMMIT=()  # per-story commit where develop deploy was found

IS_RELEASE_BRANCH=false

# Helper: parse a merge commit's subject line and echo "<story_name>|<release_name>"
# where either part may be empty if it cannot be determined.
parse_merge_subject() {
    local msg=$1
    local story=""
    local release=""

    if [[ "$msg" =~ ^Merging[[:space:]]+(.+)[[:space:]]+into[[:space:]]+([^[:space:]\'\"]+)[[:space:]]*$ ]]; then
        # create_release_branch.sh format
        story="${BASH_REMATCH[1]}"
        release="${BASH_REMATCH[2]}"
    elif [[ "$msg" =~ ^Merge[[:space:]]+remote-tracking[[:space:]]+branch[[:space:]]+[\'\"]([^\'\"]+)[\'\"][[:space:]]+into[[:space:]]+[\'\"]?([^\'\"[:space:]]+)[\'\"]?[[:space:]]*$ ]]; then
        # git CLI when merging a remote-tracking branch
        story="${BASH_REMATCH[1]}"
        release="${BASH_REMATCH[2]}"
    elif [[ "$msg" =~ ^Merge[[:space:]]+branch[[:space:]]+[\'\"]([^\'\"]+)[\'\"][[:space:]]+into[[:space:]]+[\'\"]?([^\'\"[:space:]]+)[\'\"]?[[:space:]]*$ ]]; then
        # git CLI / VS Code default when target != main/master
        story="${BASH_REMATCH[1]}"
        release="${BASH_REMATCH[2]}"
    elif [[ "$msg" =~ ^Merge[[:space:]]+branch[[:space:]]+[\'\"]([^\'\"]+)[\'\"] ]]; then
        # git CLI default when target IS main/master (no "into" clause)
        story="${BASH_REMATCH[1]}"
    elif [[ "$msg" =~ ^Merge[[:space:]]+pull[[:space:]]+request[[:space:]]+\#[0-9]+[[:space:]]+from[[:space:]]+[^[:space:]/]+/([^[:space:]]+) ]]; then
        # GitHub-style PR merge
        story="${BASH_REMATCH[1]}"
    fi

    echo "${story}|${release}"
}

if [[ "$MR_MODE" == "main" ]]; then
    RELEASE_DETECT_BASE="${BRANCH_MERGE_BASE_SHA:-${CI_MERGE_REQUEST_DIFF_BASE_SHA:-}}"

    if [[ -n "$RELEASE_DETECT_BASE" ]]; then
        RELEASE_DETECT_RANGE="${RELEASE_DETECT_BASE}..${SOURCE_BRANCH_SHA}"
        print_status "$YELLOW" "Checking if source is a release branch (scanning first-parent merge commits in ${RELEASE_DETECT_RANGE:0:60})..."

        # All merge commits on the first-parent path of the release branch.
        # --first-parent ensures we don't descend into a merged-in story's own
        # internal merge history (which would produce false positives).
        STORY_MERGE_COMMITS=$(git log --first-parent --merges --format="%H" \
            "$RELEASE_DETECT_RANGE" 2>/dev/null || echo "")

        while IFS= read -r merge_sha; do
            [[ -z "$merge_sha" ]] && continue

            # Second parent = story HEAD at the time of the merge.
            story_sha=$(git rev-parse "${merge_sha}^2" 2>/dev/null || echo "")
            [[ -z "$story_sha" ]] && continue

            merge_msg=$(git log -1 --format="%s" "$merge_sha" 2>/dev/null || echo "")

            parsed=$(parse_merge_subject "$merge_msg")
            story_branch="${parsed%%|*}"
            release_part="${parsed##*|}"

            # Strip optional origin/ prefix on either side
            story_branch="${story_branch#origin/}"
            release_part_stripped="${release_part#origin/}"

            # If the subject includes an "into <release>" clause, verify it
            # points at THIS release branch; a mismatch most likely means a
            # cross-branch merge got pulled in via some other path and we
            # shouldn't attribute it here.
            if [[ -n "$release_part_stripped" && \
                  "$release_part_stripped" != "$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME" ]]; then
                continue
            fi

            # Skip non-story merges. Several patterns are NOT story merges and
            # must never populate RELEASE_STORIES:
            #   (1) sync-from-upstream: "Merge branch 'main' into <release>"
            #       — developer keeping the release branch current against main
            #       (develop/fullqa are covered here too; they're also policy-
            #       forbidden via check_forbidden_merges but we still filter
            #       them so we don't try to deploy-verify them as stories)
            #   (2) self-merge / divergence reconciliation:
            #       "Merge branch '<release>' into <release>"
            #       "Merge remote-tracking branch 'origin/<release>' into <release>"
            #       — e.g. `git pull` on a release branch with local + remote
            #       commits; the second parent is a divergent tip of the SAME
            #       branch, not a story.
            #
            # We apply filters in three layers:
            #   (a) name equals this release branch    -> self-merge
            #   (b) name is a protected/long-lived env -> sync merge
            #   (c) ancestry: second parent already on origin/<default-branch>
            #       -> authoritative catch for anonymous / renamed / parse-failed
            #          cases, including forks of main that have since been merged
            story_branch_lower=$(echo "$story_branch" | tr '[:upper:]' '[:lower:]')
            source_branch_lower=$(echo "$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME" | tr '[:upper:]' '[:lower:]')
            default_branch_lower=$(echo "$CI_DEFAULT_BRANCH" | tr '[:upper:]' '[:lower:]')

            if [[ "$story_branch_lower" == "$source_branch_lower" ]]; then
                # Self-merge of the release branch into itself (divergence
                # reconciliation, e.g. `git pull` with local+remote commits).
                continue
            fi
            case "$story_branch_lower" in
                main|master|develop|fullqa|"$default_branch_lower")
                    continue
                    ;;
            esac
            if git show-ref --verify --quiet "refs/remotes/origin/$CI_DEFAULT_BRANCH" && \
               git merge-base --is-ancestor "$story_sha" "origin/$CI_DEFAULT_BRANCH" 2>/dev/null; then
                # The "story" HEAD is already contained in the default branch,
                # so this merge was actually main → release, not a story merge.
                continue
            fi

            # If we couldn't recover a story name (squash-style message, etc.),
            # fall back to the short SHA so the line still shows up.
            if [[ -z "$story_branch" ]]; then
                story_branch="unknown-${story_sha:0:8}"
            fi

            # De-duplicate by story name (a story could be merged twice).
            already_seen=false
            if [[ ${#RELEASE_STORIES[@]} -gt 0 ]]; then
                for existing in "${RELEASE_STORIES[@]}"; do
                    if [[ "$existing" == "$story_branch" ]]; then
                        already_seen=true
                        break
                    fi
                done
            fi
            if [[ "$already_seen" == "true" ]]; then
                continue
            fi

            RELEASE_STORIES+=("$story_branch")
            RELEASE_STORY_SHAS+=("$story_sha")
        done <<< "$STORY_MERGE_COMMITS"

        if [[ ${#RELEASE_STORIES[@]} -gt 0 ]]; then
            IS_RELEASE_BRANCH=true
            print_status "$GREEN" "✓ Source branch identified as a release branch (${#RELEASE_STORIES[@]} story branch(es) merged in)"
        else
            print_status "$YELLOW" "Source branch is not a release branch (no first-parent merge commits found in range)"
        fi
    else
        print_status "$YELLOW" "⚠ Cannot determine release-branch range (no merge-base with default branch); skipping per-story checks"
    fi

    # Verify per-story deployments
    if [[ "$IS_RELEASE_BRANCH" == "true" ]]; then
        for i in "${!RELEASE_STORIES[@]}"; do
            story_name="${RELEASE_STORIES[$i]}"
            story_sha="${RELEASE_STORY_SHAS[$i]}"

            print_status "$YELLOW" "  → Verifying deploys for story branch '$story_name' (${story_sha:0:8})"

            # --- fullqa ---
            story_fullqa_status=""
            story_fullqa_commit=""
            if git show-ref --verify --quiet "refs/remotes/origin/fullqa" && \
               git merge-base --is-ancestor "$story_sha" "origin/fullqa" 2>/dev/null; then
                RES=$(find_deploy_job_status "fullqa" "$story_sha" "deploy:fullqa" "$MAINTAINER_PAT_VALUE" "$CI_PROJECT_ID" "$CI_SERVER_HOST" "$story_name" 2>&1 | grep -v "Checking commit" | tail -1)
                story_fullqa_status=$(echo "$RES" | cut -d'|' -f1)
                story_fullqa_commit=$(echo "$RES" | cut -d'|' -f2)
            else
                story_fullqa_status="not_merged"
            fi
            RELEASE_STORY_FULLQA+=("$story_fullqa_status")
            RELEASE_STORY_FULLQA_COMMIT+=("$story_fullqa_commit")

            # --- develop ---
            story_dev_status=""
            story_dev_commit=""
            if git show-ref --verify --quiet "refs/remotes/origin/develop" && \
               git merge-base --is-ancestor "$story_sha" "origin/develop" 2>/dev/null; then
                RES=$(find_deploy_job_status "develop" "$story_sha" "deploy:dev" "$MAINTAINER_PAT_VALUE" "$CI_PROJECT_ID" "$CI_SERVER_HOST" "$story_name" 2>&1 | grep -v "Checking commit" | tail -1)
                story_dev_status=$(echo "$RES" | cut -d'|' -f1)
                story_dev_commit=$(echo "$RES" | cut -d'|' -f2)
            else
                story_dev_status="not_merged"
            fi
            RELEASE_STORY_DEVELOP+=("$story_dev_status")
            RELEASE_STORY_DEVELOP_COMMIT+=("$story_dev_commit")

            print_status "$YELLOW" "    [$story_name] fullqa=${story_fullqa_status:-?} dev=${story_dev_status:-?}"
        done
    fi
fi

# Aggregate: did every story deploy successfully to both lower envs?
ALL_STORIES_DEPLOYED=false
if [[ "$IS_RELEASE_BRANCH" == "true" && ${#RELEASE_STORIES[@]} -gt 0 ]]; then
    ALL_STORIES_DEPLOYED=true
    for i in "${!RELEASE_STORIES[@]}"; do
        if [[ "${RELEASE_STORY_FULLQA[$i]}" != "success" || "${RELEASE_STORY_DEVELOP[$i]}" != "success" ]]; then
            ALL_STORIES_DEPLOYED=false
            break
        fi
    done
fi

# Use pipeline trigger user for @-mention (GitLab notifies mentioned users)
# GITLAB_USER_LOGIN: username of user who started the pipeline (or manual job)
NOTIFY_USER="${GITLAB_USER_LOGIN:-}"

# Build the comment message (using actual newlines)
COMMENT_BODY="## Branch Compliance Verification

**Source Branch:** \`$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME\`
**Source SHA:** \`${SOURCE_BRANCH_SHA:0:8}\`
**Target Branch:** \`$CI_MERGE_REQUEST_TARGET_BRANCH_NAME\`

### Verification Results

"

# Branch name check
if [[ "$BRANCH_NAME_STATUS" == "valid" ]]; then
    COMMENT_BODY+="- :white_check_mark: **Branch Name**: Matches a configured prefix in \`VALID_BRANCH_PREFIXES\`"$'\n'
elif [[ "$BRANCH_NAME_STATUS" == "invalid" ]]; then
    COMMENT_BODY+="- :x: **Branch Name**: Does not match any prefix in \`VALID_BRANCH_PREFIXES\` (\`${VALID_BRANCH_PREFIXES}\`)"$'\n'
else
    COMMENT_BODY+="- :information_source: **Branch Name**: Check skipped (\`VALID_BRANCH_PREFIXES\` not set)"$'\n'
fi

# Branch age check
if [[ "$BRANCH_AGE_STATUS" == "recent" ]]; then
    COMMENT_BODY+="- :white_check_mark: **Branch Age**: Source branch created from default branch $BRANCH_AGE_DAYS days ago (within 30 days)"$'\n'
elif [[ "$BRANCH_AGE_STATUS" == "old" ]]; then
    COMMENT_BODY+="- :x: **Branch Age**: Source branch created from default branch $BRANCH_AGE_DAYS days ago (over 30 days old)"$'\n'
else
    COMMENT_BODY+="- :warning: **Branch Age**: Could not determine branch age"$'\n'
fi

# Forbidden merge check
if [[ "$FORBIDDEN_MERGE_STATUS" == "clean" ]]; then
    COMMENT_BODY+="- :white_check_mark: **Forbidden Merges**: No merges from fullqa/develop into source branch"$'\n'
elif [[ "$FORBIDDEN_MERGE_STATUS" == "forbidden_merge" ]]; then
    if [[ -n "$FORBIDDEN_MERGE_COMMITS" ]]; then
        # Format commit SHAs (first 8 chars) for display
        commit_list=""
        IFS=',' read -ra COMMITS <<< "$FORBIDDEN_MERGE_COMMITS"
        for commit in "${COMMITS[@]}"; do
            if [[ -n "$commit_list" ]]; then
                commit_list+=", "
            fi
            commit_list+="\`${commit:0:8}\`"
        done
        COMMENT_BODY+="- :x: **Forbidden Merges**: Source branch contains merge commits from fullqa/develop (commit(s): $commit_list)"$'\n'
    else
        COMMENT_BODY+="- :x: **Forbidden Merges**: Source branch contains merge commits from fullqa/develop"$'\n'
    fi
else
    COMMENT_BODY+="- :warning: **Forbidden Merges**: Could not check for forbidden merges"$'\n'
fi

# Source lineage (branched from main vs develop/fullqa)
if [[ "$SOURCE_ORIGIN_STATUS" == "clean" ]]; then
    COMMENT_BODY+="- :white_check_mark: **Source from main**: No merge-into-develop/fullqa commits"$'\n'
elif [[ "$SOURCE_ORIGIN_STATUS" == "branch_from_sandbox" ]]; then
    commit_list=""
    IFS=',' read -ra COMMITS <<< "$SOURCE_ORIGIN_COMMITS"
    for c in "${COMMITS[@]}"; do
        [[ -n "$commit_list" ]] && commit_list+=", "
        commit_list+="\`${c:0:8}\`"
    done
    COMMENT_BODY+="- :x: **Source from main**: Contains merge(s) into develop/fullqa - likely branched from sandbox ($commit_list)"$'\n'
else
    COMMENT_BODY+="- :warning: **Source from main**: Check could not be run"$'\n'
fi

if [[ "$MR_MODE" == "main" ]]; then
    if [[ "$MERGE_CONFLICT_STATUS" == "no_conflicts" ]]; then
        COMMENT_BODY+="- :white_check_mark: **Merge Conflicts**: No conflicts between source and target branch"$'\n'
    elif [[ "$MERGE_CONFLICT_STATUS" == "acceptable_conflicts" ]]; then
        COMMENT_BODY+="- :white_check_mark: **Merge Conflicts**: Conflicts found, but only in manifest/package.xml (acceptable)"$'\n'
    elif [[ "$MERGE_CONFLICT_STATUS" == "conflicts" ]]; then
        if [[ -n "$MERGE_CONFLICT_FILES" ]]; then
            file_list=""
            IFS=',' read -ra FILES <<< "$MERGE_CONFLICT_FILES"
            for file in "${FILES[@]}"; do
                if [[ -n "$file_list" ]]; then
                    file_list+=", "
                fi
                file_list+="\`$file\`"
            done
            COMMENT_BODY+="- :x: **Merge Conflicts**: Conflicts detected between source and target branch (file(s): $file_list)"$'\n'
        else
            COMMENT_BODY+="- :x: **Merge Conflicts**: Conflicts detected between source and target branch"$'\n'
        fi
    else
        COMMENT_BODY+="- :warning: **Merge Conflicts**: Could not check for merge conflicts"$'\n'
    fi
fi

if [[ "$PREDEPLOY_STATUS" == "success" ]]; then
    COMMENT_BODY+="- :white_check_mark: **Predeploy (\`$PREDEPLOY_JOB_NAME\`)**: Job passed"$'\n'
elif [[ "$PREDEPLOY_STATUS" == "failed" ]]; then
    COMMENT_BODY+="- :x: **Predeploy (\`$PREDEPLOY_JOB_NAME\`)**: Job failed"$'\n'
elif [[ "$PREDEPLOY_STATUS" == "running" || "$PREDEPLOY_STATUS" == "pending" ]]; then
    COMMENT_BODY+="- :hourglass: **Predeploy (\`$PREDEPLOY_JOB_NAME\`)**: In progress"$'\n'
elif [[ "$PREDEPLOY_STATUS" == "job_not_found" ]]; then
    COMMENT_BODY+="- :warning: **Predeploy (\`$PREDEPLOY_JOB_NAME\`)**: Job not found"$'\n'
elif [[ "$PREDEPLOY_STATUS" == "no_pipeline" ]]; then
    COMMENT_BODY+="- :warning: **Predeploy (\`$PREDEPLOY_JOB_NAME\`)**: No pipeline found"$'\n'
elif [[ "$PREDEPLOY_STATUS" == "api_error" ]]; then
    COMMENT_BODY+="- :warning: **Predeploy (\`$PREDEPLOY_JOB_NAME\`)**: API error"$'\n'
else
    COMMENT_BODY+="- :question: **Predeploy (\`$PREDEPLOY_JOB_NAME\`)**: Status unknown ($PREDEPLOY_STATUS)"$'\n'
fi

# Package.xml compliance check
if [[ "$PACKAGE_CHECK_STATUS" == "success" ]]; then
    # Extract test classes from output (package_check.py prints test classes as last line via print())
    # Get the last line and trim whitespace
    TEST_CLASSES=$(echo "$PACKAGE_CHECK_OUTPUT" | tail -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || echo "")
    
    # Check if there are warnings (especially test annotation warnings)
    if [[ -n "$PACKAGE_CHECK_WARNINGS" ]]; then
        # Count test annotation related warnings
        TEST_ANNOTATION_WARNINGS=$(echo "$PACKAGE_CHECK_WARNINGS" | grep -i "test annotation\|test class" || echo "")
        
        if [[ -n "$TEST_CLASSES" && "$TEST_CLASSES" != "not a test" && "$TEST_CLASSES" != *"ERROR"* && "$TEST_CLASSES" != *"Apex Tests"* ]]; then
            # Format test classes for display (limit length if too long)
            if [[ ${#TEST_CLASSES} -gt 100 ]]; then
                TEST_CLASSES_SHORT="${TEST_CLASSES:0:97}..."
                COMMENT_BODY+="- :white_check_mark: **Package.xml Compliance**: Check passed (Test classes: \`$TEST_CLASSES_SHORT\`)"$'\n'
            else
                COMMENT_BODY+="- :white_check_mark: **Package.xml Compliance**: Check passed (Test classes: \`$TEST_CLASSES\`)"$'\n'
            fi
        else
            COMMENT_BODY+="- :white_check_mark: **Package.xml Compliance**: Check passed"$'\n'
        fi
        
        # Add warnings section - prioritize test annotation warnings
        if [[ -n "$TEST_ANNOTATION_WARNINGS" ]]; then
            COMMENT_BODY+="  - :warning: **Test Annotation Warnings**: "$'\n'
            # Build warnings list using process substitution to avoid subshell issues
            WARNINGS_LIST=""
            while IFS= read -r warning; do
                # Clean up warning message for display (remove "WARNING:" prefix if present)
                CLEAN_WARNING=$(echo "$warning" | sed 's/^[[:space:]]*WARNING:[[:space:]]*//i' | cut -c1-150)
                if [[ -n "$CLEAN_WARNING" ]]; then
                    if [[ -n "$WARNINGS_LIST" ]]; then
                        WARNINGS_LIST+=$'\n'
                    fi
                    WARNINGS_LIST+="    - \`$CLEAN_WARNING\`"
                fi
            done <<< "$TEST_ANNOTATION_WARNINGS"
            COMMENT_BODY+="$WARNINGS_LIST"$'\n'
        fi
        
        # Add other warnings if any
        OTHER_WARNINGS=$(echo "$PACKAGE_CHECK_WARNINGS" | grep -vi "test annotation\|test class" || echo "")
        if [[ -n "$OTHER_WARNINGS" ]]; then
            COMMENT_BODY+="  - :warning: **Other Warnings**: "$'\n'
            WARNINGS_LIST=""
            while IFS= read -r warning; do
                CLEAN_WARNING=$(echo "$warning" | sed 's/^[[:space:]]*WARNING:[[:space:]]*//i' | cut -c1-150)
                if [[ -n "$CLEAN_WARNING" ]]; then
                    if [[ -n "$WARNINGS_LIST" ]]; then
                        WARNINGS_LIST+=$'\n'
                    fi
                    WARNINGS_LIST+="    - \`$CLEAN_WARNING\`"
                fi
            done <<< "$OTHER_WARNINGS"
            COMMENT_BODY+="$WARNINGS_LIST"$'\n'
        fi
    else
        # No warnings - standard success message
        if [[ -n "$TEST_CLASSES" && "$TEST_CLASSES" != "not a test" && "$TEST_CLASSES" != *"ERROR"* && "$TEST_CLASSES" != *"Apex Tests"* ]]; then
            # Format test classes for display (limit length if too long)
            if [[ ${#TEST_CLASSES} -gt 100 ]]; then
                TEST_CLASSES_SHORT="${TEST_CLASSES:0:97}..."
                COMMENT_BODY+="- :white_check_mark: **Package.xml Compliance**: Check passed (Test classes: \`$TEST_CLASSES_SHORT\`)"$'\n'
            else
                COMMENT_BODY+="- :white_check_mark: **Package.xml Compliance**: Check passed (Test classes: \`$TEST_CLASSES\`)"$'\n'
            fi
        else
            COMMENT_BODY+="- :white_check_mark: **Package.xml Compliance**: Check passed"$'\n'
        fi
    fi
elif [[ "$PACKAGE_CHECK_STATUS" == "failed" ]]; then
    # Extract error message (first error line, limit length)
    ERROR_MSG=$(echo "$PACKAGE_CHECK_OUTPUT" | grep -i "ERROR" | head -1 | cut -c1-200 || echo "Package.xml compliance check failed")
    COMMENT_BODY+="- :x: **Package.xml Compliance**: Check failed - $ERROR_MSG"$'\n'
elif [[ "$PACKAGE_CHECK_STATUS" == "error" ]]; then
    # Limit error message length for display
    ERROR_DISPLAY=$(echo "$PACKAGE_CHECK_OUTPUT" | cut -c1-200 || echo "$PACKAGE_CHECK_OUTPUT")
    COMMENT_BODY+="- :warning: **Package.xml Compliance**: Could not perform check - $ERROR_DISPLAY"$'\n'
else
    COMMENT_BODY+="- :warning: **Package.xml Compliance**: Check status unknown"$'\n'
fi

if [[ "$MR_MODE" == "main" ]]; then
if [[ "$FULLQA_EXISTS" == "true" ]]; then
    if [[ "$FULLQA_MERGED" == "true" ]]; then
        if [[ "$FULLQA_DEPLOY_STATUS" == "success" ]]; then
            if [[ -n "$FULLQA_DEPLOY_COMMIT" ]]; then
                COMMENT_BODY+="- :white_check_mark: **fullqa**: Merged and deployed successfully (commit: \`${FULLQA_DEPLOY_COMMIT:0:8}\`)"$'\n'
            else
                COMMENT_BODY+="- :white_check_mark: **fullqa**: Merged and deployed successfully"$'\n'
            fi
            print_status "$GREEN" "✓ fullqa: Merged and deployed successfully"
        elif [[ "$FULLQA_DEPLOY_STATUS" == "failed" ]]; then
            if [[ -n "$FULLQA_DEPLOY_COMMIT" ]]; then
                COMMENT_BODY+="- :x: **fullqa**: Merged but deployment failed (commit: \`${FULLQA_DEPLOY_COMMIT:0:8}\`)"$'\n'
            else
                COMMENT_BODY+="- :x: **fullqa**: Merged but deployment failed"$'\n'
            fi
            print_status "$RED" "✗ fullqa: Merged but deployment failed"
        elif [[ "$FULLQA_DEPLOY_STATUS" == "running" || "$FULLQA_DEPLOY_STATUS" == "pending" ]]; then
            COMMENT_BODY+="- :hourglass: **fullqa**: Merged, deployment in progress"$'\n'
            print_status "$YELLOW" "⏳ fullqa: Merged, deployment in progress"
        elif [[ "$FULLQA_DEPLOY_STATUS" == "job_not_found" ]]; then
            COMMENT_BODY+="- :warning: **fullqa**: Merged but deploy job not found"$'\n'
            print_status "$YELLOW" "⚠ fullqa: Merged but deploy job not found"
        elif [[ "$FULLQA_DEPLOY_STATUS" == "no_pipeline" ]]; then
            COMMENT_BODY+="- :warning: **fullqa**: Merged but no pipeline found"$'\n'
            print_status "$YELLOW" "⚠ fullqa: Merged but no pipeline found"
        else
            COMMENT_BODY+="- :question: **fullqa**: Merged, deployment status unknown ($FULLQA_DEPLOY_STATUS)"$'\n'
            print_status "$YELLOW" "? fullqa: Merged, deployment status unknown"
        fi
    else
        COMMENT_BODY+="- :x: **fullqa**: Not merged"$'\n'
        print_status "$RED" "✗ fullqa: Not merged"
    fi
else
    COMMENT_BODY+="- :warning: **fullqa**: Branch does not exist"$'\n'
    print_status "$YELLOW" "⚠ fullqa: Branch does not exist"
fi

# Develop status
if [[ "$DEVELOP_EXISTS" == "true" ]]; then
    if [[ "$DEVELOP_MERGED" == "true" ]]; then
        if [[ "$DEVELOP_DEPLOY_STATUS" == "success" ]]; then
            if [[ -n "$DEVELOP_DEPLOY_COMMIT" ]]; then
                COMMENT_BODY+="- :white_check_mark: **develop**: Merged and deployed successfully (commit: \`${DEVELOP_DEPLOY_COMMIT:0:8}\`)"$'\n'
            else
                COMMENT_BODY+="- :white_check_mark: **develop**: Merged and deployed successfully"$'\n'
            fi
            print_status "$GREEN" "✓ develop: Merged and deployed successfully"
        elif [[ "$DEVELOP_DEPLOY_STATUS" == "failed" ]]; then
            if [[ -n "$DEVELOP_DEPLOY_COMMIT" ]]; then
                COMMENT_BODY+="- :x: **develop**: Merged but deployment failed (commit: \`${DEVELOP_DEPLOY_COMMIT:0:8}\`)"$'\n'
            else
                COMMENT_BODY+="- :x: **develop**: Merged but deployment failed"$'\n'
            fi
            print_status "$RED" "✗ develop: Merged but deployment failed"
        elif [[ "$DEVELOP_DEPLOY_STATUS" == "running" || "$DEVELOP_DEPLOY_STATUS" == "pending" ]]; then
            COMMENT_BODY+="- :hourglass: **develop**: Merged, deployment in progress"$'\n'
            print_status "$YELLOW" "⏳ develop: Merged, deployment in progress"
        elif [[ "$DEVELOP_DEPLOY_STATUS" == "job_not_found" ]]; then
            COMMENT_BODY+="- :warning: **develop**: Merged but deploy job not found"$'\n'
            print_status "$YELLOW" "⚠ develop: Merged but deploy job not found"
        elif [[ "$DEVELOP_DEPLOY_STATUS" == "no_pipeline" ]]; then
            COMMENT_BODY+="- :warning: **develop**: Merged but no pipeline found"$'\n'
            print_status "$YELLOW" "⚠ develop: Merged but no pipeline found"
        else
            COMMENT_BODY+="- :question: **develop**: Merged, deployment status unknown ($DEVELOP_DEPLOY_STATUS)"$'\n'
            print_status "$YELLOW" "? develop: Merged, deployment status unknown"
        fi
    else
        COMMENT_BODY+="- :x: **develop**: Not merged"$'\n'
        print_status "$RED" "✗ develop: Not merged"
    fi
else
    COMMENT_BODY+="- :warning: **develop**: Branch does not exist"$'\n'
    print_status "$YELLOW" "⚠ develop: Branch does not exist"
fi

# --- Release branch: per-story deployment breakdown ---
if [[ "$IS_RELEASE_BRANCH" == "true" ]]; then
    COMMENT_BODY+=$'\n'"### Release Branch — Story Branch Deployment Verification"$'\n'
    COMMENT_BODY+="Source branch appears to be a release branch. Each story branch merged in is verified individually below."$'\n'
    COMMENT_BODY+="> If every story branch was deployed successfully to fullqa and develop, the release branch itself does **not** need to be deployed backwards to those envs."$'\n\n'

    if [[ "$ALL_STORIES_DEPLOYED" == "true" ]]; then
        COMMENT_BODY+="- :white_check_mark: **All ${#RELEASE_STORIES[@]} story branch(es) deployed successfully to fullqa and develop**"$'\n'
    else
        COMMENT_BODY+="- :warning: **Not all story branches are successfully deployed to fullqa and develop (see details below)**"$'\n'
    fi

    for i in "${!RELEASE_STORIES[@]}"; do
        story_name="${RELEASE_STORIES[$i]}"
        story_sha="${RELEASE_STORY_SHAS[$i]}"
        fq_status="${RELEASE_STORY_FULLQA[$i]}"
        fq_commit="${RELEASE_STORY_FULLQA_COMMIT[$i]}"
        dv_status="${RELEASE_STORY_DEVELOP[$i]}"
        dv_commit="${RELEASE_STORY_DEVELOP_COMMIT[$i]}"

        COMMENT_BODY+="- **\`$story_name\`** (story HEAD: \`${story_sha:0:8}\`)"$'\n'

        # fullqa line
        case "$fq_status" in
            success)
                if [[ -n "$fq_commit" ]]; then
                    COMMENT_BODY+="  - :white_check_mark: **fullqa**: Deployed successfully (commit: \`${fq_commit:0:8}\`)"$'\n'
                else
                    COMMENT_BODY+="  - :white_check_mark: **fullqa**: Deployed successfully"$'\n'
                fi
                ;;
            failed)
                if [[ -n "$fq_commit" ]]; then
                    COMMENT_BODY+="  - :x: **fullqa**: Deployment failed (commit: \`${fq_commit:0:8}\`)"$'\n'
                else
                    COMMENT_BODY+="  - :x: **fullqa**: Deployment failed"$'\n'
                fi
                ;;
            running|pending)
                COMMENT_BODY+="  - :hourglass: **fullqa**: Deployment in progress"$'\n'
                ;;
            not_merged)
                COMMENT_BODY+="  - :x: **fullqa**: Story HEAD not merged into fullqa"$'\n'
                ;;
            job_not_found|no_pipeline)
                COMMENT_BODY+="  - :warning: **fullqa**: Deploy job not found for any ancestor commit"$'\n'
                ;;
            *)
                COMMENT_BODY+="  - :question: **fullqa**: Deploy status unknown (${fq_status:-?})"$'\n'
                ;;
        esac

        # develop line
        case "$dv_status" in
            success)
                if [[ -n "$dv_commit" ]]; then
                    COMMENT_BODY+="  - :white_check_mark: **develop**: Deployed successfully (commit: \`${dv_commit:0:8}\`)"$'\n'
                else
                    COMMENT_BODY+="  - :white_check_mark: **develop**: Deployed successfully"$'\n'
                fi
                ;;
            failed)
                if [[ -n "$dv_commit" ]]; then
                    COMMENT_BODY+="  - :x: **develop**: Deployment failed (commit: \`${dv_commit:0:8}\`)"$'\n'
                else
                    COMMENT_BODY+="  - :x: **develop**: Deployment failed"$'\n'
                fi
                ;;
            running|pending)
                COMMENT_BODY+="  - :hourglass: **develop**: Deployment in progress"$'\n'
                ;;
            not_merged)
                COMMENT_BODY+="  - :x: **develop**: Story HEAD not merged into develop"$'\n'
                ;;
            job_not_found|no_pipeline)
                COMMENT_BODY+="  - :warning: **develop**: Deploy job not found for any ancestor commit"$'\n'
                ;;
            *)
                COMMENT_BODY+="  - :question: **develop**: Deploy status unknown (${dv_status:-?})"$'\n'
                ;;
        esac
    done
fi
fi

COMMENT_BODY+=$'\n'"---"$'\n'
COMMENT_BODY+="*AI-Automated compliance check for $CI_MERGE_REQUEST_TARGET_BRANCH_NAME MRs. Fix issues before merging into $CI_MERGE_REQUEST_TARGET_BRANCH_NAME.*"
if [[ -n "$NOTIFY_USER" ]]; then
    COMMENT_BODY+=$'\n\n'"cc @${NOTIFY_USER}"
fi

# GitLab API base URL for merge request notes
API_URL="https://${CI_SERVER_HOST_CLEAN}/api/v4/projects/${CI_PROJECT_ID}/merge_requests/${CI_MERGE_REQUEST_IID}/notes"

# ============================================================================
# DELETE PREVIOUS VERIFICATION COMMENTS (match by header, not author)
# ============================================================================
# Target by comment header only so this works when the bot token/user changes.
# The unique header identifies our verification comments regardless of who posted them.
print_status "$YELLOW" "Checking for previous verification comments to delete..."

NOTES_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -H "PRIVATE-TOKEN: ${MAINTAINER_PAT_VALUE}" \
    "${API_URL}?per_page=100" 2>&1)

NOTES_BODY=$(echo "$NOTES_RESPONSE" | sed '$d')
NOTES_STATUS=$(echo "$NOTES_RESPONSE" | tail -n1)

if [[ "$NOTES_STATUS" -ge 200 && "$NOTES_STATUS" -lt 300 ]]; then
    DELETED_COUNT=0

    if command -v jq &> /dev/null; then
        # Find notes containing our verification header (any author - resilient to bot token rotation)
        NOTE_IDS=$(echo "$NOTES_BODY" | jq -r '.[] | select(.body | contains("Branch Compliance Verification") or contains("Branch Deployment Verification") or contains("MR Branch Compliance (fullqa/develop)")) | .id' 2>/dev/null | tr -d '\r' || echo "")

        if [[ -n "$NOTE_IDS" ]]; then
            while IFS= read -r note_id; do
                note_id=$(echo "$note_id" | tr -d '\r')
                if [[ -n "$note_id" && "$note_id" != "null" ]]; then
                    print_status "$YELLOW" "  Deleting previous comment ID: $note_id"

                    DELETE_RESPONSE=$(curl -s -w "\n%{http_code}" \
                        -X DELETE \
                        -H "PRIVATE-TOKEN: ${MAINTAINER_PAT_VALUE}" \
                        "${API_URL}/${note_id}" 2>&1)

                    DELETE_STATUS=$(echo "$DELETE_RESPONSE" | tail -n1)

                    if [[ "$DELETE_STATUS" -ge 200 && "$DELETE_STATUS" -lt 300 ]] || [[ "$DELETE_STATUS" == "204" ]]; then
                        DELETED_COUNT=$((DELETED_COUNT + 1))
                        print_status "$GREEN" "    ✓ Deleted comment $note_id"
                    else
                        print_status "$YELLOW" "    ⚠ Failed to delete comment $note_id (HTTP $DELETE_STATUS)"
                    fi
                fi
            done <<< "$NOTE_IDS"
        fi
    else
        print_status "$YELLOW" "  ⚠ jq not available, skipping comment deletion"
    fi

    if [[ $DELETED_COUNT -gt 0 ]]; then
        print_status "$GREEN" "✓ Deleted $DELETED_COUNT previous verification comment(s)"
    else
        print_status "$YELLOW" "No previous verification comments found to delete"
    fi
else
    print_status "$YELLOW" "⚠ Could not fetch existing comments (HTTP $NOTES_STATUS)"
fi

# ============================================================================
# POST NEW COMMENT
# ============================================================================

# Prepare JSON payload for GitLab API
# Use jq if available for proper JSON encoding, otherwise use printf
if command -v jq &> /dev/null; then
    JSON_PAYLOAD=$(jq -n --arg body "$COMMENT_BODY" '{body: $body}')
else
    # Fallback: manual JSON encoding (escape backslashes, quotes, and newlines)
    ESCAPED_BODY=$(printf '%s' "$COMMENT_BODY" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/\r/\\r/g')
    JSON_PAYLOAD="{\"body\":\"$ESCAPED_BODY\"}"
fi

print_status "$YELLOW" "Posting new comment to merge request..."
print_status "$YELLOW" "API URL: $API_URL"

# Post comment to GitLab MR using project access token
HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "PRIVATE-TOKEN: ${MAINTAINER_PAT_VALUE}" \
    -H "Content-Type: application/json" \
    -d "$JSON_PAYLOAD" \
    "$API_URL" 2>&1)

HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n1)

if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -lt 300 ]]; then
    print_status "$GREEN" "✓ Successfully posted comment to merge request (HTTP $HTTP_STATUS)"
    if command -v jq &> /dev/null; then
        COMMENT_ID=$(echo "$HTTP_BODY" | jq -r '.id // empty')
        if [[ -n "$COMMENT_ID" ]]; then
            print_status "$GREEN" "Comment ID: $COMMENT_ID"
        fi
    fi
else
    print_status "$RED" "✗ Failed to post comment to merge request (HTTP $HTTP_STATUS)"
    print_status "$RED" "Response: $HTTP_BODY"
    exit 1
fi

print_status "$GREEN" "\n=== Verification Summary ==="
if [[ "$MR_MODE" == "main" ]]; then
    RELEASE_HEAD_DEPLOYED=false
    if [[ "$FULLQA_EXISTS" == "true" && "$FULLQA_MERGED" == "true" && "$FULLQA_DEPLOY_STATUS" == "success" ]] && \
       [[ "$DEVELOP_EXISTS" == "true" && "$DEVELOP_MERGED" == "true" && "$DEVELOP_DEPLOY_STATUS" == "success" ]]; then
        RELEASE_HEAD_DEPLOYED=true
    fi

    if [[ "$IS_RELEASE_BRANCH" == "true" ]]; then
        # For release branches the HEAD does not have to be deployed backwards
        # if every individual story branch was already deployed to both envs.
        if [[ "$RELEASE_HEAD_DEPLOYED" == "true" ]]; then
            print_status "$GREEN" "✓ Release branch and all lower-env deployments verified successfully!"
        elif [[ "$ALL_STORIES_DEPLOYED" == "true" ]]; then
            print_status "$GREEN" "✓ All ${#RELEASE_STORIES[@]} story branch(es) deployed successfully to fullqa and develop"
            print_status "$GREEN" "  Release branch HEAD is not required to be deployed to lower envs."
        else
            print_status "$YELLOW" "⚠ Release branch: some story branches are not yet deployed successfully to fullqa/develop"
        fi
    else
        if [[ "$RELEASE_HEAD_DEPLOYED" == "true" ]]; then
            print_status "$GREEN" "✓ All branches verified and deployed successfully!"
        elif [[ "$FULLQA_EXISTS" == "true" && "$FULLQA_MERGED" == "true" ]] && \
             [[ "$DEVELOP_EXISTS" == "true" && "$DEVELOP_MERGED" == "true" ]]; then
            print_status "$YELLOW" "⚠ Branches merged but deployments may not be complete"
        else
            print_status "$YELLOW" "⚠ Some branches are not yet merged or deployed"
        fi
    fi
else
    print_status "$GREEN" "MR branch compliance check complete."
fi
exit 0
