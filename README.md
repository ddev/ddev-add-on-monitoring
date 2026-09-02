# ddev-add-on-monitoring
Monitoring tools for DDEV add-ons

This repository provides scripts for monitoring DDEV add-ons and their test workflows:

- `check-addons.sh` - Monitors scheduled GitHub Actions workflows
- `notify-addon-owners.sh` - Notifies owners about disabled test workflows
- `run-addon-tests.sh` - Runs every add-on's tests on demand
- `run-addon-tests-check.sh` - Waits for those runs and reports which ones failed

## What it monitors

`check-addons.sh` and `notify-addon-owners.sh` monitor the same set of repositories:

- **Topic-based repositories**: All repositories with the `ddev-get` topic
- **Critical DDEV infrastructure**: Key repositories like `ddev/ddev`, `ddev/github-action-add-on-test`, etc.
- **Additional repositories**: Configurable list via command line

## check-addons.sh

Monitors DDEV repositories by checking their scheduled GitHub Actions workflows for recent successful runs.

### Usage

Basic usage:
```bash
./check-addons.sh --github-token=<token> --org=ddev
```

Preview what would be checked without calling the GitHub API:
```bash
./check-addons.sh --dry-run --org=ddev
```

Add additional repositories to monitor:
```bash
./check-addons.sh --github-token=<token> --org=ddev --additional-github-repos="owner/repo1,owner/repo2,owner/repo3"
```

### Options

- `--github-token=TOKEN` - GitHub personal access token (required)
- `--org=ORG` - GitHub organization to filter by (use "all" for all orgs)  
- `--additional-github-repos=REPOS` - Comma-separated list of additional repositories to monitor
- `--dry-run` - Show what would be checked without calling the GitHub API
- `--help` - Show help information

### Exit codes

- `0` - All monitored repositories have recent successful scheduled runs
- `1` - One or more repositories have failed scheduled runs
- `2` - One or more repositories haven't had scheduled runs within the last day
- `3` - One or more repositories have no scheduled runs configured
- `5` - GitHub token not provided

## notify-addon-owners.sh

Notifies repository owners when their test workflows are disabled. Uses GitHub issues for tracking notification history to avoid spamming owners.

### Usage

Test without taking action:
```bash
./notify-addon-owners.sh --github-token=<token> --dry-run
```

Basic usage:
```bash
./notify-addon-owners.sh --github-token=<token> --org=ddev
```

Test specific owner's repositories:
```bash
./notify-addon-owners.sh --github-token=<token> --org=myusername --dry-run
```

### Options

- `--github-token=TOKEN` - GitHub personal access token (required)
- `--org=ORG` - GitHub organization to filter by
- `--additional-github-repos=REPOS` - Comma-separated list of additional repositories to monitor
- `--dry-run` - Show what would be done without taking action
- `--help` - Show help information

### Features

- **Issue-based tracking**: Uses GitHub issues to track notification history
- **Rate limiting**: Maximum 2 notifications per repository with 30-day intervals
- **Cooldown period**: 60-day cooldown after issue closure to handle repeated disabling
- **Automatic cleanup**: Closes issues when workflows are re-enabled
- **Dry-run mode**: Test functionality without affecting real repositories

### Notification Logic

1. **First notification**: Creates an issue with `automated-notification` and `ddev-addon-test` labels
2. **Follow-up notifications**: Adds comments to existing issues (max 2 total notifications)
3. **Cooldown period**: Waits 60 days after issue closure before re-notifying
4. **Automatic resolution**: Closes issues when workflows are re-enabled

### Repositories Without Test Workflows

Repositories that have the `ddev-get` topic but no `tests` workflow at all go through the same
notification lifecycle as disabled workflows (create, follow up up to twice, cooldown after
closure). The issue points maintainers at the `ddev-addon-template` repository's recommended
`tests.yml`, the `addon-update-checker.sh` script, and the option to remove the `ddev-get` topic
if the add-on doesn't need to be automatically discoverable. The notification is automatically
closed once a `tests` workflow shows up, whether or not it's currently enabled.

### Required GitHub token scopes

This tool only targets public repositories and needs to search/list and create/close issues.

- Classic PAT (recommended for cross-org/public repos):
    - public_repo

- Fine-grained PAT:
    - Repository access: All repositories in the target org(s) or the specific repositories you’ll monitor
    - Permissions:
        - Issues: Read and Write
        - Metadata: Read-only
        - Actions: Read-only (optional; not strictly required for reading workflow state on public repos)

