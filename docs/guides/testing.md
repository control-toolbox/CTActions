# Testing a package: CI, GPU, coverage

[← Workflows of control-toolbox](../README.md)

For a developer of a control-toolbox package: where the tests run, how to ask for the GPU,
what happens on `main`, and what to do when a self-hosted run misbehaves. How to start a
check on a pull request (labels, statuses) is in
[the pull-request guide](pull-requests.md); why the runners are used this way is in
[design: tests and runners](../design/testing-runners.md).

## Where the tests run

| Runner | What it is | Asked on a PR by | On `main` and tags |
| --- | --- | --- | --- |
| GitHub-hosted: Linux, macOS (Apple Silicon), Windows | a fresh machine per job | `run ci github-runner` | always |
| `kkt` | self-hosted, CUDA, the faster GPU | `run ci kkt-runner` | the GPU job, unless `kkt` is offline |
| `occidata` | self-hosted on a SLURM cluster, a GPU node taken per step | `run ci occidata-runner` | the GPU job when `kkt` is offline |

Julia versions: `1.10` (the lowest supported), `1.12`, `1.13` by default on GitHub's
runners; the newest `1` on the GPU job. A package without GPU-relevant code (CTBase,
CTModels) has the GitHub-hosted job only.

**Coverage** runs on `main` and tags only (Linux, one Julia), uploaded to Codecov: there is
nothing to ask for on a pull request.

## What a run does

- **GitHub-hosted**: cache, build, `Pkg.test`. Nothing survives the job.
- **Self-hosted**: the Julia depot persists between jobs and branches, so the run caches
  `artifacts/` and `compiled/`, moves `TMPDIR` off the node's `/tmp`, and, if the tests
  fail, **purges `compiled/` and runs them once more**: a stale precompiled cache is the
  most common cause of a failure that is not yours.
- On `occidata`, the test step runs through `$OCCIDATA_GPU_RUN`: the step waits for a GPU
  node of the cluster, then runs there. A test suite may rely on it: `RUNNER_NAME` contains
  `occidata` ⇒ `CUDA.functional()` holds.
- **`ct-registry`** (betas of the ecosystem) is added when the caller asks
  (`use_ct_registry: true`), except on a pull request that sets a **stable** version: a
  release must resolve from General alone (`REL4`).
- **CompatHelper and Dependabot** pull requests are tested with the newest versions their
  bounds allow (not on Julia 1.10, whose resolver would pick versions that need a newer
  Julia).

## Reading a failure

| What you see | Likely cause | What to do |
| --- | --- | --- |
| Fails on GitHub's runners | your change, or a new release of a dependency | reproduce locally; compare with the last green run on `main` |
| Fails on `occidata` or `kkt` only, in precompilation | a stale depot; already retried once | re-run; if it persists, tell the maintainer of the runners (the weekly maintenance purges the cache) |
| `occidata` run waits a long time before the tests | waiting for a GPU node of the cluster | nothing: it is the queue of the cluster |
| First `occidata` run after Monday 02:30 UTC is slow | the weekly maintenance purged the caches | nothing |
| A job failed around `HH:01` on `occidata` | the node wipes its `/tmp` every hour | re-run; a long custom job must use `$RUNNER_TEMP` |
| Fails on Windows only, about paths or the registry | backslashes in paths; the SSH agent of Windows | see [ci.md](../workflows/ci.md#what-it-does); CTBase carries a Windows smoke test of its test selection |
| The GPU job on `main` ran on `occidata` | `kkt` was offline, or the `CT_RUNNERS_*` secrets were missing (warning in the `select` job) | nothing, unless it is always so |

## Setting up a package

1. `CI.yml` calling [`ci.yml`](../workflows/ci.md#caller): one job for GitHub's runners,
   and, with GPU-relevant code, one per self-hosted runner plus `test-gpu-main` on
   [`ci-gpu.yml`](../workflows/ci-gpu.md) ([Split CI](../workflows/ci.md#split-ci)).
2. Pass `SSH_KEY` when `use_ct_registry: true`, and `CT_RUNNERS_*` to `ci-gpu.yml`. These
   are organization secrets: nothing to create.
3. `Coverage.yml` calling [`coverage.yml`](../workflows/coverage.md), with `CODECOV_TOKEN`.
4. The labels and `Labels.yml`: [the pull-request guide](pull-requests.md#setting-up-a-package).
5. A workflow of your own that needs the GPU on `occidata` prefixes its command with
   `${OCCIDATA_GPU_RUN:-}` ([Runners](../conventions/runners.md#occidata-a-gpu-on-demand)).

Useful inputs of `ci.yml`: `test_args` (forwarded to `Pkg.test`: a group, file globs,
`cron`), `fail_fast: false` (keep the other platforms running after a failure), the
`upload_artifact_*` inputs (a report uploaded even when the tests fail). All in
[ci.md](../workflows/ci.md#inputs-and-secrets).

## Beyond the CI

- **Slow tests**: a weekly workflow of the package with `test_args: 'cron'`, calling
  `ci.yml` and `ci-gpu.yml` (CTFlows.jl's `CronIntegration.yml`).
- **A subset on one runner, by hand**: CTFlows.jl's `CITargeted.yml`.
- **What works, rather than what is correct**: a probe, not a test
  ([probes](../workflows/per-repo.md#probes)).

## The pages behind it

| Subject | Page |
| --- | --- |
| The test workflow, its inputs, split CI | [`ci.yml`](../workflows/ci.md) |
| The GPU job of `main` | [`ci-gpu.yml`](../workflows/ci-gpu.md), [`select-gpu-runner.yml`](../workflows/select-gpu-runner.md) |
| Coverage | [`coverage.yml`](../workflows/coverage.md) |
| The runners, `occidata`'s GPU on demand | [Runners](../conventions/runners.md) |
| Their maintenance | [maintenance](../workflows/occidata-runner-maintenance.md), [watchdog](../workflows/occidata-runner-watchdog.md) |
| `ct-registry`, the secrets, forks | [Secrets and registries](../conventions/secrets.md) |
| Why it is built this way | [design: tests and runners](../design/testing-runners.md) |
