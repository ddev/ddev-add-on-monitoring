#!/usr/bin/env bash

# This bash script monitors DDEV add-on repositories for disabled test workflows
# and sends notifications to repository owners when workflows are suspended.
# Uses GitHub issues for tracking notification history to avoid external state.
# `./notify-addon-owners.sh --github-token=<token> --dry-run`

set -eu -o pipefail

# Configuration
MAX_NOTIFICATIONS=${MAX_NOTIFICATIONS:-2}
NOTIFICATION_INTERVAL_DAYS=${NOTIFICATION_INTERVAL_DAYS:-30}
RENOTIFICATION_COOLDOWN_DAYS=${RENOTIFICATION_COOLDOWN_DAYS:-60}

# Initialize variables
GITHUB_TOKEN=""
org="all"  # Default to check all organizations
additional_github_repos=""
DRY_RUN=false
EXIT_CODE=0
RATE_LIMIT_REMAINING=5000  # Default to 5000 requests/hour

# Loop through arguments and process them
for arg in "$@"
do
    case $arg in
        --github-token=*)
        GITHUB_TOKEN="${arg#*=}"
        shift # Remove processed argument
        ;;
        --org=*)
        org="${arg#*=}"
        shift # Remove processed argument
        ;;
        --additional-github-repos=*)
        additional_github_repos="${arg#*=}"
        shift # Remove processed argument
        ;;
        --dry-run)
        DRY_RUN=true
        shift # Remove processed argument
        ;;
        --help)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --github-token=TOKEN     GitHub personal access token (required)"
        echo "  --org=ORG                GitHub organization to filter by (default: all)"
        echo "  --additional-github-repos=REPOS  Comma-separated list of additional repositories"
        echo "  --dry-run                Show what would be done without taking action"
        echo "  --help                   Show this help message"
        echo ""
        echo "Examples:"
        echo "  $0 --github-token=<token> --dry-run"
        echo "  $0 --github-token=<token> --org=ddev"
        echo "  $0 --github-token=<token> --org=myusername --dry-run"
        exit 0
        ;;
        *)
        echo "Unknown option: $arg"
        echo "Use --help for usage information"
        exit 1
        ;;
    esac
done

if [ "${GITHUB_TOKEN}" = "" ]; then 
    echo "ERROR: --github-token must be set"
    exit 5
fi

echo "Organization: $org"
if [ "$DRY_RUN" = true ]; then
    echo "Mode: DRY RUN (no actions will be taken)"
else
    # Get actual rate limit status
    rate_limit_response=$(curl -s -I -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/rate_limit")
    actual_rate_limit=$(echo "$rate_limit_response" | grep -i "x-ratelimit-remaining:" | cut -d':' -f2 | tr -d ' \r\n')
    if [[ -n "$actual_rate_limit" && "$actual_rate_limit" =~ ^[0-9]+$ ]]; then
        RATE_LIMIT_REMAINING="$actual_rate_limit"
    fi
    echo "Starting with $RATE_LIMIT_REMAINING API requests remaining"
fi

# Use brew coreutils gdate if it exists, otherwise things fail with macOS date
export DATE=date
if command -v gdate >/dev/null; then DATE=gdate; fi

# Topic to filter repositories
topic="ddev-get"

# Additional repositories to monitor beyond topic-based filtering
additional_repos=(
    "ddev/ddev"
    "ddev/github-action-add-on-test"
    "ddev/github-action-setup-ddev"
    "ddev/signing_tools"
    "ddev/sponsorship-data"
)

# Wrapper functions that respect dry-run mode
gh_api() {
    local endpoint="$1"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would call GitHub API: $endpoint"
        return 0
    fi
    local response
    response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
         -H "Accept: application/vnd.github.v3+json" \
         "$endpoint")
    
    # Check if response is valid JSON
    if ! echo "$response" | jq -e . >/dev/null 2>&1; then
        echo "DEBUG: Response was not valid JSON: $response"
        echo "API_ERROR: Invalid JSON response"
        return 1
    fi
    
    # Check if it's an error response
    if echo "$response" | jq -e '.message' >/dev/null 2>&1; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.message')
        echo "API_ERROR: $error_msg"
        return 1
    fi
    
    echo "$response"
}

