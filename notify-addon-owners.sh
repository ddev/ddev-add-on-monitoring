#!/usr/bin/env bash

# This bash script monitors DDEV add-on repositories for disabled test workflows
# and sends notifications to repository owners when workflows are suspended.
# Uses GitHub issues for tracking notification history to avoid external state.
# `./notify-addon-owners.sh --github-token=<token> --dry-run`
#
# GITHUB_TOKEN requirements:
#   - Classic token: 'repo' scope (or 'public_repo' for public repos only)
#   - Fine-grained token: "Actions" (read), "Issues" (read/write) permissions
#   - The token must have access to the repositories being monitored.

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
REPORT=false
EXIT_CODE=0
RATE_LIMIT_REMAINING=5000  # Default to 5000 requests/hour for core API
SEARCH_RATE_LIMIT_REMAINING=30  # Default to 30 requests/minute for search API
START_REPO="1"  # Start from the nth repository (1-based index) or a repo name (owner/repo)

# Report tracking arrays
REPORT_OK=()
REPORT_DISABLED=()
REPORT_NO_TESTS=()
REPORT_ERRORS=()

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
        --report)
        REPORT=true
        shift # Remove processed argument
        ;;
        --start-repo=*)
        START_REPO="${arg#*=}"
        shift # Remove processed argument
        ;;
        --help)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --github-token=TOKEN     GitHub personal access token (required)."
        echo "                           The token needs the following scopes:"
        echo "                             - 'repo' (Full control of private repositories)"
        echo "                               or 'public_repo' (Access public repositories)"
        echo "                             - Required for: reading workflows, creating/closing"
        echo "                               issues, and commenting on issues in add-on repos"
        echo "  --org=ORG                GitHub organization to filter by (default: all)"
        echo "  --additional-github-repos=REPOS  Comma-separated list of additional repositories"
        echo "  --start-repo=N|OWNER/REPO  Start processing from the Nth repo (1-based) or named repo"
        echo "  --dry-run                Show what would be done without taking action"
        echo "  --report                 Print a categorized summary report at the end"
        echo "  --help                   Show this help message"
        echo ""
        echo "Examples:"
        echo "  $0 --github-token=<token> --dry-run"
        echo "  $0 --github-token=<token> --org=ddev"
        echo "  $0 --github-token=<token> --start-repo=50 --dry-run"
        echo "  $0 --github-token=<token> --start-repo=ddev/ddev-redis --dry-run"
        echo "  $0 --github-token=<token> --org=myusername --dry-run"
        echo ""
        echo "Safely providing the token:"
        echo "  There is no GITHUB_TOKEN environment variable fallback, so avoid typing or"
        echo "  pasting the raw token. If you're authenticated with the gh CLI, pull it from"
        echo "  there instead so the literal token never lands in your shell history:"
        echo "    $0 --github-token=\$(gh auth token) --dry-run"
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

