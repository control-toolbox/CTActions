# `select-gpu-runner.yml`: kkt, else occidata

[← Workflows of control-toolbox](../README.md)

Picks the self-hosted GPU runner of a job: `kkt` unless it is offline, else `occidata`.
Called by [`ci-gpu.yml`](ci-gpu.md) and by [`documentation.yml`](documentation.md#choosing-the-gpu-runner)
(`gpu_runner: 'auto'`); a package does not call it directly.

| Input | Default | Meaning |
| --- | --- | --- |
| `preferred` | `kkt` | Runner label used when it is not offline |
| `fallback` | `occidata` | Runner label used otherwise |

| Output | Example | For |
| --- | --- | --- |
| `runner` | `kkt` | messages |
| `runs_on_matrix` | `[["kkt"]]` | `runs_on` of `ci.yml` |
| `runs_on_labels` | `["kkt"]` | `runs-on: ${{ fromJSON(…) }}` |

## Rules

- **Only *offline* counts.** A busy `kkt` is waited for: its queue is shorter than a cold
  `occidata` run (a GPU node through SLURM, a cold depot).
- **The state is read once**, when the job runs, from `gh api orgs/<org>/actions/runners`.
  A runner that goes offline afterwards leaves the job queued; the caller's timeout bounds it.
- **Unknown is offline.** Without the `CT_RUNNERS_*` secrets, or if the token or the API call fails, the
  fallback is chosen with a warning: slower, never stuck.

## The GitHub App `ct-runners`

The workflow's `GITHUB_TOKEN` cannot list the organization's runners, so the job mints a
one-hour token as the App `ct-runners`, whose only permission is the organization's
**Self-hosted runners: read**. Its secrets `CT_RUNNERS_CLIENT_ID` and
`CT_RUNNERS_PRIVATE_KEY` are organization secrets, visible to the packages with a GPU CI
(not CTActions, not the other App [`ct-prune`](../conventions/github-app.md): that one
writes to the packages, and its key stays in CTActions). A leaked `ct-runners` key
reveals the state of the runners and nothing else. A caller passes the two secrets
explicitly:

```yaml
    secrets:
      CT_RUNNERS_CLIENT_ID: ${{ secrets.CT_RUNNERS_CLIENT_ID }}
      CT_RUNNERS_PRIVATE_KEY: ${{ secrets.CT_RUNNERS_PRIVATE_KEY }}
```

A key does not expire. If it is deleted or the App uninstalled, the step fails softly and
the job warns, then falls back to occidata: the symptom is a slower CI, with that
warning in the `select` job. Rotate the key as for `ct-prune`: generate a new one in the
App's settings, update `CT_RUNNERS_PRIVATE_KEY`, delete the old one.
