# `select-gpu-runner.yml`: kkt, else occidata

[← Workflows of control-toolbox](../README.md)

Picks the self-hosted GPU runner of a job: `kkt` unless it is offline, else `occidata`;
with `when_busy: 'skip'`, only a runner online **and idle** counts, and the job is skipped
when neither is. Called by [`ci-gpu.yml`](ci-gpu.md) (`wait`) and by
[`documentation.yml`](documentation.md#choosing-the-gpu-runner) (`gpu_runner: 'auto'`,
`skip`); a package does not call it directly.

| Input | Default | Meaning |
| --- | --- | --- |
| `preferred` | `kkt` | Runner label used when it is not offline |
| `fallback` | `occidata` | Runner label used otherwise |
| `when_busy` | `wait` | `wait`: a busy runner is waited for; `skip`: only an online and idle runner counts, else `skip` is `true` |
| `ctactions_ref` | `main` | Ref of CTActions whose script decides (a branch to test a change) |

| Output | Example | For |
| --- | --- | --- |
| `runner` | `kkt` | messages; empty when `skip` is `true` |
| `skip` | `false` | `true` when, with `when_busy: 'skip'`, no runner is online and idle: the caller skips its job |
| `runs_on_matrix` | `[["kkt"]]` | `runs_on` of `ci.yml` |
| `runs_on_labels` | `["kkt"]` | `runs-on: ${{ fromJSON(…) }}` |

## Rules

- **`wait` (default, the tests): only *offline* counts.** A busy `kkt` is waited for: its
  queue is shorter than a cold `occidata` run (a GPU node through SLURM, a cold depot).
- **`skip` (the docs): online and idle, else nothing.** `kkt` if online and idle, else
  `occidata` if online and idle, else `skip` is `true`. A GPU pass of the docs queued for a
  busy runner would hold the concurrency group of the caller, and the docs of the next
  commits would wait for it (CTActions#174); skipping it leaves the site of the CPU build.
- **The state is read once**, when the job runs, from `gh api orgs/<org>/actions/runners`.
  A runner that goes offline afterwards leaves the job queued; the caller's timeout bounds it.
- **Unknown is offline.** Without the `CT_RUNNERS_*` secrets, or if the token or the API call fails, the
  fallback is chosen with a warning: slower, never stuck. It is never skipped then, even
  with `skip`: in doubt, the job runs ([principle 7](../principles.md#7-in-doubt-the-safe-side)).
- **The decision is a script**, [`scripts/select-gpu/pick.sh`](../../scripts/select-gpu/pick.sh):
  the workflow reads the runners (`labels`, `status`, `busy`) and passes them to it.
  `scripts/select-gpu/test.sh` covers both modes and the unknown state; `select-gpu-tests.yml`
  runs it on a change.

## The GitHub App `ct-runners`

The workflow's `GITHUB_TOKEN` cannot list the organization's runners, so the job mints a
one-hour token as the App `ct-runners`, whose only permission is the organization's
**Self-hosted runners: read**. Its secrets `CT_RUNNERS_CLIENT_ID` and
`CT_RUNNERS_PRIVATE_KEY` are organization secrets, visible to **every repository** (*Repository access*: all,
checked on 2026-11-13), so a new package needs nothing. They are not the secrets of the
other App [`ct-prune-compat`](../conventions/github-app.md): that one writes to the
packages, and its key stays in CTActions. A leaked `ct-runners` key
reveals the state of the runners and nothing else. A caller passes the two secrets
explicitly:

```yaml
    secrets:
      CT_RUNNERS_CLIENT_ID: ${{ secrets.CT_RUNNERS_CLIENT_ID }}
      CT_RUNNERS_PRIVATE_KEY: ${{ secrets.CT_RUNNERS_PRIVATE_KEY }}
```

A key does not expire. If it is deleted or the App uninstalled, the step fails softly and
the job warns, then falls back to occidata: the symptom is a slower CI, with that
warning in the `select` job. Rotate the key as for `ct-prune-compat`: generate a new one in the
App's settings, update `CT_RUNNERS_PRIVATE_KEY`, delete the old one.
