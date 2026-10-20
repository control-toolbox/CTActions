# `ci.yml`: the test suite

[← Workflows of control-toolbox](../README.md)

Builds the package and runs its test suite over a Julia version × runner
matrix, on GitHub-hosted or self-hosted runners. Caller: `CI.yml`, in every package.

## Caller

```yaml
# .github/workflows/CI.yml
name: CI

on:
  push:
    branches: [main]
    tags: '*'
  pull_request:
    types: [labeled, synchronize, reopened]

jobs:
  test-cpu-github:
    if: >
      github.event_name != 'pull_request' ||
      (github.event.action == 'labeled' && github.event.label.name == 'run ci github-runner') ||
      (github.event.action != 'labeled' && contains(github.event.pull_request.labels.*.name, 'run ci github-runner'))
    uses: control-toolbox/CTActions/.github/workflows/ci.yml@main
    with:
      runs_on: '["ubuntu-latest", "macos-latest", "windows-latest"]'
      runner_type: 'github'
      use_ct_registry: true
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}
```

The guard and the `types:` list are explained in [Labels](../conventions/labels.md).
`runs_on` lists the three GitHub-hosted OSes, Windows included. CTBase is the reference
caller to copy from; it also carries a Windows smoke test of its test selection
(`test-selection-smoke`), added after Windows' backslash-separated paths silently broke a
forward-slash glob.

## Inputs and secrets

| Input | Default | Meaning |
| --- | --- | --- |
| `versions` | `'["1.10","1.12","1.13"]'` | Julia versions (JSON array) |
| `runs_on` | `'["ubuntu-latest","macos-latest","windows-latest"]'` | One matrix entry per element: a label, or a list of labels for a self-hosted runner (`'[["occidata"]]'`) |
| `runner_type` | `'github'` | `github` or `self-hosted`: selects the caching and test steps |
| `use_ct_registry` | `false` | Add `ct-registry` (needs `SSH_KEY`) |
| `test_args` | `''` | Forwarded to `Pkg.test` (e.g. `'GPU'`, `'cron'`, file globs) |

| Secret | |
| --- | --- |
| `SSH_KEY` | for `ct-registry`, see [Secrets](../conventions/secrets.md#ct-registry) |

## What it does

- **GitHub-hosted:** `julia-actions/cache`, then `julia-buildpkg` and `julia-runtest`.
- **Self-hosted:** caches of `artifacts/` and `compiled/` at the depot Julia reports,
  `TMPDIR` moved off the node's `/tmp`, the tests run through `$OCCIDATA_GPU_RUN` (a GPU
  node on `occidata`, nothing elsewhere), and **retried once after purging `compiled/`**,
  since a persistent depot can hold stale precompiled code. See
  [Runners](../conventions/runners.md).
- **`force_latest_compatible_version: auto`** on CompatHelper and Dependabot branches: a
  CompatHelper PR is tested with the newest versions it allows. **Except on Julia 1.10**
  (CTActions#93): Pkg forces the latest registered version without checking Julia
  compatibility (JET 0.12 needs Julia ≥ 1.11), which makes resolution fail. The newest
  versions are still tested on the newer Julia versions.
- **Windows with `ct-registry`:** Git's own OpenSSH client and Pkg's CLI git, because
  Windows' OpenSSH and Julia's LibGit2 cannot use the agent `add-julia-registry` starts
  (details in the workflow's comments).

## Split CI

A package with GPU-relevant code adds one job per self-hosted runner, each with its own
label (see [Runners](../conventions/runners.md#split-ci)):

```yaml
  test-gpu-occidata:
    if: >
      github.event_name == 'pull_request' &&
      ((github.event.action == 'labeled' && github.event.label.name == 'run ci occidata-runner') ||
      (github.event.action != 'labeled' && contains(github.event.pull_request.labels.*.name, 'run ci occidata-runner')))
    uses: control-toolbox/CTActions/.github/workflows/ci.yml@main
    with:
      runs_on: '[["occidata"]]'
      runner_type: 'self-hosted'
      use_ct_registry: true
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}
```

A `kkt` job is the same with `kkt` and `run ci kkt-runner`.

The two GPU jobs are guarded `github.event_name == 'pull_request' && (…)`: on a PR each
runs on its label. On a push (`main`, tags) a single job picks the runner at run time,
`kkt` unless it is offline, else `occidata` ([`ci-gpu.yml`](ci-gpu.md)):

```yaml
  test-gpu-main:
    if: github.event_name != 'pull_request'
    uses: control-toolbox/CTActions/.github/workflows/ci-gpu.yml@main
    with:
      use_ct_registry: true
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}
      RUNNERS_STATUS_TOKEN: ${{ secrets.RUNNERS_STATUS_TOKEN }}
```
 CTFlows.jl also calls
`ci.yml` from `CITargeted.yml` (a subset of the tests on a chosen runner, by hand) and
`CronIntegration.yml` (weekly slow tests, `test_args: 'cron'`): see
[Workflows defined in a package](per-repo.md).
