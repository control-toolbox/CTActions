# Workflows defined in a package

[← Workflows of control-toolbox](../README.md)

A few workflows hold their own logic in a package instead of calling CTActions: an
upstream action with nothing to factor out, a one-shot bootstrap, or experiments specific
to one package.

| Workflow | Where | Why it is not centralized |
| --- | --- | --- |
| `TagBot.yml` | every package | Thin wrapper over `JuliaRegistries/TagBot@v1`, an upstream action: nothing to factor. Triggered by an `issue_comment` from `JuliaTagBot` (registration) or `workflow_dispatch`; uses `GITHUB_TOKEN` and `DOCUMENTER_KEY` (`ssh:`) |
| `setup-repo.yml` | CTAppTemplate.jl only | One-shot bootstrap: renames the package, regenerates the UUID, sets authors and assignees, opens a setup PR. Meaningful only on a fresh copy of the template |
| `JOSS.yml` | OptimalControl.jl only | Compiles the JOSS paper under `joss/` |
| `CPUProbe.yml`, `GPUProbe.yml` | CTFlows.jl, CTSolvers.jl | Capability probes, see [below](#probes) |
| `CITargeted.yml` | CTFlows.jl | By hand: a subset of the tests (`tests`: file globs) on a chosen self-hosted runner (`kkt` or `occidata`), to iterate on one failing file. Calls `ci.yml` with `test_args` |
| `CronIntegration.yml` | CTFlows.jl | Weekly (Monday 03:00 UTC): the slow end-to-end tests excluded from regular CI (`test_args: 'cron'`), on GitHub-hosted runners and `occidata`; opens an issue on failure. Calls `ci.yml` |
| `benchmark-reusable.yml`, `benchmarks-orchestrator.yml` | CTBenchmarks.jl only | Benchmark orchestration specific to that repository |

`CTDirect.jl`'s former `GPU.yml` (label `run GPU`) predates the split CI and has been
replaced by it ([Runners](../conventions/runners.md#split-ci)).

## Probes

A package whose documentation states what works (which solver accepts which model, what
runs on a GPU) backs those statements with a **probe** rather than with tests, which would
fail the CI for what is a capability, not a bug. A probe always succeeds and prints a
capability matrix; it is diagnostic only and gates nothing. Same layout in every package:

| Path | Content |
| --- | --- |
| `probe/common.jl` | Helpers: a cell runs one experiment in `try/catch`, records warnings, and is marked ✓ (works and correct), ⚠ (runs, but wrong, not converged, or warned) or ✗ (throws); a matrix printer |
| `probe/cpu/probe_cpu.jl`, `probe/cpu/Project.toml` | CPU experiments; the script activates its folder and `dev`s the repository, so it measures the working tree |
| `probe/gpu/probe_gpu.jl`, `probe/gpu/Project.toml` | Device experiments; without a functional device every cell reports the error it really raises |
| `probe/README.md` | How to run, and the latest known results with their date and machine |
| `.github/workflows/CPUProbe.yml`, `GPUProbe.yml` | `ubuntu-latest` and a self-hosted GPU runner; label `run probe` or `workflow_dispatch` |

Judge a numerical result against a well-conditioned problem with an analytic solution:
solvers stop at a tolerance and may relax bounds by about that tolerance, so on a badly
conditioned problem a correct solve can look wrong (CTSolvers, MadNLP on GPU). On
`occidata`, the GPU step needs the `$OCCIDATA_GPU_RUN` prefix
([Runners](../conventions/runners.md#occidata-a-gpu-on-demand)).