# Enhanced API wrapper with rate limit handling
gh_api_safe() {
    local endpoint="$1"
    local allow_skip="${2:-true}"  # Allow skipping on rate limit errors
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would call GitHub API: $endpoint"
        return 0
    fi
    
    # Check rate limit before making request
    if [[ $RATE_LIMIT_REMAINING -lt 10 ]]; then
        echo "RATE_LIMIT_ERROR: Only $RATE_LIMIT_REMAINING requests remaining. Pausing to avoid rate limit."
        if [[ "$allow_skip" == "true" ]]; then
            return 2  # Special exit code for rate limit (allowing skip)
        else
            return 1  # Fatal error
        fi
    fi
    
    local response
    local headers
    response=$(curl -s -D /tmp/headers_$$ -H "Authorization: token $GITHUB_TOKEN" \
         -H "Accept: application/vnd.github.v3+json" \
         "$endpoint")
    
    # Extract rate limit info from headers
    if [[ -f "/tmp/headers_$$" ]]; then
        local rate_limit_remaining
        rate_limit_remaining=$(grep -i "x-ratelimit-remaining:" "/tmp/headers_$$" | cut -d':' -f2 | tr -d ' \r\n')
        if [[ -n "$rate_limit_remaining" && "$rate_limit_remaining" =~ ^[0-9]+$ ]]; then
            RATE_LIMIT_REMAINING="$rate_limit_remaining"
        fi
        rm -f "/tmp/headers_$$"
    fi
    
    # Check if response is valid JSON
    if ! echo "$response" | jq -e . >/dev/null 2>&1; then
        echo "DEBUG: Response was not valid JSON: $response"
        echo "API_ERROR: Invalid JSON response"
        return 1
    fi
    
    # Check if it's an error response
    if echo "$response" | jq -e '.message' >/dev/null 2>&1; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.message')
        local status_code
        status_code=$(echo "$response" | jq -r '.status // "unknown"')
        
        # Handle rate limiting specifically
        if [[ "$error_msg" == *"API rate limit exceeded"* ]] || [[ "$status_code" == "403" ]]; then
            echo "RATE_LIMIT_ERROR: $error_msg"
            if [[ "$allow_skip" == "true" ]]; then
                return 2  # Special exit code for rate limit (allowing skip)
            else
                return 1  # Fatal error
            fi
        fi
        
        echo "API_ERROR: $error_msg"
        return 1
    fi
    
    echo "$response"
}

gh_issue_create() {
    local repo="$1"
    local title="$2"
    local body="$3"
    local labels="$4"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would create notification issue in $repo"
        return 0
    fi
    
    local data
data=$(jq -n --arg title "$title" --arg body "$body" --arg labels "$labels" \
        '{"title": $title, "body": $body, "labels": ($labels | split(","))}')
    
    local response
response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
         -H "Accept: application/vnd.github.v3+json" \
         -X POST \
         -H "Content-Type: application/json" \
         -d "$data" \
         "https://api.github.com/repos/$repo/issues" 2>&1)
    
    # Check if response is valid JSON and has an error message
    if echo "$response" | jq -e . >/dev/null 2>&1; then
        # Check if it's an error response (has message field)
        if echo "$response" | jq -e '.message' >/dev/null 2>&1; then
            local error_msg
            error_msg=$(echo "$response" | jq -r '.message')
            echo "{\"error\": \"$error_msg\"}"
        else
            echo "$response"
        fi
    else
        # Return error response that can be detected
        echo '{"error": "Issues are disabled on this repository"}'
    fi
}

gh_issue_comment() {
    local repo="$1"
    local issue_number="$2"
    local comment="$3"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would comment on issue $issue_number in $repo"
        return 0
    fi
    
    local data
data=$(jq -n --arg body "$comment" '{"body": $body}')
    
    curl -s -H "Authorization: token $GITHUB_TOKEN" \
         -H "Accept: application/vnd.github.v3+json" \
         -X POST \
         -H "Content-Type: application/json" \
         -d "$data" \
         "https://api.github.com/repos/$repo/issues/$issue_number/comments"
}

