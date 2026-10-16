# `occidata-runner-maintenance.yml`: keep the `occidata` runner clean

[← Workflows of control-toolbox](../README.md)

Runs **on the `occidata` self-hosted runner itself** (`runs-on: [self-hosted, occidata]`),
in CTActions, every Monday at 02:30 UTC and by hand (`workflow_dispatch`). No package
calls it. See [Runners](../conventions/runners.md#occidata-a-gpu-on-demand) for the
runner.

| Step | Why |
| --- | --- |
| Sanitize the runner's git config (`scripts/sanitize_runner_gitconfig.sh`, control-toolbox/occidata) | Removes `url.*.insteadOf` rewrites (an `https → git@github.com:` rewrite broke every checkout on 2026-09-28, the cluster having no SSH key), deduplicates `safe.directory`, checks HTTPS access. First, so that it runs even if a later step fails |
| Purge the Julia compile cache (`julia_depot/compiled`) | A persistent depot accumulates stale precompiled code |
| Update TeXLive (`tlmgr update --self --all`) | Keeps the runner's TeXLive current |
| Delete logs older than 30 days | Disk |
| Prune the runner's private `TMPDIR` (entries older than 2 days) | Jobs' temporary files (Pkg's test sandboxes) live there instead of the node's `/tmp`, which has a cleaner; this directory has none. A CI run lasts under an hour, so a live sandbox is never touched |

The first job after the purge runs cold (it precompiles everything): slower, not
unhealthy.
