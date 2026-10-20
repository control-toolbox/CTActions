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

An **organization secret**, shared with the repositories that call it **and with
CTActions** (for the expiry check below). The workflow's `GITHUB_TOKEN` cannot list the
organization's runners. A caller passes it explicitly,
`RUNNERS_STATUS_TOKEN: ${{ secrets.RUNNERS_STATUS_TOKEN }}`.

Creating it (an organization owner):

1. GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained
   tokens** → Generate new token. Resource owner: `control-toolbox`; expiration: the
   longest the organization allows; **no repository access needed**.
2. Organization permissions: **Self-hosted runners: Read-only**. Nothing else.
3. If the organization requires approval of tokens, approve it
   (Organization → Settings → Personal access tokens → Pending requests).
4. Organization → Settings → Secrets and variables → Actions → New organization secret
   `RUNNERS_STATUS_TOKEN`, repository access to the packages with a GPU CI (CTSolvers,
   CTFlows, CTLie, CTDirect, CTParser, OptimalControl) **and CTActions**.
5. Run [`token-expiry.yml`](#token-expiry) by hand to check it.

## Token expiry

When the token expires, the selection does not fail: it falls back to occidata, and
the only symptom is a slower CI. [`token-expiry.yml`](../../.github/workflows/token-expiry.yml)
(weekly, Saturday) calls the same endpoint with the token and reads the expiry GitHub
reports for it (the `github-authentication-token-expiration` header: no date to keep by
hand). It opens an issue `RUNNERS_STATUS_TOKEN needs attention` in CTActions when the token
is rejected (401, expired or revoked), lacks the permission (403/404), is not shared with
CTActions, or expires within 30 days, and closes it when all is well. It reports with
`github.token` only, so it works the day the PAT does not. A job that selected occidata
because of a rejected token says so in its warning.