gh_issue_close() {
    local repo="$1"
    local issue_number="$2"
    local comment="$3"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would add comment, update title to [RESOLVED], and close issue $issue_number in $repo"
        return 0
    fi
    
    # First add a comment explaining the closure
    local comment_data
comment_data=$(jq -n --arg body "$comment" '{"body": $body}')
    curl -s -H "Authorization: token $GITHUB_TOKEN" \
         -H "Accept: application/vnd.github.v3+json" \
         -X POST \
         -H "Content-Type: application/json" \
         -d "$comment_data" \
         "https://api.github.com/repos/$repo/issues/$issue_number/comments" > /dev/null
    
    # Then update the title and close the issue
    local current_title
    current_title=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
         -H "Accept: application/vnd.github.v3+json" \
         "https://api.github.com/repos/$repo/issues/$issue_number" | jq -r '.title')
    
    local new_title
    if [[ "$current_title" == *"[RESOLVED]"* ]]; then
        new_title="$current_title"
    else
        new_title="[RESOLVED] $current_title"
    fi
    
    local close_data
close_data=$(jq -n --arg title "$new_title" '{"title": $title, "state": "closed"}')
    curl -s -H "Authorization: token $GITHUB_TOKEN" \
         -H "Accept: application/vnd.github.v3+json" \
         -X PATCH \
         -H "Content-Type: application/json" \
         -d "$close_data" \
         "https://api.github.com/repos/$repo/issues/$issue_number" > /dev/null
}

# Fetch all repositories with the specified topic
fetch_repos_with_topic() {
  # First try GitHub search
  page=1
  while :; do
    query="topic:$topic"
    # only add org filter if org is specified and not "all"
    if [ "${org}" != "" ] && [ "${org}" != "all" ]; then query="${query}+org:$org"; fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
      # In dry-run mode, make real API calls for repository discovery
      repos=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
           -H "Accept: application/vnd.github.v3+json" \
           "https://api.github.com/search/repositories?q=${query}&per_page=100&page=$page" 2>/dev/null | jq -r '.items[].full_name' 2>/dev/null)
    else
      local api_response
      api_response=$(gh_api_safe "https://api.github.com/search/repositories?q=${query}&per_page=100&page=$page" "false")
      local api_exit_code=$?
      if [[ "$api_exit_code" -eq 2 ]]; then
        echo "❌ Rate limit reached while fetching repositories. Stopping repository discovery."
        break
      elif [[ "$api_exit_code" -ne 0 ]] || [[ "$api_response" == "API_ERROR:"* ]] || ! echo "$api_response" | jq -e . >/dev/null 2>&1; then
        repos=""
      else
        repos=$(echo "$api_response" | jq -r '.items[].full_name' 2>/dev/null)
      fi
    fi

    if [[ -z "$repos" ]]; then
      break
    fi

    echo "$repos"
    ((page++))
  done
}

# Check if repo has any test workflows
has_test_workflows() {
    local repo="$1"
    
    local workflows=""
    if [[ "$DRY_RUN" == "true" ]]; then
        workflows=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
             -H "Accept: application/vnd.github.v3+json" \
             "https://api.github.com/repos/$repo/actions/workflows")
    else
        workflows=$(gh_api_safe "https://api.github.com/repos/$repo/actions/workflows")
        local api_exit_code=$?
        if [[ "$api_exit_code" -eq 2 ]]; then
            echo "❌ Rate limit reached while checking workflows for $repo. Skipping..."
            return 2  # Special code for rate limit
        elif [[ "$api_exit_code" -ne 0 ]] || [[ "$workflows" == "RATE_LIMIT_ERROR:"* ]]; then
            echo "❌ API error checking workflows for $repo. Skipping..."
            return 2
        fi
    fi
    
    local count
count=$(echo "$workflows" | jq -r '.workflows | length')
    
    if [[ "$count" -eq 0 ]]; then
        return 1  # No workflows
    fi
    
    # Check if there's a tests workflow
    echo "$workflows" | jq -r '.workflows[].name' | grep -i "^tests$" > /dev/null
}

