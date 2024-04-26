# ddev-add-on-monitoring
Monitoring tools for DDEV add-ons

So far this provides `check-addons.sh`, (bash5 script) which queries for 
repositories with the `ddev-get` topic and then sees if their tests are
running and if they are, if they're succeeding.

It requires GITHUB_TOKEN with read:org privs and optionally ORG=all or ORG=ddev
