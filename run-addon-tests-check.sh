#!/usr/bin/env bash

# Waits for the workflow runs recorded by `run-addon-tests.sh` and reports the
# conclusion of each one.
# Uses the `gh` CLI login; override with GH_TOKEN="$(gh auth token)".
#
# Usage: ./run-addon-tests-check.sh [run-ids-file]  (default $HOME/tmp/addon-test-runs.txt)

set -eu -o pipefail

run_ids_file="${1:-$HOME/tmp/addon-test-runs.txt}"
poll_interval=30

EXIT_CODE=0

# Retried because gh also fails on a blip, and an unreadable run must not be
# mistaken for one that is still going
run_status() {
  local attempt status
  for attempt in 1 2 3; do
    if status=$(gh run view "$2" --repo "$1" --json status,conclusion \
      --jq '.status + " " + (.conclusion // "pending")' 2>/dev/null); then
      echo "$status"
      return
    fi
    sleep 2
  done
  echo "unavailable"
}

if [[ ! -s "$run_ids_file" ]]; then
  echo "No runs to check: $run_ids_file is missing or empty. Run ./run-addon-tests.sh first"
  exit 4
fi

repos=()
run_ids=()
while read -r repo run_id; do
  [[ -z "${repo:-}" || -z "${run_id:-}" ]] && continue
  repos+=("$repo")
  run_ids+=("$run_id")
done < "$run_ids_file"

echo "Watching ${#repos[@]} runs from $run_ids_file"

# A status is asked for once and then kept, so a finished run is not polled
# again and the report below needs no further requests
statuses=()
while :; do
  pending=()
  for i in "${!repos[@]}"; do
    if [[ -n "${statuses[$i]:-}" ]]; then continue; fi
    status=$(run_status "${repos[$i]}" "${run_ids[$i]}")
    case "${status%% *}" in
      completed | unavailable) statuses[$i]="$status" ;;
      *) pending+=("${repos[$i]#*/}") ;;
    esac
  done
  if [[ "${#pending[@]}" -eq 0 ]]; then break; fi
  echo "$(date +%H:%M:%S) waiting on ${#pending[@]} of ${#repos[@]}: ${pending[*]}"
  sleep "$poll_interval"
done

failed=0
for i in "${!repos[@]}"; do
  repo="${repos[$i]}"
  run_url="https://github.com/$repo/actions/runs/${run_ids[$i]}"
  echo "$repo: ${statuses[$i]} ($run_url)"
  if [[ "${statuses[$i]}" != "completed success" ]]; then
    ((failed++))
    echo "ERROR: Test run did not succeed in $repo at $run_url"
    EXIT_CODE=1
  fi
done

echo ""
echo "Final: $failed of ${#repos[@]} runs did not succeed"

exit ${EXIT_CODE}
