# Which repository has which workflow

[← Workflows of control-toolbox](README.md)

Measured on 2026-10-16 (`gh api repos/control-toolbox/<repo>/contents/.github/workflows`).
The base set is CI, Coverage, Documentation, Formatter, SpellCheck, CompatHelper,
UpdateReadme and TagBot, in every repository below; the columns are what varies.

| Repository | DocPreviewCleanup | AutoAssign | AddToProject | Breakage | Extra |
| --- | :---: | :---: | :---: | :---: | --- |
| CTAppTemplate.jl | — | — | — | ✅ | `setup-repo` |
| CTBase.jl | ✅ | ✅ | ✅ | ✅ | — |
| CTModels.jl | ✅ | ✅ | ✅ | ✅ | — |
| CTParser.jl | — | ✅ | ✅ | ✅ | split CI |
| CTFlows.jl | ✅ | ✅ | ✅ | ✅ | split CI (three ways), `CPUProbe`/`GPUProbe`, `CITargeted`, `CronIntegration` |
| CTDirect.jl | ✅ | ✅ | ✅ | ✅ | split CI; `Formatter.yml.disabled` |
| CTSolvers.jl | ✅ | ✅ | ✅ | ✅ | split CI (three ways), `CPUProbe`/`GPUProbe`; documentation GPU pass on `kkt` |
| CTLie.jl | ✅ | ✅ | — | ✅ (vs. OptimalControl) | split CI |
| OptimalControl.jl | ✅ | ✅ | ✅ | ✅ (packages and applications) | split CI, `JOSS`; documentation GPU pass on `occidata` |
| OptimalControlProblems.jl | — | ✅ | ✅ | — | — |
| CTDiffFlow.jl | — | ✅ | — | — | — |
| CTBenchmarks.jl | — | ✅ | ✅ | — | `benchmark-*` |

Split CI and the GPU passes: see [Runners](conventions/runners.md#split-ci). CTActions
itself runs the organization's workflows (the prune, the `occidata` runner): see the
[catalog](README.md#workflows-that-run-in-ctactions).

## Why

**Breakage only where there are downstream consumers.** It answers *"if I change this
package, do its consumers still pass?"*, so it makes sense only for a package depended on
inside the ecosystem: CTBase tests every package above it, OptimalControl its applications
and tutorials, a leaf repository (CTDiffFlow, CTBenchmarks, OptimalControlProblems) has
nothing to break. See [breakage.yml](workflows/breakage.md). The template ships a
`Breakage.yml` to fill in or delete.

**AddToProject only for repositories tracked on the board** (the core packages); not for
peripheral repositories or the template.

**DocPreviewCleanup goes with PR previews**: every package that deploys them should have
it ([documentation.yml](workflows/documentation.md#pr-previews)). CTParser.jl,
OptimalControlProblems.jl, CTDiffFlow.jl, CTBenchmarks.jl and the template do not have it
yet.

**Formatter is disabled in CTDirect.jl** (`Formatter.yml.disabled`): GitHub ignores the
file, which stays on disk; rename it back to re-enable.

**The template's CI has no label gate**: `CTAppTemplate.jl/CI.yml` calls `ci.yml` with no
`if:` and minimal inputs; a real package then gates it with `run ci github-runner` and
richer inputs.