# Check if any test workflows are disabled
has_disabled_test_workflows() {
    local repo="$1"
    
    local workflows=""
    if [[ "$DRY_RUN" == "true" ]]; then
        workflows=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
             -H "Accept: application/vnd.github.v3+json" \
             "https://api.github.com/repos/$repo/actions/workflows")
    else
        workflows=$(gh_api_safe "https://api.github.com/repos/$repo/actions/workflows")
        local api_exit_code=$?
        if [[ "$api_exit_code" -eq 2 ]]; then
            echo "❌ Rate limit reached while checking disabled workflows for $repo. Assuming not disabled..."
            return 1  # Assume not disabled on rate limit
        elif [[ "$api_exit_code" -ne 0 ]] || [[ "$workflows" == "RATE_LIMIT_ERROR:"* ]]; then
            echo "❌ API error checking disabled workflows for $repo. Assuming not disabled..."
            return 1
        fi
    fi
    
    echo "$workflows" | jq -r '.workflows[] | select(.name | ascii_downcase == "tests") | select(.state == "disabled_manually" or .state == "disabled_inactivity")' | grep -q . > /dev/null
}

# Check if there are any closed notification issues
has_recently_closed_notification() {
    local repo="$1"
    local cutoff_date
    cutoff_date=$(${DATE} -d "${RENOTIFICATION_COOLDOWN_DAYS} days ago" -u +"%Y-%m-%dT%H:%M:%SZ")
    
    if [[ "$DRY_RUN" == "true" ]]; then
        # In dry-run mode, simulate recent closures
        if [[ "$repo" == *"recently-closed"* ]]; then
            return 0  # Has recent closures
        else
            return 1  # No recent closures
        fi
    fi
    
    local issues
    issues=$(gh_api_safe "https://api.github.com/repos/$repo/issues?state=closed")
    local api_exit_code=$?
    if [[ "$api_exit_code" -eq 2 ]]; then
        return 1  # Skip on rate limit
    elif [[ "$api_exit_code" -ne 0 ]] || [[ "$issues" == "RATE_LIMIT_ERROR:"* ]]; then
        return 1  # Skip on API error
    fi
    if [[ "$issues" == *"[DRY-RUN]"* ]] || [[ "$issues" == "API_ERROR:"* ]] || ! echo "$issues" | jq -e . >/dev/null 2>&1; then
        return 1  # Skip if in dry-run or invalid JSON
    fi
    # First filter issues with date-based titles, then check if any are recent
    echo "$issues" | jq -r --arg cutoff "$cutoff_date" \
        '.[] | select(.title | contains("DDEV Add-on Test Workflows Suspended") and (.title | test("\\([0-9]{4}-[0-9]{2}-[0-9]{2}\\)"))) | select(.closed_at > $cutoff) | .number' 2>/dev/null | grep -q . > /dev/null
}

# Get notification count from issue
get_notification_count() {
    local repo="$1"
    local issue_number="$2"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        # In dry-run mode, simulate notification count
        if [[ "$repo" == *"max-notifications"* ]]; then
            echo 2  # At max
        else
            echo 0  # Can notify
        fi
        return
    fi
    
    local issue
    issue=$(gh_api_safe "https://api.github.com/repos/$repo/issues/$issue_number")
    local api_exit_code=$?
    if [[ "$api_exit_code" -eq 2 ]]; then
        echo "0"  # Default to 0 on rate limit
        return
    elif [[ "$api_exit_code" -ne 0 ]] || [[ "$issue" == "RATE_LIMIT_ERROR:"* ]]; then
        echo "0"  # Default to 0 on API error
        return
    fi
    local comment_count
    comment_count=$(echo "$issue" | jq -r '.comments')
    echo $((comment_count + 1))
}