# Validate token and check capabilities early
echo -n "Validating GitHub token... "
token_check_headers="/tmp/token_check_headers_$$"
token_check_response=$(curl -s -D "$token_check_headers" -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/user" 2>&1)

if [[ -f "$token_check_headers" ]]; then
    http_status=$(head -1 "$token_check_headers" | grep -o '[0-9]\{3\}' | head -1)
    if [[ "$http_status" == "401" ]]; then
        echo "FAILED"
        echo "ERROR: Invalid or expired GitHub token (HTTP 401 Unauthorized)"
        rm -f "$token_check_headers"
        exit 5
    elif [[ "$http_status" == "403" ]]; then
        echo "FAILED"
        echo "ERROR: GitHub token is forbidden (HTTP 403). Check token permissions."
        rm -f "$token_check_headers"
        exit 5
    fi

    token_user=$(echo "$token_check_response" | jq -r '.login // "unknown"' 2>/dev/null)

    # Check scopes for classic tokens (fine-grained tokens don't return x-oauth-scopes)
    oauth_scopes=$(grep -i "^x-oauth-scopes:" "$token_check_headers" | cut -d':' -f2- | tr -d '\r\n' | xargs)
    if [[ -n "$oauth_scopes" ]]; then
        echo "OK (user: $token_user, scopes: $oauth_scopes)"
        # Warn if missing required scopes
        if ! echo "$oauth_scopes" | grep -qiE '(^|,)\s*repo\s*(,|$)'; then
            if ! echo "$oauth_scopes" | grep -qi 'public_repo'; then
                echo "WARNING: Token may lack required scopes. Need 'repo' or 'public_repo'."
                echo "         Current scopes: $oauth_scopes"
                echo "         The script will continue but may fail on some API calls."
            fi
        fi
    else
        echo "OK (user: $token_user, fine-grained token)"
    fi
    rm -f "$token_check_headers"
else
    echo "FAILED"
    echo "ERROR: Could not connect to GitHub API"
    exit 5
fi

echo "Organization: $org"
if [ "$DRY_RUN" = true ]; then
    echo "Mode: DRY RUN (no actions will be taken)"
else
    # Get actual core API rate limit status using the rate_limit endpoint
    temp_core_headers="/tmp/core_headers_$$"
    curl -s -I -D "$temp_core_headers" -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/rate_limit" > /dev/null
    if [[ -f "$temp_core_headers" ]]; then
        actual_rate_limit=$(grep -i "^x-ratelimit-remaining:" "$temp_core_headers" | head -1 | cut -d':' -f2 | tr -d ' \r\n')
        if [[ -n "$actual_rate_limit" && "$actual_rate_limit" =~ ^[0-9]+$ ]]; then
            RATE_LIMIT_REMAINING="$actual_rate_limit"
        fi
        rm -f "$temp_core_headers"
    fi
    
    # Get search API rate limit using a minimal search query
    temp_search_headers="/tmp/search_headers_$$"
    curl -s -I -D "$temp_search_headers" -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/search/repositories?q=test&per_page=1" > /dev/null
    if [[ -f "$temp_search_headers" ]]; then
        actual_search_rate_limit=$(grep -i "^x-ratelimit-remaining:" "$temp_search_headers" | head -1 | cut -d':' -f2 | tr -d ' \r\n')
        if [[ -n "$actual_search_rate_limit" && "$actual_search_rate_limit" =~ ^[0-9]+$ ]]; then
            SEARCH_RATE_LIMIT_REMAINING="$actual_search_rate_limit"
        fi
        rm -f "$temp_search_headers"
    fi
    
    echo "Starting with $RATE_LIMIT_REMAINING core API requests remaining"
    echo "Starting with $SEARCH_RATE_LIMIT_REMAINING search API requests remaining"
fi

# Use brew coreutils gdate if it exists, otherwise things fail with macOS date
export DATE=date
if command -v gdate >/dev/null; then DATE=gdate; fi

# Topic to filter repositories
topic="ddev-get"

# Additional repositories to monitor beyond topic-based filtering. These are core DDEV
# infrastructure repos, not community add-ons -- they're still categorized as OK/disabled/
# no-tests for reporting, but never sent add-on-specific notification issues/comments (see
# is_notification_excluded), since that wording ("remove the ddev-get topic", "this add-on",
# ddev-addon-template) doesn't apply to them.
additional_repos=(
    "ddev/ddev"
    "ddev/github-action-add-on-test"
    "ddev/github-action-setup-ddev"
    "ddev/signing_tools"
    "ddev/sponsorship-data"
)

# True (0) if repo should be excluded from actual notifications (still monitored/reported)
is_notification_excluded() {
    local repo="$1"
    local excluded
    for excluded in "${additional_repos[@]}"; do
        if [[ "$repo" == "$excluded" ]]; then
            return 0
        fi
    done
    return 1
}

# Shared maintainer-guidance snippets, reused across notification issue bodies/comments.
# Single-quoted so the literal backticks in these markdown code spans stay literal --
# they get interpolated into unquoted heredocs below via "$VAR", which is safe because
# parameter expansion doesn't re-scan the substituted text for backticks/$ of its own.
UPDATE_CHECKER_RESOURCE='- Run the DDEV add-on update checker to catch outdated workflow files and other common maintenance issues:
  ```bash
  curl -fsSL https://ddev.com/s/addon-update-checker.sh | bash
  ```
- [DDEV Add-on Maintenance Guide](https://ddev.com/blog/ddev-add-on-maintenance-guide/)'

TOPIC_REMOVAL_REMINDER="If you don't want to be notified about this, or the tests are irrelevant,
or the add-on is irrelevant, please remove the 'ddev-get' topic from the repository."

FOLLOWUP_REMINDER_SUFFIX='Run `curl -fsSL https://ddev.com/s/addon-update-checker.sh | bash` to check for other maintenance issues, or remove the `ddev-get` topic if this add-on no longer needs to be discoverable.'

# Labels applied to notification issues (GitHub creates them automatically if they don't exist yet)
NOTIFICATION_LABELS="automated-notification,ddev-addon-test"

# Notification-type title markers: phrase (for jq/title matching) and query (for the search API, '+' for spaces)
DISABLED_TITLE_PHRASE="DDEV Add-on Test Workflows Suspended"
DISABLED_TITLE_QUERY="DDEV+Add-on+Test+Workflows+Suspended"
NO_TESTS_TITLE_PHRASE="DDEV Add-on Missing Test Workflows"
NO_TESTS_TITLE_QUERY="DDEV+Add-on+Missing+Test+Workflows"

# API wrapper with rate limit handling, respects dry-run mode
gh_api_safe() {
    local endpoint="$1"
    local allow_skip="${2:-true}"  # Allow skipping on rate limit errors
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would call GitHub API: $endpoint"
        return 0
    fi
    
    # Check appropriate rate limit before making request
    if [[ "$endpoint" == *"search"* ]]; then
        # This is a search API call
        if [[ $SEARCH_RATE_LIMIT_REMAINING -lt 3 ]]; then
            echo "SEARCH_RATE_LIMIT_ERROR: Only $SEARCH_RATE_LIMIT_REMAINING search requests remaining. Pausing to avoid search rate limit."
            if [[ "$allow_skip" == "true" ]]; then
                return 2  # Special exit code for rate limit (allowing skip)
            else
                return 1  # Fatal error
            fi
        fi
    else
        # This is a core API call
        if [[ $RATE_LIMIT_REMAINING -lt 10 ]]; then
            echo "RATE_LIMIT_ERROR: Only $RATE_LIMIT_REMAINING requests remaining. Pausing to avoid rate limit."
            if [[ "$allow_skip" == "true" ]]; then
                return 2  # Special exit code for rate limit (allowing skip)
            else
                return 1  # Fatal error
            fi
        fi
    fi
    
    local response
    local temp_headers="/tmp/gh_headers_$$"
    
    # Make the API call and capture both response and headers
    response=$(curl -s -D "$temp_headers" -H "Authorization: token $GITHUB_TOKEN" \
         -H "Accept: application/vnd.github.v3+json" \
         "$endpoint")
    
    # Extract rate limit info from headers if the file exists
    if [[ -f "$temp_headers" ]]; then
        local rate_limit_remaining
        local rate_limit_resource
        
        # Extract rate limit remaining (more robust pattern matching)
        rate_limit_remaining=$(grep -i "^x-ratelimit-remaining:" "$temp_headers" | head -1 | cut -d':' -f2 | tr -d ' \r\n')
        rate_limit_resource=$(grep -i "^x-ratelimit-resource:" "$temp_headers" | head -1 | cut -d':' -f2 | tr -d ' \r\n')
        
        # Update the appropriate rate limit counter
        if [[ -n "$rate_limit_remaining" && "$rate_limit_remaining" =~ ^[0-9]+$ ]]; then
            if [[ "$rate_limit_resource" == "search" ]]; then
                SEARCH_RATE_LIMIT_REMAINING="$rate_limit_remaining"
            else
                # For core API calls (default when no resource header or resource != "search")
                RATE_LIMIT_REMAINING="$rate_limit_remaining"
            fi
        fi
        
        # Clean up temporary file
        rm -f "$temp_headers"
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

# Update RATE_LIMIT_REMAINING from a captured curl -D header file, then remove it
update_rate_limit_from_headers() {
    local headers_file="$1"
    if [[ -f "$headers_file" ]]; then
        local remaining
        remaining=$(grep -i "^x-ratelimit-remaining:" "$headers_file" | head -1 | cut -d':' -f2 | tr -d ' \r\n')
        if [[ -n "$remaining" && "$remaining" =~ ^[0-9]+$ ]]; then
            RATE_LIMIT_REMAINING="$remaining"
        fi
        rm -f "$headers_file"
    fi
}

# Perform the actual issue-create POST; returns the raw GitHub response JSON (success or error)
create_issue_request() {
    local repo="$1"
    local title="$2"
    local body="$3"
    local labels="$4"

    local data
data=$(jq -n --arg title "$title" --arg body "$body" --arg labels "$labels" \
        '{"title": $title, "body": $body, "labels": (if $labels == "" then [] else ($labels | split(",")) end)}')

    local response
    local temp_headers="/tmp/gh_write_headers_$$"
response=$(curl -s -D "$temp_headers" -H "Authorization: token $GITHUB_TOKEN" \
         -H "Accept: application/vnd.github.v3+json" \
         -X POST \
         -H "Content-Type: application/json" \
         -d "$data" \
         "https://api.github.com/repos/$repo/issues" 2>&1)
    update_rate_limit_from_headers "$temp_headers"
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

    local response
    response=$(create_issue_request "$repo" "$title" "$body" "$labels")

    # Applying labels that don't already exist on the repo requires write access, which we
    # often don't have on third-party add-on repos. Don't let that block the notification
    # itself -- retry without labels rather than failing outright.
    if [[ -n "$labels" ]] && echo "$response" | jq -e '.message' >/dev/null 2>&1; then
        local error_msg
        error_msg=$(echo "$response" | jq -r '.message')
        if [[ "$error_msg" == *"permission to create labels"* ]]; then
            response=$(create_issue_request "$repo" "$title" "$body" "")
        fi
    fi

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

    local response
    local temp_headers="/tmp/gh_write_headers_$$"
    response=$(curl -s -D "$temp_headers" -H "Authorization: token $GITHUB_TOKEN" \
         -H "Accept: application/vnd.github.v3+json" \
         -X POST \
         -H "Content-Type: application/json" \
         -d "$data" \
         "https://api.github.com/repos/$repo/issues/$issue_number/comments")
    update_rate_limit_from_headers "$temp_headers"
    echo "$response"
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
    local temp_headers="/tmp/gh_write_headers_$$"
    curl -s -D "$temp_headers" -H "Authorization: token $GITHUB_TOKEN" \
         -H "Accept: application/vnd.github.v3+json" \
         -X POST \
         -H "Content-Type: application/json" \
         -d "$comment_data" \
         "https://api.github.com/repos/$repo/issues/$issue_number/comments" > /dev/null
    update_rate_limit_from_headers "$temp_headers"

    # Then update the title and close the issue
    local current_title
    temp_headers="/tmp/gh_write_headers_$$"
    current_title=$(curl -s -D "$temp_headers" -H "Authorization: token $GITHUB_TOKEN" \
         -H "Accept: application/vnd.github.v3+json" \
         "https://api.github.com/repos/$repo/issues/$issue_number" | jq -r '.title')
    update_rate_limit_from_headers "$temp_headers"

    local new_title
    if [[ "$current_title" == *"[RESOLVED]"* ]]; then
        new_title="$current_title"
    else
        new_title="[RESOLVED] $current_title"
    fi

    local close_data
close_data=$(jq -n --arg title "$new_title" '{"title": $title, "state": "closed"}')
    temp_headers="/tmp/gh_write_headers_$$"
    curl -s -D "$temp_headers" -H "Authorization: token $GITHUB_TOKEN" \
         -H "Accept: application/vnd.github.v3+json" \
         -X PATCH \
         -H "Content-Type: application/json" \
         -d "$close_data" \
         "https://api.github.com/repos/$repo/issues/$issue_number" > /dev/null
    update_rate_limit_from_headers "$temp_headers"
}

# Search for an open issue whose title contains the given words (joined by '+' for the query).
# Prints the issue number on stdout (empty if none found). Returns 2 on rate limit, 1 if the
# search itself failed (caller should treat that as "unknown" and avoid creating a duplicate).
find_open_notification_issue() {
    local repo="$1"
    local title_words="$2"

    local issues
    issues=$(gh_api_safe "https://api.github.com/search/issues?q=repo:$repo+state:open+in:title+${title_words}")
    local api_exit_code=$?
    if [[ "$api_exit_code" -eq 2 ]]; then
        return 2
    elif [[ "$api_exit_code" -ne 0 ]] || [[ "$issues" == "RATE_LIMIT_ERROR:"* ]] || ! echo "$issues" | jq -e . >/dev/null 2>&1; then
        return 1
    fi
    echo "$issues" | jq -r '.items[] | .number' 2>/dev/null | head -1
}

# Close any open notification issue matching title_words, if one exists.
# Returns 2 on rate limit (caller should stop processing this repo).
close_resolved_notification() {
    local repo="$1"
    local title_words="$2"
    local dry_run_stub="$3"
    local close_comment="$4"

    local open_issue=""
    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ "$repo" == *"$dry_run_stub"* ]]; then
            open_issue="456"
        fi
    else
        open_issue=$(find_open_notification_issue "$repo" "$title_words")
        local search_exit_code=$?
        if [[ "$search_exit_code" -eq 2 ]]; then
            echo "  ⚠️  Rate limit reached while searching for open issues."
            return 2
        elif [[ "$search_exit_code" -ne 0 ]]; then
            open_issue=""
        fi
    fi

    if [[ -n "$open_issue" ]]; then
        gh_issue_close "$repo" "$open_issue" "$close_comment"
        echo "  🔒 Closed resolved notification issue #$open_issue"
    fi
}

# Fetch all repositories with the specified topic
fetch_repos_with_topic() {
  # First try GitHub search
  page=1
  while :; do
    query="topic:$topic+archived:false"
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

# Fetch a repo's workflow list once; shared by workflows_has_tests and
# workflows_has_disabled_tests so we don't hit /actions/workflows twice per repo.
# Prints the workflows JSON on stdout; returns 2 on rate limit/API error.
fetch_workflows_json() {
    local repo="$1"

    if [[ "$DRY_RUN" == "true" ]]; then
        curl -s -H "Authorization: token $GITHUB_TOKEN" \
             -H "Accept: application/vnd.github.v3+json" \
             "https://api.github.com/repos/$repo/actions/workflows"
        return 0
    fi

    local workflows
    workflows=$(gh_api_safe "https://api.github.com/repos/$repo/actions/workflows")
    local api_exit_code=$?
    if [[ "$api_exit_code" -eq 2 ]]; then
        echo "❌ Rate limit reached while checking workflows for $repo. Skipping..." >&2
        return 2  # Special code for rate limit
    elif [[ "$api_exit_code" -ne 0 ]] || [[ "$workflows" == "RATE_LIMIT_ERROR:"* ]]; then
        echo "❌ API error checking workflows for $repo. Skipping..." >&2
        return 2
    fi

    echo "$workflows"
}

# Check if a previously-fetched workflows JSON has any workflow named "tests"
workflows_has_tests() {
    local workflows="$1"

    local count
count=$(echo "$workflows" | jq -r '.workflows | length')

    if [[ "$count" -eq 0 ]]; then
        return 1  # No workflows
    fi

    echo "$workflows" | jq -r '.workflows[].name' | grep -i "^tests$" > /dev/null
}

# Check if a previously-fetched workflows JSON shows the "tests" workflow disabled
workflows_has_disabled_tests() {
    local workflows="$1"

    echo "$workflows" | jq -r '.workflows[] | select(.name | ascii_downcase == "tests") | select(.state == "disabled_manually" or .state == "disabled_inactivity")' | grep -q . > /dev/null
}

# Check if there are any closed notification issues whose title contains title_phrase
has_recently_closed_notification() {
    local repo="$1"
    local title_phrase="$2"
    local dry_run_stub="$3"
    local cutoff_date
    cutoff_date=$(${DATE} -d "${RENOTIFICATION_COOLDOWN_DAYS} days ago" -u +"%Y-%m-%dT%H:%M:%SZ")

    if [[ "$DRY_RUN" == "true" ]]; then
        # In dry-run mode, simulate recent closures
        if [[ "$repo" == *"$dry_run_stub"* ]]; then
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
    echo "$issues" | jq -r --arg cutoff "$cutoff_date" --arg phrase "$title_phrase" \
        '.[] | select(.title | contains($phrase) and (.title | test("\\([0-9]{4}-[0-9]{2}-[0-9]{2}\\)"))) | select(.closed_at > $cutoff) | .number' 2>/dev/null | grep -q . > /dev/null
}

# Get notification count from issue
get_notification_count() {
    local repo="$1"
    local issue_number="$2"
    local issue="${3:-}"  # Optional pre-fetched issue JSON, to avoid re-fetching

    if [[ "$DRY_RUN" == "true" ]]; then
        # In dry-run mode, simulate notification count
        if [[ "$repo" == *"max-notifications"* ]]; then
            echo 2  # At max
        else
            echo 0  # Can notify
        fi
        return
    fi

    if [[ -z "$issue" ]]; then
        issue=$(gh_api_safe "https://api.github.com/repos/$repo/issues/$issue_number")
        local api_exit_code=$?
        if [[ "$api_exit_code" -eq 2 ]]; then
            echo "0"  # Default to 0 on rate limit
            return
        elif [[ "$api_exit_code" -ne 0 ]] || [[ "$issue" == "RATE_LIMIT_ERROR:"* ]]; then
            echo "0"  # Default to 0 on API error
            return
        fi
    fi
    local comment_count
    comment_count=$(echo "$issue" | jq -r '.comments')
    echo $((comment_count + 1))
}

# Check if issue was recently created or commented
was_recently_notified() {
    local repo="$1"
    local issue_number="$2"
    local issue="${3:-}"  # Optional pre-fetched issue JSON, to avoid re-fetching

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
    if [[ -z "$issue" ]]; then
issue=$(gh_api_safe "https://api.github.com/repos/$repo/issues/$issue_number")
local api_exit_code=$?
if [[ "$api_exit_code" -eq 2 ]]; then
    return 1  # Skip on rate limit (assume not recently notified)
elif [[ "$api_exit_code" -ne 0 ]] || [[ "$issue" == "RATE_LIMIT_ERROR:"* ]]; then
    return 1  # Skip on API error
fi
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
    local workflows="$2"

    if is_notification_excluded "$repo"; then
        if workflows_has_disabled_tests "$workflows"; then
            REPORT_DISABLED+=("$repo")
            echo "⚠️  DISABLED WORKFLOWS (notifications excluded for this repo)"
        else
            REPORT_OK+=("$repo")
            echo "✅ OK"
        fi
        return
    fi

    # A "tests" workflow now exists (enabled or disabled), so any earlier "missing test
    # workflow" notification is resolved regardless of which branch below we take.
    close_resolved_notification "$repo" "$NO_TESTS_TITLE_QUERY" "has-no-tests-open-issue" \
        "✅ A test workflow now exists for this add-on. Closing this notification." || return 2

    if workflows_has_disabled_tests "$workflows"; then
        REPORT_DISABLED+=("$repo")
        echo "⚠️  DISABLED WORKFLOWS"

        if has_recently_closed_notification "$repo" "$DISABLED_TITLE_PHRASE" "recently-closed"; then
            echo "  ✓ (in cooldown period)"
            return
        fi

        # Look for existing open notification issue
        local existing_issue=""
        if [[ "$DRY_RUN" == "true" ]]; then
            if [[ "$repo" == *"has-issue"* ]]; then
                existing_issue="123"
            fi
        else
            existing_issue=$(find_open_notification_issue "$repo" "$DISABLED_TITLE_QUERY")
            local search_exit_code=$?
            if [[ "$search_exit_code" -eq 2 ]]; then
                echo "  ⚠️  Rate limit reached while searching for issues."
                return 2
            elif [[ "$search_exit_code" -ne 0 ]]; then
                echo "  ⚠️  Failed to search for existing issues. Skipping issue operations for $repo to avoid duplicates..."
                return
            fi
        fi

        if [[ -n "$existing_issue" ]]; then
            # Fetch the issue once and reuse it for both checks below
            local existing_issue_json=""
            if [[ "$DRY_RUN" != "true" ]]; then
                existing_issue_json=$(gh_api_safe "https://api.github.com/repos/$repo/issues/$existing_issue")
                local issue_fetch_exit_code=$?
                if [[ "$issue_fetch_exit_code" -eq 2 ]]; then
                    echo "  ⚠️  Rate limit reached while checking notification issue."
                    return 2
                elif [[ "$issue_fetch_exit_code" -ne 0 ]] || [[ "$existing_issue_json" == "RATE_LIMIT_ERROR:"* ]]; then
                    existing_issue_json=""  # Let the helpers below fall back to fetching individually
                fi
            fi

            local notification_count
notification_count=$(get_notification_count "$repo" "$existing_issue" "$existing_issue_json")

            if [[ $notification_count -ge $MAX_NOTIFICATIONS ]]; then
                echo "  ✓ (max notifications reached)"
            elif was_recently_notified "$repo" "$existing_issue" "$existing_issue_json"; then
                echo "  ✓ (recently notified)"
            else
                gh_issue_comment "$repo" "$existing_issue" "⚠️ **Follow-up notification** ($notification_count/$MAX_NOTIFICATIONS): Test workflows remain suspended. Please re-enable them to ensure continued testing of your add-on with DDEV. $FOLLOWUP_REMINDER_SUFFIX" > /dev/null
                echo "  📝 Follow-up comment added to issue #$existing_issue"
            fi
        else
            local issue_title
issue_title="⚠️ ${DISABLED_TITLE_PHRASE} ($(${DATE} -u +"%Y-%m-%d"))"
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
$UPDATE_CHECKER_RESOURCE
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
)" "$NOTIFICATION_LABELS")
            
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
        REPORT_OK+=("$repo")
        echo "✅ OK"

        close_resolved_notification "$repo" "$DISABLED_TITLE_QUERY" "has-open-issue" \
            "✅ Test workflows are now active. Closing this notification." || return 2
    fi
}

# Handle repositories without test workflows
handle_repo_without_tests() {
    local repo="$1"
    REPORT_NO_TESTS+=("$repo")
    echo "⚠️  No test workflows found"

    if is_notification_excluded "$repo"; then
        echo "  (notifications excluded for this repo)"
        return
    fi

    if has_recently_closed_notification "$repo" "$NO_TESTS_TITLE_PHRASE" "recently-closed-no-tests"; then
        echo "  ✓ (in cooldown period)"
        return
    fi

    # Look for existing open notification issue
    local existing_issue=""
    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ "$repo" == *"has-no-tests-issue"* ]]; then
            existing_issue="789"
        fi
    else
        existing_issue=$(find_open_notification_issue "$repo" "$NO_TESTS_TITLE_QUERY")
        local search_exit_code=$?
        if [[ "$search_exit_code" -eq 2 ]]; then
            echo "  ⚠️  Rate limit reached while searching for issues."
            return 2
        elif [[ "$search_exit_code" -ne 0 ]]; then
            echo "  ⚠️  Failed to search for existing issues. Skipping issue operations for $repo to avoid duplicates..."
            return
        fi
    fi

    if [[ -n "$existing_issue" ]]; then
        # Fetch the issue once and reuse it for both checks below
        local existing_issue_json=""
        if [[ "$DRY_RUN" != "true" ]]; then
            existing_issue_json=$(gh_api_safe "https://api.github.com/repos/$repo/issues/$existing_issue")
            local issue_fetch_exit_code=$?
            if [[ "$issue_fetch_exit_code" -eq 2 ]]; then
                echo "  ⚠️  Rate limit reached while checking notification issue."
                return 2
            elif [[ "$issue_fetch_exit_code" -ne 0 ]] || [[ "$existing_issue_json" == "RATE_LIMIT_ERROR:"* ]]; then
                existing_issue_json=""  # Let the helpers below fall back to fetching individually
            fi
        fi

        local notification_count
