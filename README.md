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