# Check if issue was recently created or commented
was_recently_notified() {
    local repo="$1"
    local issue_number="$2"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        # In dry-run mode, simulate recent notification
        if [[ "$repo" == *"recently-notified"* ]]; then
            return 0  # Recently notified
        else
            return 1  # OK to notify
        fi
    fi
    
    local cutoff_date
    cutoff_date=$(${DATE} -d "${NOTIFICATION_INTERVAL_DAYS} days ago" -u +"%Y-%m-%dT%H:%M:%SZ")
    local issue
issue=$(gh_api_safe "https://api.github.com/repos/$repo/issues/$issue_number")
local api_exit_code=$?
if [[ "$api_exit_code" -eq 2 ]]; then
    return 1  # Skip on rate limit (assume not recently notified)
elif [[ "$api_exit_code" -ne 0 ]] || [[ "$issue" == "RATE_LIMIT_ERROR:"* ]]; then
    return 1  # Skip on API error
fi
    
    # Check creation date
    local created_at
    created_at=$(echo "$issue" | jq -r '.created_at')
    if [[ "$created_at" > "$cutoff_date" ]]; then
        return 0
    fi
    
    # Check for recent comments
    local comments
comments=$(gh_api_safe "https://api.github.com/repos/$repo/issues/$issue_number/comments")
local comments_exit_code=$?
if [[ "$comments_exit_code" -eq 2 ]]; then
    return 1  # Skip on rate limit
elif [[ "$comments_exit_code" -ne 0 ]] || [[ "$comments" == "RATE_LIMIT_ERROR:"* ]]; then
    return 1  # Skip on API error
fi
    echo "$comments" | jq -r --arg cutoff "$cutoff_date" '.[] | select(.created_at > $cutoff) | .id' | grep -q . > /dev/null
}

