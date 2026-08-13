#!/usr/bin/env bash

# This bash4+ script (doesn't work on macOS)
# Queries GitHub repositories that have the `ddev-get` topic
# And looks at their tests to see if they are recent
# Depending on whether `$ORG` is set to an org it will limit to that org
# If --org = "all", it will look everywhere
# Also monitors additional critical DDEV repositories beyond add-ons
# `./check-addons.sh --github-token=<token> --org=ddev

# Token requirements (public repos only):
# - Classic PAT: public_repo
# - Fine-grained PAT: Issues (Read and Write), Metadata (Read-only); Actions (Read-only) optional.
# - Provide via GITHUB_TOKEN (e.g., export GITHUB_TOKEN=ghp_...).
# Notes:
# - Search for public data does not need special scopes; auth mainly increases rate limits.
# - No workflow/admin scopes required since this script only reads workflow state and creates/closes issues.

set -eu -o pipefail

topic="ddev-get" # Topic to filter repositories

# Additional repositories to monitor beyond topic-based filtering
# These are critical DDEV infrastructure repositories with scheduled tests
additional_repos=(
    "ddev/coder-ddev"
    "ddev/ddev"
    "ddev/ddev-gitlab-ci"
    "ddev/github-action-add-on-test"
    "ddev/github-action-setup-ddev"
    "ddev/signing_tools"
    "ddev/sponsorship-data"
)

EXIT_CODE=0

# Initialize variables
GITHUB_TOKEN=""
org=""
additional_github_repos=""
DRY_RUN=false

print_help() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --github-token=TOKEN          GitHub personal access token (required unless using --help)"
  echo "  --org=ORG                     GitHub organization to filter by (use \"all\" for all orgs)"
  echo "  --additional-github-repos=REPOS  Comma-separated list of additional repositories to monitor"
  echo "  --dry-run                     Show what would be checked without calling the GitHub API"
  echo "  --help                        Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0 --github-token=<token> --org=ddev"
  echo "  $0 --github-token=<token> --additional-github-repos=owner/repo1,owner/repo2"
  echo "  $0 --dry-run --org=ddev"
}

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
        print_help
        exit 0
        ;;
        *)
        echo "Unknown option: $arg"
        echo "Use --help for usage information"
        exit 1
        ;;
    esac
done


if [ "$DRY_RUN" = true ]; then
  echo "Mode: DRY RUN (no GitHub API calls will be made)"
  echo "Organization: ${org:-all}"
  echo "Topic: $topic"
  echo "Built-in additional repositories:"
  for repo in "${additional_repos[@]}"; do
    echo "  - $repo"
  done
  if [[ -n "$additional_github_repos" ]]; then
    echo "CLI-provided additional repositories:"
    IFS=',' read -ra cli_repos <<< "$additional_github_repos"
    for repo in "${cli_repos[@]}"; do
      echo "  - $repo"
    done
  fi
  exit 0
fi

if [ "${GITHUB_TOKEN}" = "" ]; then echo "--github-token must be set"; exit 5; fi
echo "Organization: $org"

# Use brew coreutils gdate if it exists, otherwise things fail with macOS date
# brew install coreutils
export DATE=date
if command -v gdate >/dev/null; then DATE=gdate; fi

# Fetch all repositories with the specified topic
fetch_repos_with_topic() {
  page=1
  while :; do
    query="topic:$topic"
    # if the org has been specified add it to the query, otherwise do all
    if [ "${org}" != "" ]; then query="${query}+org:$org"; fi
    repos=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github.v3+json" \
      "https://api.github.com/search/repositories?q=${query}&per_page=100&page=$page" | jq -r '.items[].full_name')

    if [[ -z "$repos" ]]; then
      break
    fi

    echo "$repos"
    ((page++))
  done
}

