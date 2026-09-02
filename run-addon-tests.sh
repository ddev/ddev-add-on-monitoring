#!/usr/bin/env bash

# Dispatches the `tests` workflow on the default branch of every repository with
# the `ddev-get` topic, writing "repo run_id" lines for run-addon-tests-check.sh.
# Uses the `gh` CLI login; override with GH_TOKEN="$(gh auth token)".
#
# Usage: ./run-addon-tests.sh [run-ids-file]  (default $HOME/tmp/addon-test-runs.txt)

set -eu -o pipefail

topic="ddev-get"
workflow="tests.yml"
run_ids_file="${1:-$HOME/tmp/addon-test-runs.txt}"

poll_attempts=40
poll_interval=3

EXIT_CODE=0

# Newest run, found by ID because the API does not reliably return it first
latest_run_id() {
  gh run list --repo "$1" --workflow "$workflow" --limit 100 \
    --json databaseId --jq '[.[].databaseId] | max // 0'
}

mkdir -p "$(dirname "$run_ids_file")"
: > "$run_ids_file"

repos=$(gh search repos --owner=ddev --topic="$topic" --limit=1000 \
  --json=fullName --jq='.[].fullName' | sort)

for repo in $repos; do
  actions_url="https://github.com/$repo/actions"

  # `gh workflow run` reports no run ID, so remember what was newest beforehand
  before_id=$(latest_run_id "$repo")

  if ! gh workflow run "$workflow" --repo "$repo"; then
    echo "ERROR: Dispatch of $workflow in $repo failed. Check $actions_url"
    EXIT_CODE=1
    continue
  fi

  run_id="$before_id"
  for ((attempt = 0; attempt < poll_attempts; attempt++)); do
    sleep "$poll_interval"
    run_id=$(latest_run_id "$repo")
    if [[ "$run_id" != "$before_id" ]]; then break; fi
  done

  if [[ "$run_id" == "$before_id" ]]; then
    echo "ERROR: Dispatched $workflow in $repo but no new run appeared. Check $actions_url"
    EXIT_CODE=1
    continue
  fi

  echo "$repo $run_id" >> "$run_ids_file"
  echo "$repo: dispatched (https://github.com/$repo/actions/runs/$run_id)"
done

echo ""
echo "Dispatched $(wc -l < "$run_ids_file" | tr -d ' ') runs, IDs written to $run_ids_file"
echo "Now wait for them and report the conclusions with:"
echo "  ./run-addon-tests-check.sh $run_ids_file"

exit ${EXIT_CODE}
