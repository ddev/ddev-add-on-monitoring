# ddev-add-on-monitoring
Monitoring tools for DDEV add-ons

This repository provides scripts for monitoring DDEV add-ons and their test workflows:

- `check-addons.sh` - Monitors scheduled GitHub Actions workflows
- `notify-addon-owners.sh` - Notifies owners about disabled test workflows

## What it monitors

Both scripts monitor the same set of repositories:

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

Add additional repositories to monitor:
```bash
./check-addons.sh --github-token=<token> --org=ddev --additional-github-repos="owner/repo1,owner/repo2,owner/repo3"
```

### Options

- `--github-token=TOKEN` - GitHub personal access token (required)
- `--org=ORG` - GitHub organization to filter by (use "all" for all orgs)  
- `--additional-github-repos=REPOS` - Comma-separated list of additional repositories to monitor

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

The script identifies repositories that lack test workflows and provides information for manual follow-up:
- Suggests adding test workflows
- Recommends removing the `ddev-get` topic if tests won't be added
