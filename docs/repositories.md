# Which repository has which workflow

[← Workflows of control-toolbox](README.md)

Measured on 2026-10-19 (`gh api repos/control-toolbox/<repo>/contents/.github/workflows`).
The base set is CI, Coverage, Documentation, Formatter, SpellCheck, CompatHelper,
UpdateReadme and TagBot, in every repository below; the columns are what varies.

| Repository | DocPreviewCleanup | AutoAssign | AddToProject | Breakage | ReleaseGate, ReleaseTag | Extra |
| --- | :---: | :---: | :---: | :---: | :---: | --- |
| CTAppTemplate.jl | — | — | — | ✅ | — | `setup-repo` |
| CTBase.jl | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| CTModels.jl | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| CTParser.jl | — | ✅ | ✅ | ✅ | ✅ | split CI |
| CTFlows.jl | ✅ | ✅ | ✅ | ✅ | ✅ | split CI (three ways), `CPUProbe`/`GPUProbe`, `CITargeted`, `CronIntegration` |
| CTDirect.jl | ✅ | ✅ | ✅ | ✅ | ✅ | split CI; `Formatter.yml.disabled` |
| CTSolvers.jl | ✅ | ✅ | ✅ | ✅ | ✅ | split CI (three ways), `CPUProbe`/`GPUProbe`; documentation GPU pass on `kkt` |
| CTLie.jl | ✅ | ✅ | — | ✅ (vs. OptimalControl) | ✅ | split CI |
| OptimalControl.jl | ✅ | ✅ | ✅ | ✅ (packages and applications) | ✅ | split CI, `JOSS`; documentation GPU pass on `occidata` |
| OptimalControlProblems.jl | — | ✅ | ✅ | — | — | — |
| CTDiffFlow.jl | — | ✅ | — | — | — | — |
| CTBenchmarks.jl | — | ✅ | ✅ | — | — | `benchmark-*` |

Split CI and the GPU passes: see [Runners](conventions/runners.md#split-ci). CTActions
itself runs the organization's workflows (the prune, the `occidata` runner): see the
[catalog](README.md#workflows-that-run-in-ctactions).

## Why

**Breakage only where there are downstream consumers.** It answers *"if I change this
package, do its consumers still pass?"*, so it makes sense only for a package depended on
inside the ecosystem. The consumers are not listed in the package: the suite derives them
from the `Project.toml` files of the organization (CTBase is tested against every package
that loads it, OptimalControl against OptimalControlProblems and, declared, its tutorials
and applications), see [breakage-suite.yml](workflows/breakage-suite.md#which-packages-are-tested).
A repository nobody loads (CTDiffFlow, CTBenchmarks) has nothing to break. The template
ships a `Breakage.yml` to fill in or delete.

**ReleaseGate and ReleaseTag in the packages that are released with the
[release recipe](https://github.com/control-toolbox/ct-agents/blob/main/recipes/release.md)**
(the eight core packages): the gate of a release PR (`REL1`–`REL7`) and the tag and GitHub
release of a merged one ([release-gate.yml](workflows/release-gate.md),
[release-tag.yml](workflows/release-tag.md)). Their `Documentation.yml` accepts
`workflow_dispatch`, so that the release can build the docs of the tag it creates.

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