# Handle repositories with test workflows
handle_repo_with_tests() {
    local repo="$1"
    
    if has_disabled_test_workflows "$repo"; then
        echo "⚠️  DISABLED WORKFLOWS"
        
        if has_recently_closed_notification "$repo"; then
            echo "  ✓ (in cooldown period)"
            return
        fi
        
        # Look for existing open notification issue
        local existing_issue
        existing_issue=""
        if [[ "$DRY_RUN" == "true" ]]; then
            if [[ "$repo" == *"has-issue"* ]]; then
                existing_issue="123"
            fi
        else
            local issues
            issues=$(gh_api_safe "https://api.github.com/search/issues?q=repo:$repo+state:open+in:title+DDEV+Add-on+Test+Workflows+Suspended")
            local api_exit_code=$?
            if [[ "$api_exit_code" -eq 2 ]]; then
                echo "  ⚠️  Rate limit reached while searching for issues. Skipping issue search for $repo..."
                existing_issue=""
            elif [[ "$api_exit_code" -ne 0 ]] || [[ "$issues" == "RATE_LIMIT_ERROR:"* ]] || ! echo "$issues" | jq -e . >/dev/null 2>&1; then
                existing_issue=""
            else
                existing_issue=$(echo "$issues" | jq -r '.items[] | .number' 2>/dev/null | head -1)
            fi
        fi
        
        if [[ -n "$existing_issue" ]]; then
            local notification_count
notification_count=$(get_notification_count "$repo" "$existing_issue")
            
            if [[ $notification_count -ge $MAX_NOTIFICATIONS ]]; then
                echo "  ✓ (max notifications reached)"
            elif was_recently_notified "$repo" "$existing_issue"; then
                echo "  ✓ (recently notified)"
            else
                gh_issue_comment "$repo" "$existing_issue" "⚠️ **Follow-up notification** ($notification_count/$MAX_NOTIFICATIONS): Test workflows remain suspended. Please re-enable them to ensure continued testing of your add-on with DDEV." > /dev/null
                echo "  📝 Follow-up comment added to issue #$existing_issue"
            fi
        else
            local issue_title
issue_title="⚠️ DDEV Add-on Test Workflows Suspended ($(${DATE} -u +"%Y-%m-%d"))"
            local issue_url
            issue_url=$(gh_issue_create "$repo" "$issue_title" "$(cat << EOF
## Test Workflows Suspended - Please re-enable

The automated test workflows for this DDEV add-on are currently disabled (GitHub disables them
after two months of inactivity).

This may affect the reliability and compatibility of your add-on with future DDEV releases.
But more than that, it means that we won't hear from you about problems in DDEV HEAD,
and we really need to hear when your tests break.

### Action Required
Please re-enable the suspended test workflows by visiting the workflow page directly:

🔗 **[Re-enable Test Workflows](https://github.com/$repo/actions/workflows/tests.yml)**

Click the "Enable workflow" button on that page to restore automated testing.

If you don't want to be notified about this, or the tests are irrelevant,
or the add-on is irrelevant, please remove the 'ddev-get' topic from the repository.

### Resources
- [DDEV Add-on Maintenance Guide](https://ddev.com/blog/ddev-add-on-maintenance-guide/)
- [Why workflows get disabled now and they didn't used to](https://github.com/ddev/github-action-add-on-test/issues/46)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)

We'll try to add to the ddev-addon-template repository an alternate script that might be able to keep these running, but we haven't figured out a GitHub-approved way to do it yet.

### Support

As always, we're happy to help. Reach out to us here (we see most issues) or in the [DDEV Discord](https://ddev.com/s/discord) or [DDEV Issue Queue](https://github.com/ddev/ddev/issues).

### Notification Info
- This is an automated notification (1/$MAX_NOTIFICATIONS)
- Created: $(${DATE} -u +"%Y-%m-%d")
- Repository: $repo

---
*This issue will be automatically updated if the problem persists. To stop receiving these notifications, please resolve the workflow issues or remove the ddev-get topic.*
EOF
)" "")
            
            local issue_number=""
            if [[ "$DRY_RUN" == "false" && "$issue_url" != *"DRY-RUN"* ]] && echo "$issue_url" | jq -e . >/dev/null 2>&1; then
                # Check for error response
                if echo "$issue_url" | jq -e '.error' >/dev/null 2>&1; then
                    local error_msg
                    error_msg=$(echo "$issue_url" | jq -r '.error')
                    case "$error_msg" in
                        "Not Found")
                            echo "  ❌ Cannot create notification issue: Issues are disabled on this repository or token lacks permissions"
                            ;;
                        "Resource not accessible by personal access token")
                            echo "  ❌ Cannot create notification issue: Token lacks write permissions for this repository"
                            ;;
                        "Bad credentials")
                            echo "  ❌ Cannot create notification issue: Invalid GitHub token"
                            ;;
                        *)
                            echo "  ❌ Cannot create notification issue: $error_msg"
                            ;;
                    esac
                else
                    issue_number=$(echo "$issue_url" | jq -r '.number')
                    local issue_html_url
                    issue_html_url=$(echo "$issue_url" | jq -r '.html_url')
                    echo "  🔔 Created notification issue #$issue_number: $issue_html_url"
                fi
            else
                echo "  🔔 Would create notification issue"
            fi
        fi
    else
        echo "✅ OK"
        
        # Close any open notification issues (only show if action taken)
        local open_issue
        open_issue=""
        if [[ "$DRY_RUN" == "true" ]]; then
            if [[ "$repo" == *"has-open-issue"* ]]; then
                open_issue="456"
            fi
        else
            local issues
            issues=$(gh_api_safe "https://api.github.com/search/issues?q=repo:$repo+state:open+in:title+DDEV+Add-on+Test+Workflows+Suspended")
            local api_exit_code=$?
            if [[ "$api_exit_code" -eq 2 ]]; then
                echo "  ⚠️  Rate limit reached while searching for open issues. Skipping issue search for $repo..."
                open_issue=""
            elif [[ "$api_exit_code" -ne 0 ]] || [[ "$issues" == "RATE_LIMIT_ERROR:"* ]] || ! echo "$issues" | jq -e . >/dev/null 2>&1; then
                open_issue=""
            else
                open_issue=$(echo "$issues" | jq -r '.items[] | .number' 2>/dev/null | head -1)
            fi
        fi
        
        if [[ -n "$open_issue" ]]; then
            gh_issue_close "$repo" "$open_issue" "✅ Test workflows are now active. Closing this notification."
            echo "  🔒 Closed resolved notification issue #$open_issue"
        fi
    fi
}

# Handle repositories without test workflows
handle_repo_without_tests() {
    local repo="$1"
    echo "⚠️  No test workflows found"
    
    # Only show this info in dry-run mode
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  💡 Consider suggesting they add tests or remove 'ddev-get' topic"
    fi
}

