# ddev-add-on-monitoring
Monitoring tools for DDEV add-ons

This provides `check-addons.sh`, a bash script that monitors DDEV repositories by checking their scheduled GitHub Actions workflows.

## What it monitors

- **Topic-based repositories**: All repositories with the `ddev-get` topic
- **Critical DDEV infrastructure**: Key repositories like `ddev/ddev`, `ddev/github-action-add-on-test`, etc.
- **Additional repositories**: Configurable list via command line

## Usage

Basic usage:
```bash
./check-addons.sh --github-token=<token> --org=ddev
```

Add additional repositories to monitor:
```bash
./check-addons.sh --github-token=<token> --org=ddev --additional-github-repos="owner/repo1,owner/repo2,owner/repo3"
```

## Options

- `--github-token=TOKEN` - GitHub personal access token (required)
- `--org=ORG` - GitHub organization to filter by (use "all" for all orgs)  
- `--additional-github-repos=REPOS` - Comma-separated list of additional repositories to monitor

## Exit codes

- `0` - All monitored repositories have recent successful scheduled runs
- `1` - One or more repositories have failed scheduled runs
- `2` - One or more repositories haven't had scheduled runs within the last day
- `3` - One or more repositories have no scheduled runs configured
- `5` - GitHub token not provided
