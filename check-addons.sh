#!/bin/bash

# This bash4+ script (doesn't work on macOS)
# Queries GitHub repositories that have the `ddev-get` topic
# And looks at their tests to see if they are recent
# Depending on whether `$ORG` is set to an org it will limit to that org
# If ORG = "all", it will look everywhere

set -eu -o pipefail

org=${ORG:-all}
topic="ddev-get" # Topic to filter repositories
if [ "${org}" = "all" ]; then org=""; fi

# Fetch all repositories with the specified topic
fetch_repos_with_topic() {
  page=1
  while :; do
    query="topic:$topic"
    # if the org has been specified add it to the query, otherwise do all
    if [ "${org}" != "all" ]; then query="${query}+org:$org"; fi
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
  local current_date=$(date +%s)  # Current date in seconds since the Unix epoch
  local one_week_ago=$(($current_date - 604800))  # One week ago in seconds since the Unix epoch

  mapfile -t repos < <(fetch_repos_with_topic)
  for repo in "${repos[@]}"; do
    # Fetch only the most recent scheduled workflow run
    response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/$repo/actions/runs?event=schedule&per_page=1")

    # Check if any runs are returned
    if [ "$(echo "$response" | jq -r '.workflow_runs | length')" -eq 0 ]; then
      echo "No scheduled runs found for $repo"
      continue # Skip to the next repository
    fi

    # Extract the conclusion of the most recent scheduled run
    status=$(echo "$response" | jq -r '.workflow_runs[0] | select(.conclusion != null) | .conclusion')
    timestamp=$(echo $response | jq -r '.workflow_runs[0].updated_at')

    local run_date=$(echo "$response" | jq -r '.workflow_runs[0].updated_at')
    local run_date_seconds=$(date -d "$run_date" +%s)  # Convert run date to seconds since the Unix epoch

    # Check if the run date is within the last week
    if [[ "${run_date_seconds}" -le "$one_week_ago" ]]; then
        echo "ERROR: The most recent scheduled run for $repo was not within the last week."
    fi


    echo "$repo: $status (${timestamp})"
    if [[ "$status" == "failure" ]]; then
      # Get URL of the failed run
      run_url=$(echo "$response" | jq -r '.workflow_runs[0].html_url')
      echo "ERROR: Scheduled test failed in $repo at $run_url ($timestamp)"
    fi
  done
}

check_recent_scheduled_run
