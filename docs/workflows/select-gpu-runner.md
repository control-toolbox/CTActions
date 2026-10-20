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
- **Unknown is offline.** Without `RUNNERS_STATUS_TOKEN`, or if the API call fails, the
  fallback is chosen with a warning: slower, never stuck.

## The secret `RUNNERS_STATUS_TOKEN`

An **organization secret**, shared with the repositories that call it. The workflow's
`GITHUB_TOKEN` cannot list the organization's runners: the token needs "Self-hosted
runners: read" on the organization (fine-grained PAT or GitHub App). A caller passes it
explicitly, `RUNNERS_STATUS_TOKEN: ${{ secrets.RUNNERS_STATUS_TOKEN }}`.