# Check the most recent scheduled workflow run
check_recent_scheduled_run() {
  local current_date=$(${DATE} +%s)  # Current date in seconds since the Unix epoch
  local one_day_ago=$(($current_date - 86400))  # One day ago in seconds since the Unix epoch

  # Combine topic-based repos with additional repos and deduplicate
  # Use a more compatible approach for older bash versions
  topic_repos=()
  while IFS= read -r repo; do
    [[ -n "$repo" ]] && topic_repos+=("$repo")
  done < <(fetch_repos_with_topic)

  # Start with hardcoded repos, then add CLI-provided repos
  all_repos=("${topic_repos[@]}" "${additional_repos[@]}")

  # Add CLI-provided repos if available
  cli_repos=()
  if [[ -n "$additional_github_repos" ]]; then
    IFS=',' read -ra cli_repos <<< "$additional_github_repos"
    all_repos=("${all_repos[@]}" "${cli_repos[@]}")
  fi

  # Remove duplicates using a simpler approach compatible with older bash
  unique_repos=()
  for repo in "${all_repos[@]}"; do
    # Check if repo is already in unique_repos array
    duplicate=false
    if [[ ${#unique_repos[@]} -gt 0 ]]; then
      for existing in "${unique_repos[@]}"; do
        if [[ "$repo" == "$existing" ]]; then
          duplicate=true
          break
        fi
      done
    fi
    if [[ "$duplicate" == false ]]; then
      unique_repos+=("$repo")
    fi
  done

  # Calculate total additional repos (hardcoded + CLI)
  total_additional=$((${#additional_repos[@]} + ${#cli_repos[@]}))
  echo "Checking ${#unique_repos[@]} total repositories (${#topic_repos[@]} from topic '${topic}', ${total_additional} additional)"

  for repo in "${unique_repos[@]}"; do
    repo_url="https://github.com/$repo"
    actions_url="$repo_url/actions"
    # Fetch the most recent scheduled workflow run. GitHub's `event=schedule`
    # filter sometimes answers with a run that is days or weeks old, so if that
    # happens, ask again without the filter, which is reliable but only reaches
    # back 100 runs. The runs are sorted here because the newest one is not
    # always first.
    local run_date="" run_date_seconds=0 candidate candidate_date candidate_seconds
    for url in \
      "https://api.github.com/repos/$repo/actions/runs?event=schedule&per_page=30" \
      "https://api.github.com/repos/$repo/actions/runs?per_page=100"; do

      candidate=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$url" |
        jq '{workflow_runs: [.workflow_runs[]? | select(.event == "schedule")] | sort_by(.created_at) | reverse}')
      candidate_date=$(echo "$candidate" | jq -r '.workflow_runs[0].updated_at // empty')
      [[ -z "$candidate_date" ]] && continue

      candidate_seconds=$(${DATE} -d "$candidate_date" +%s)
      # Keep whichever query found the newer run
      if [[ "$candidate_seconds" -gt "$run_date_seconds" ]]; then
        response="$candidate"
        run_date="$candidate_date"
        run_date_seconds="$candidate_seconds"
      fi

      # A recent run is trustworthy, so the second query is not needed
      if [[ "$run_date_seconds" -gt "$one_day_ago" ]]; then break; fi
    done

    # Check if any runs are returned
    if [[ "$run_date_seconds" -eq 0 ]]; then
      echo "ERROR: No scheduled runs found for $repo. Check workflows at $actions_url"
      EXIT_CODE=3
      continue # Skip to the next repository
    fi

    # Extract the conclusion of the most recent scheduled run
    status=$(echo "$response" | jq -r '.workflow_runs[0] | select(.conclusion != null) | .conclusion')
    timestamp="$run_date"
    run_url=$(echo "$response" | jq -r '.workflow_runs[0].html_url')

    # Check if the run date is within the last day
    if [[ "${run_date_seconds}" -le "$one_day_ago" ]]; then
      echo "ERROR: The most recent scheduled run for $repo was not within the last day. Latest run: $run_url (workflow list: $actions_url)"
        EXIT_CODE=2
    fi


    echo "$repo: $status (${timestamp})"
    if [[ "$status" == "failure" ]]; then
      echo "ERROR: Scheduled test failed in $repo at $run_url ($timestamp)"
      EXIT_CODE=1
    fi
  done
}

check_recent_scheduled_run
exit ${EXIT_CODE}