# Process a single repository with error handling
process_repo() {
    local repo="$1"
    
    if has_test_workflows "$repo"; then
        local workflows_exit_code=$?
        if [[ "$workflows_exit_code" -eq 2 ]]; then
            rate_limit_hit=true
            echo "❌ RATE LIMIT: $RATE_LIMIT_REMAINING"
            return 0  # Continue processing other repos
        fi
        handle_repo_with_tests "$repo"
        echo " [RATE LIMIT: $RATE_LIMIT_REMAINING]"
    else
        local workflows_exit_code=$?
        if [[ "$workflows_exit_code" -eq 2 ]]; then
            rate_limit_hit=true
            echo "❌ RATE LIMIT: $RATE_LIMIT_REMAINING"
            return 0  # Continue processing other repos
        fi
        handle_repo_without_tests "$repo"
        echo " [RATE LIMIT: $RATE_LIMIT_REMAINING]"
    fi
}

# Main notification function
notify_about_disabled_workflows() {
  # local current_date=$(${DATE} +%s)  # Unused variable
  
  # Combine topic-based repos with additional repos and deduplicate
  topic_repos=()
  while IFS= read -r repo; do
    [[ -n "$repo" ]] && topic_repos+=("$repo")
  done < <(fetch_repos_with_topic)
  
  # Start with topic repos
  all_repos=("${topic_repos[@]}")
  
  # Add hardcoded repos only if org is "all" or not specified, or if repos match the org
  filtered_additional_repos=()
  if [ "${org}" == "" ] || [ "${org}" == "all" ]; then
    all_repos=("${all_repos[@]}" "${additional_repos[@]}")
    filtered_additional_repos=("${additional_repos[@]}")
  else
    # Only add hardcoded repos that match the specified org
    for repo in "${additional_repos[@]}"; do
      if [[ "$repo" == "$org/"* ]]; then
        all_repos+=("$repo")
        filtered_additional_repos+=("$repo")
      fi
    done
  fi
  
  # Add CLI-provided repos if available
  cli_repos=()
  if [[ -n "$additional_github_repos" ]]; then
    IFS=',' read -ra cli_repos <<< "$additional_github_repos"
    all_repos=("${all_repos[@]}" "${cli_repos[@]}")
  fi
  
  # Remove duplicates using printf/sort approach compatible with older bash
  if [[ ${#all_repos[@]} -gt 0 ]]; then
    printf "%s\n" "${all_repos[@]}" | grep -v '^$' | sort -u > /tmp/repos_$$.txt
    mapfile -t unique_repos < /tmp/repos_$$.txt
    rm -f /tmp/repos_$$.txt
  else
    unique_repos=()
  fi
  
  # Calculate total additional repos (filtered + CLI)
  total_additional=$((${#filtered_additional_repos[@]} + ${#cli_repos[@]}))
  echo "Checking ${#unique_repos[@]} total repositories (${#topic_repos[@]} from topic '${topic}', ${total_additional} additional)"
  echo ""
  
  rate_limit_hit=false
  for repo in "${unique_repos[@]}"; do
    echo -n "Checking $repo... "
    
    # Wrap the repository processing in error handling
    if ! process_repo "$repo"; then
        echo "❌ ERROR processing $repo"
        continue
    fi
  done
  
  if [[ "$rate_limit_hit" == "true" ]]; then
    echo ""
    echo "⚠️  Rate limit was reached during processing."
    echo "Some repositories may have been skipped due to API rate limiting."
    echo "Consider running the script again later or using a personal access token with higher rate limits."
  fi
  echo ""
}

# Run the main function
notify_about_disabled_workflows

echo "Summary:"
echo "- Repositories checked: ${#unique_repos[@]}"
echo "- API rate limit remaining: $RATE_LIMIT_REMAINING"
if [[ "$rate_limit_hit" == "true" ]]; then
    echo "- ⚠️  Rate limit was reached during processing"
    EXIT_CODE=2  # Set exit code 2 for rate limit, but don't crash
fi
if [[ "$DRY_RUN" == "true" ]]; then
    echo "- Mode: DRY RUN (no actions taken)"
else
    echo "- Mode: LIVE (actions may have been taken)"
fi

exit ${EXIT_CODE}