Notes
- The Search API for public data does not require special scopes; authenticating primarily increases rate limits.
- Creating/closing issues in public repositories requires public_repo for Classic PAT; no org admin scopes are needed.
- Some repositories may restrict who can open issues (interaction limits or disabled issues). The script handles permission errors gracefully, but no additional scopes can bypass repo-level restrictions.

### Safely providing the token

The script only accepts the token via `--github-token=<token>` (there is no `GITHUB_TOKEN` environment variable fallback), so avoid typing or pasting the raw token on the command line. If you're already authenticated with the `gh` CLI, pull the token from it instead:

```bash
./notify-addon-owners.sh --github-token=$(gh auth token) --dry-run
```

This keeps the literal token out of your shell history — only the `$(gh auth token)` expression is recorded, not the value it expands to.

## Manual Testing

### Environment Variables

The script supports several environment variables for testing and configuration:

- `NOTIFICATION_INTERVAL_DAYS` - Days between notifications (default: 30)
- `RENOTIFICATION_COOLDOWN_DAYS` - Days to wait after issue closure before re-notifying (default: 60)

### Testing Scenarios

#### Testing with Disabled Workflows
Use the `ddev-test` organization which contains repositories with disabled workflows:

```bash
# Dry run to see what would be done
./notify-addon-owners.sh --github-token=<token> --org=ddev-test --dry-run

# Real run (will create issues if needed)
./notify-addon-owners.sh --github-token=<token> --org=ddev-test
```

#### Testing Notification Timing
To test the notification timing without waiting for the default intervals:

```bash
# Set notification interval to 0 days for immediate re-notification
NOTIFICATION_INTERVAL_DAYS=0 ./notify-addon-owners.sh --github-token=<token> --org=ddev-test --dry-run

# Set cooldown period to 0 days to test immediate re-notification after closure
RENOTIFICATION_COOLDOWN_DAYS=0 ./notify-addon-owners.sh --github-token=<token> --org=ddev-test --dry-run
```

#### Testing with Specific Repositories
Test with a specific repository:

```bash
# Test a single repository
./notify-addon-owners.sh --github-token=<token> --additional-github-repos="owner/repo" --dry-run
```

#### Testing Issue Management
To test issue creation and closing behavior:

1. **First run**: Creates initial notification issue
2. **Re-enable workflows**: Run again to see issue closing behavior
3. **Disable workflows again**: Run with `NOTIFICATION_INTERVAL_DAYS=0` to test re-notification

#### Debugging
Use bash debug mode to troubleshoot issues:

```bash
bash -x ./notify-addon-owners.sh --github-token=<token> --org=ddev-test --dry-run
```

### GitHub Token Requirements

The script requires a GitHub personal access token with the following permissions:

- **repo**: Full access to repository information, issues, and workflows
- **read:org**: Read organization information (when using organization filters)

For creating issues, the token must have write permissions for the target repositories.

## run-addon-tests.sh and run-addon-tests-check.sh

These two exist to confirm that the add-on tests pass against the current DDEV HEAD.
You don't normally need to run them by hand, since the add-on tests already run on a
daily schedule, but when you're about to make a release you usually want to make sure
that the latest DDEV HEAD is good.

`run-addon-tests.sh` dispatches the `tests` workflow on the default branch of every
`ddev` org repository with the `ddev-get` topic, then writes one `repo run_id` line per
dispatch to `$HOME/tmp/addon-test-runs.txt`. Each add-on's `tests.yml` runs a
`[stable, HEAD]` matrix, so a dispatch covers HEAD alongside the released version.

`run-addon-tests-check.sh` reads that file and waits for every run to complete, naming
the repositories it's still waiting on, and then reports each conclusion with a link to
the run.

Both use whatever login the `gh` CLI has, and `GH_TOKEN` overrides it. Dispatching a
workflow is a write operation, so unlike the other scripts here these need a token with
`workflow` (Classic PAT) or Actions write (fine-grained PAT) access.

### Usage

```bash
./run-addon-tests.sh
./run-addon-tests-check.sh
```

Keep the run IDs somewhere else, for instance to leave an earlier batch untouched:

```bash
./run-addon-tests.sh ~/tmp/pre-release-runs.txt
./run-addon-tests-check.sh ~/tmp/pre-release-runs.txt
```

Use a token other than the `gh` login's:

```bash
GH_TOKEN="$(gh auth token)" ./run-addon-tests.sh
```

### Exit codes

- `0` - Every workflow was dispatched, and every run succeeded
- `1` - A dispatch failed, or a run did not succeed
- `4` - The run IDs file is missing or empty, so there is nothing to wait for

Each add-on's `tests.yml` sets `cancel-in-progress` for the same ref, so a dispatch
cancels an in-flight scheduled run in that repository, and dispatching twice in a row
cancels the first batch.
