# Runners

[← Workflows of control-toolbox](../README.md)

## GitHub-hosted and self-hosted

`ci.yml` takes `runner_type: github | self-hosted` and a `runs_on` JSON array (a label
per matrix entry, or a list of labels for a self-hosted runner, e.g. `'[["occidata"]]'`).
The two kinds differ in what they keep between jobs:

| | GitHub-hosted | Self-hosted |
| --- | --- | --- |
| Disk | fresh for every job | persistent depot, shared by every job and branch |
| Cache | `julia-actions/cache` | `actions/cache` of `artifacts/` and `compiled/`, at the depot Julia reports (`Base.DEPOT_PATH[1]`) |
| Stale precompiled code | impossible | possible: the tests are retried once after purging `compiled/` |
| `/tmp` | private | may be wiped by the node (`occidata`: every hour at `HH:01`), so `TMPDIR` is moved under `$RUNNER_TEMP` |

The self-hosted runners are visible to every repository through the organization's
`Default` runner group (`gh api orgs/control-toolbox/actions/runners`).

## The runners

| Runner | Labels | GPU | Used by (2026-10-16) |
| --- | --- | --- | --- |
| GitHub-hosted | `ubuntu-latest`, `macos-latest`, `windows-latest` | — | everything |
| `occidata` | `self-hosted, gpu, occidata` | CUDA, on demand (see below) | CI of OptimalControl, CTParser, CTDirect, CTFlows, CTSolvers, CTLie (`run ci occidata-runner`); OptimalControl's documentation GPU pass |
| `kkt` | `self-hosted, Linux, X64, gpu, cuda, kkt` | CUDA, faster than `occidata` | CI of CTFlows, CTSolvers (`run ci kkt-runner`); CTSolvers' documentation GPU pass and GPU probe |
| `pinwheel` | `self-hosted, Linux, X64, gpu, amdgpu, pinwheel` | **AMD** | nothing |

**`kkt` is back in service.** It was missing from the runner list on 2026-09-02 and
considered retired; it is registered and online again since 2026-10-15.

**`pinwheel` is AMD, not CUDA.** It is no candidate for the `:gpu` CI of this ecosystem,
whose GPU stack (`ExaModels` → `MadNLPGPU` → `CUDSS`) is CUDA-only. Recorded here so that
nobody points a CUDA job at it by accident; it deserves its own maintenance workflow once
something targets it.

## `occidata`: a GPU on demand

The `occidata` runner (a SLURM cluster at IRIT) has **no GPU of its own**. Since
2026-09-28 it idles in a CPU allocation (`24CPUNodes`) instead of holding a GTX 1080 Ti for
7 days. A step that needs CUDA prefixes its command with `$OCCIDATA_GPU_RUN`, exported by
the runner (control-toolbox/occidata, `scripts/slurm_gpu_run.sh`). The script submits the
command to `GPUNodes` with `sbatch --wait` for the step's duration only: it keeps the
step's environment (`RUNNER_NAME` included), streams its output, propagates its exit
status, and cancels the SLURM job when the workflow is cancelled.

```yaml
- run: ${OCCIDATA_GPU_RUN:-} julia --project=... script.jl   # plain `julia ...` on any other runner
```

`ci.yml` (self-hosted test step) and `documentation.yml` (`build-gpu`) already do this
(CTActions#79), so their callers need nothing. **A workflow with its own steps must add
the prefix itself** (as CTFlows.jl's `GPUProbe.yml` does): without it the step runs on the
CPU node, and the test suites' contract "`RUNNER_NAME` contains `occidata` ⇒
`CUDA.functional()` is required" fails. Resources can be tuned per step with
`OCCIDATA_GPU_PARTITION`, `OCCIDATA_GPU_GRES`, `OCCIDATA_GPU_CPUS`, `OCCIDATA_GPU_MEM` and
`OCCIDATA_GPU_TIME` (a bare number is minutes). The runner's `gpu` label therefore means
"can get a GPU", not "runs on one". Precompilation happens inside the prefixed command,
that is, while the GPU is held.

Two quirks of the node, for any role:

- its `/tmp` is wiped every hour at `HH:01`: `ci.yml` and `documentation.yml` move
  `TMPDIR` under `$RUNNER_TEMP` (commit 2f00b67), and any long job needs the same;
- the weekly [maintenance](../workflows/occidata-runner-maintenance.md) (Monday 02:30
  UTC) purges the compiled-code cache, so the first job after it runs cold.

A job landing right after either is slower or needs a retry; the runner is not unhealthy.
Its runner jobs are restarted by the daily
[watchdog](../workflows/occidata-runner-watchdog.md).

Occidata also hosts a second runner instance, `occidata-cpu`, for the `ocourses`
organization, in `cpu` mode (no `$OCCIDATA_GPU_RUN`, never a GPU). Instances, their modes
and how to add one: control-toolbox/occidata, `docs/gha-runner-config.md` § 9.

## Choosing between `kkt` and `occidata`

On a PR, the labels choose (`run ci kkt-runner`, `run ci occidata-runner`): either
runner can always be asked for. On a push to `main` or a tag, one GPU job runs:
[`ci-gpu.yml`](../workflows/ci-gpu.md) takes `kkt` unless it is *offline*, else `occidata`;
a busy `kkt` is waited for. The documentation's GPU pass does the same with
`gpu_runner: 'auto'`. Both read the runner state with the organization secret
`RUNNERS_STATUS_TOKEN` ([details](../workflows/select-gpu-runner.md)).

## Split CI

A package with GPU-relevant code calls `ci.yml` several times from its `CI.yml`, one job
per runner, each gated by its own label:

| Job | `runs_on` | `runner_type` | Label |
| --- | --- | --- | --- |
| GitHub-hosted | `'["ubuntu-latest", "macos-latest", "windows-latest"]'` | `github` | `run ci github-runner` |
| `occidata` | `'[["occidata"]]'` | `self-hosted` | `run ci occidata-runner` |
| `kkt` (optional) | `'[["kkt"]]'` | `self-hosted` | `run ci kkt-runner` |

As of 2026-10-16: OptimalControl, CTParser, CTDirect and CTLie split two ways
(GitHub-hosted, `occidata`; CTParser's `main` still targets `kkt` with stale labels,
fixed by CTParser.jl#326); CTFlows and CTSolvers three ways (plus `kkt`). CTBase and CTModels, with no GPU-relevant code, have a single GitHub-hosted job.
The full caller is in [ci.yml](../workflows/ci.md#split-ci).

**Documentation can use a GPU too, but shaped differently:** publish on GitHub-hosted
first, then upgrade on the GPU runner, never "attempt GPU, fall back to CPU". See
[documentation.yml](../workflows/documentation.md#gpu-upgrade-pass).