notification_count=$(get_notification_count "$repo" "$existing_issue" "$existing_issue_json")

        if [[ $notification_count -ge $MAX_NOTIFICATIONS ]]; then
            echo "  ✓ (max notifications reached)"
        elif was_recently_notified "$repo" "$existing_issue" "$existing_issue_json"; then
            echo "  ✓ (recently notified)"
        else
            gh_issue_comment "$repo" "$existing_issue" "⚠️ **Follow-up notification** ($notification_count/$MAX_NOTIFICATIONS): This add-on still has no automated test workflow. $FOLLOWUP_REMINDER_SUFFIX" > /dev/null
            echo "  📝 Follow-up comment added to issue #$existing_issue"
        fi
    else
        local issue_title
issue_title="📋 ${NO_TESTS_TITLE_PHRASE} ($(${DATE} -u +"%Y-%m-%d"))"
        local issue_url
        issue_url=$(gh_issue_create "$repo" "$issue_title" "$(cat << EOF
## No Test Workflows Found

This DDEV add-on repository has the 'ddev-get' topic but no automated test workflow. Without
tests, we have no way to know when this add-on breaks against new DDEV releases, and neither do you.

### Action Required
Add a test workflow so this add-on gets automatically tested against new DDEV releases. The
[ddev-addon-template](https://github.com/ddev/ddev-addon-template) repository has the recommended
tests.yml workflow you can copy.

$TOPIC_REMOVAL_REMINDER

### Resources
$UPDATE_CHECKER_RESOURCE
- [ddev-addon-template](https://github.com/ddev/ddev-addon-template)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)

### Support

As always, we're happy to help. Reach out to us here (we see most issues) or in the [DDEV Discord](https://ddev.com/s/discord) or [DDEV Issue Queue](https://github.com/ddev/ddev/issues).

### Notification Info
- This is an automated notification (1/$MAX_NOTIFICATIONS)
- Created: $(${DATE} -u +"%Y-%m-%d")
- Repository: $repo

---
*This issue will be automatically updated if the problem persists. To stop receiving these notifications, please add a test workflow or remove the ddev-get topic.*
EOF
)" "$NOTIFICATION_LABELS")

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
}

# Process a single repository with error handling
# Returns 2 if rate limit was hit (caller should stop processing)
process_repo() {
    local repo="$1"

    local workflows
    local fetch_exit_code=0
    workflows=$(fetch_workflows_json "$repo") || fetch_exit_code=$?
    if [[ "$fetch_exit_code" -eq 2 ]]; then
        echo "❌ RATE LIMIT [CORE: $RATE_LIMIT_REMAINING, SEARCH: $SEARCH_RATE_LIMIT_REMAINING]"
        return 2
    fi

    if workflows_has_tests "$workflows"; then
        local handle_exit_code=0
        handle_repo_with_tests "$repo" "$workflows" || handle_exit_code=$?
        if [[ "$handle_exit_code" -eq 2 ]]; then
            return 2
        fi
        echo " [CORE: $RATE_LIMIT_REMAINING, SEARCH: $SEARCH_RATE_LIMIT_REMAINING]"
    else
        local handle_exit_code=0
        handle_repo_without_tests "$repo" || handle_exit_code=$?
        if [[ "$handle_exit_code" -eq 2 ]]; then
            return 2
        fi
        echo " [CORE: $RATE_LIMIT_REMAINING, SEARCH: $SEARCH_RATE_LIMIT_REMAINING]"
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

  # Resolve --start-repo if it's a repo name (contains '/') instead of a number
  if [[ "$START_REPO" == *"/"* ]]; then
    local start_repo_name="$START_REPO"
    START_REPO=""
    for i in "${!unique_repos[@]}"; do
      if [[ "${unique_repos[$i]}" == "$start_repo_name" ]]; then
        START_REPO=$((i + 1))
        break
      fi
    done
    if [[ -z "$START_REPO" ]]; then
      echo "ERROR: Repository '$start_repo_name' not found in the repo list."
      echo "Available repositories:"
      for i in "${!unique_repos[@]}"; do
        echo "  $((i + 1)): ${unique_repos[$i]}"
      done
      return 1
    fi
    echo "Starting from repository $START_REPO ($start_repo_name)"
    echo ""
  fi

  rate_limit_hit=false
  for i in "${!unique_repos[@]}"; do
    local repo_num=$((i + 1))
    local repo="${unique_repos[$i]}"

    # Skip if we haven't reached the starting repository
    if [[ $repo_num -lt $START_REPO ]]; then
        continue
    fi

    echo -n "[$repo_num/$(( ${#unique_repos[@]} ))] Checking $repo (https://github.com/$repo)... "

    # Wrap the repository processing in error handling
    local process_exit_code=0
    process_repo "$repo" || process_exit_code=$?
    if [[ "$process_exit_code" -eq 2 ]]; then
        rate_limit_hit=true
        local next_repo_num=$((repo_num))
        echo ""
        echo ""
        echo "❌ Rate limit hit while processing repository $repo_num/${#unique_repos[@]} ($repo)."
        echo "   Processed $((repo_num - START_REPO)) of $((${#unique_repos[@]} - START_REPO + 1)) repositories in this run."
        echo ""
        echo "   To resume from this repository, run:"
        echo "   $0 --github-token=<token> --start-repo=${next_repo_num}"
        echo "   or:"
        echo "   $0 --github-token=<token> --start-repo=${repo}"
        break
    elif [[ "$process_exit_code" -ne 0 ]]; then
        REPORT_ERRORS+=("$repo")
        echo "❌ ERROR processing $repo"
        continue
    fi
  done
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

# Print categorized report if requested
if [[ "$REPORT" == "true" ]]; then
    echo ""
    echo "======================================"
    echo "  REPORT"
    echo "======================================"
    echo ""
    echo "Tests OK: ${#REPORT_OK[@]}"
    echo "Disabled workflows: ${#REPORT_DISABLED[@]}"
    echo "No test workflows: ${#REPORT_NO_TESTS[@]}"
    echo "Errors: ${#REPORT_ERRORS[@]}"

    if [[ ${#REPORT_DISABLED[@]} -gt 0 ]]; then
        echo ""
        echo "--- Disabled workflows (${#REPORT_DISABLED[@]}) ---"
        for repo in "${REPORT_DISABLED[@]}"; do
            echo "  https://github.com/$repo"
        done
    fi

    if [[ ${#REPORT_NO_TESTS[@]} -gt 0 ]]; then
        echo ""
        echo "--- No test workflows (${#REPORT_NO_TESTS[@]}) ---"
        for repo in "${REPORT_NO_TESTS[@]}"; do
            echo "  https://github.com/$repo"
        done
    fi

    if [[ ${#REPORT_ERRORS[@]} -gt 0 ]]; then
        echo ""
        echo "--- Errors (${#REPORT_ERRORS[@]}) ---"
        for repo in "${REPORT_ERRORS[@]}"; do
            echo "  https://github.com/$repo"
        done
    fi
    echo ""
fi

exit ${EXIT_CODE}
