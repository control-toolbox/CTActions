# `ci.yml`: the test suite

[← Workflows of control-toolbox](../README.md)

Builds the package and runs its test suite over a Julia version × runner
matrix, on GitHub-hosted or self-hosted runners. Caller: `CI.yml`, in every package.

## Caller

```yaml
# .github/workflows/CI.yml
name: CI
run-name: "CI ${{ inputs.target }}${{ inputs.pr && format(' #{0}', inputs.pr) || '' }}"

on:
  push:
    branches: [main]
    tags: '*'
  workflow_dispatch:          # by label-dispatch.yml, when a `run ci …` label is added
    inputs:
      pr:
        description: 'Pull request number, set by label-dispatch.yml'
        required: false
        default: ''
      target:
        description: 'github, occidata or kkt'
        required: false
        default: ''

jobs:
  test-cpu-github:
    if: github.event_name == 'push' || inputs.target == 'github'
    uses: control-toolbox/CTActions/.github/workflows/ci.yml@main
    with:
      runs_on: '["ubuntu-latest", "macos-latest", "windows-latest"]'
      runner_type: 'github'
      use_ct_registry: true
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}
```

On a pull request, `CI.yml` is started by the package's `Labels.yml`
([label-dispatch](label-dispatch.md#in-a-package)): one run per `run ci …` label, with
`target` saying which. A caller still on `pull_request` with a label guard works too (the
older model, see [Labels](../conventions/labels.md)); `label-dispatch.yml` is the one to
use in a new or migrated package.
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
| `upload_artifact_path` | `''` | Optional file or directory uploaded after the test, including on failure |
| `upload_artifact_name` | `''` | Optional artifact base name; Julia version and the runner labels are appended as `<name>-<julia version>-<runs_on>` |
| `upload_artifact_if_no_files` | `warn` | `warn`, `error`, or `ignore` when the path is absent |
| `upload_artifact_retention_days` | `''` | Optional retention in days; empty keeps the repository default |
| `upload_artifact_include_hidden_files` | `false` | Include files whose names begin with `.` |
| `fail_fast` | `true` | `strategy.fail-fast` of the matrix: `false` keeps the other platforms running after a failure (e.g. to collect one report per platform) |

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
- **Stable release pull requests run without `ct-registry`:** on a `pull_request` whose
  `Project.toml` sets a stable version other than the base's (`release.jl stable-release`),
  the `add-ct-registry` action adds nothing, so the tests see what General serves (`REL4`).
  Its input `skip_on_stable: 'false'` keeps the registry; [Breakage](breakage.md) sets it,
  since the dependents may need betas of their own. When the base `Project.toml` cannot be
  read, the registry is added as usual.
- **Optional test artifacts:** when both upload inputs are non-empty, the requested path
  is uploaded with `actions/upload-artifact@v4` after the test step, with the matrix Julia
  version and sanitized runner labels appended to the artifact name as
  `<name>-<julia version>-<runs_on>`. The path may contain several newline-separated
  paths. The upload runs even when tests fail; a missing path warns by default (or
  errors/ignores according to `upload_artifact_if_no_files`). Hidden files are excluded
  unless `upload_artifact_include_hidden_files` is true. On a self-hosted retry, the
  artifact contains the files left by the last test attempt. Setting only one of
  `upload_artifact_path` and `upload_artifact_name` produces a warning.

## Split CI

A package with GPU-relevant code adds one job per self-hosted runner, each with its own
label (see [Runners](../conventions/runners.md#split-ci)):

```yaml
  test-gpu-occidata:
    if: inputs.target == 'occidata'          # `run ci occidata-runner`, through Labels.yml
    uses: control-toolbox/CTActions/.github/workflows/ci.yml@main
    with:
      runs_on: '[["occidata"]]'
      runner_type: 'self-hosted'
      use_ct_registry: true
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}
```

A `kkt` job is the same with `kkt` (`inputs.target == 'kkt'`, label `run ci kkt-runner`).

On a pull request each GPU job runs on its label. On a push (`main`, tags) a single job
picks the runner at run time, `kkt` unless it is offline, else `occidata`
([`ci-gpu.yml`](ci-gpu.md)):

```yaml
  test-gpu-main:
    if: github.event_name == 'push'
    uses: control-toolbox/CTActions/.github/workflows/ci-gpu.yml@main
    with:
      use_ct_registry: true
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}
      CT_RUNNERS_CLIENT_ID: ${{ secrets.CT_RUNNERS_CLIENT_ID }}
      CT_RUNNERS_PRIVATE_KEY: ${{ secrets.CT_RUNNERS_PRIVATE_KEY }}
```

A caller still on `pull_request` guards the GPU jobs on their label
(`github.event_name == 'pull_request' && …`, see [Labels](../conventions/labels.md#the-guard))
and `test-gpu-main` on `github.event_name != 'pull_request'`. CTFlows.jl also calls
`ci.yml` from `CITargeted.yml` (a subset of the tests on a chosen runner, by hand) and
`CronIntegration.yml` (weekly slow tests, `test_args: 'cron'`): see
[Workflows defined in a package](per-repo.md).

## Superseded runs

On a pull request, a new run cancels the previous one of the same workflow and pull request;
nothing is cancelled on `main` or on a tag. See [Superseded runs](superseded-runs.md).

## On a push to `main`: the label `ci on main: changes only`

The first job, `changes`, decides whether the jobs of this workflow run on a push to `main`.
Without the label `ci on main: changes only` on the merged pull request they always run;
with it, they run only if a changed file can affect them. The input `ctactions_ref`
(default `main`) is the ref of CTActions whose scripts `changes` runs, to test a change. See
[CI on `main`](ci-on-main.md).
