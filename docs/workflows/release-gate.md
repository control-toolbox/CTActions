# `release-gate.yml`: the gate of a release pull request

[← Workflows of control-toolbox](../README.md)

Checks a release PR against the release rules of ct-conventions,
[`REL1`–`REL7`](https://github.com/control-toolbox/ct-conventions/blob/main/rules/release.md).
Caller: `ReleaseGate.yml`, in every package. With the job a **required check** of `main`
and auto-merge on, no release PR is merged — by an agent or a human — while a rule fails.

A PR that does not change the `version` of `Project.toml` is not a release: the job passes
at once, saying so. Cheap and GitHub-hosted: no label.

## What it checks

| Rule | Check |
| --- | --- |
| — | name and uuid unchanged |
| `REL2` | the suffix is none or `-beta`; the triple is above every version in General, ct-registry and the tags |
| `REL5` | the tag `vX.Y.Z` does not exist yet |
| `REL1` | the bump is breaking exactly when the changelog since the reference (the last stable for a stable, the last release for a beta) has a `💥 Breaking Changes` section; the version is the one REL1 and REL2 give |
| `REL3` | for a stable, a jump in General is explained by betas (then reported: `[merge approved]` will be needed), else fails |
| `CHG2` | the entry `## [X.Y.Z] - YYYY-MM-DD` is the first one, under an empty `[Unreleased]`, with its `✅ Compatibility` subsection |
| `CHG3`, `CHG4` | `BREAKING.md` has a `##` entry naming the version |
| — | the PR changes `Project.toml`, `CHANGELOG.md`, `BREAKING.md` only, and only the version in `Project.toml` |
| `REL7` | since the tag of the reference, something reaches a user: `src/`, `ext/`, `docs/`, or `Project.toml` beyond the version |
| — | the PR has every run label of the package's workflows (one GPU label is enough: `kkt` or `occidata`; `run probe` is not needed): a label-gated job without its label is *skipped*, and a skipped job passes a required check |
| `REL4` | a stable resolves from General alone, weak dependencies included, on the lowest Julia (`julia_lowest`) and the newest |

The packages' CI uses ct-registry (`use_ct_registry: true`), so it passes with a bound
that only a beta satisfies; the gate runs with General only.

## Caller

```yaml
# .github/workflows/ReleaseGate.yml
name: Release gate

on:
  pull_request:
    types: [opened, synchronize, reopened, labeled, unlabeled, edited]

jobs:
  call:
    uses: control-toolbox/CTActions/.github/workflows/release-gate.yml@main
```

`labeled` and `unlabeled` are in the `types`: adding the missing label reruns the gate.
The required check is `call / gate`, with the others of
[Required checks](../conventions/required-checks.md).

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `julia_lowest` | `'1.10'` | The lowest Julia version REL4 resolves on |
| `ctactions_ref` | `'main'` | Ref of CTActions the script is checked out from |

## The release tool

The gate is one command of `scripts/release/release.jl`, which the agent, a human and the
workflows call the same way:

```bash
julia scripts/release/release.jl status --repo control-toolbox/CTBase.jl [--version 0.30.12]
julia scripts/release/release.jl gate --base <base sha> --labels "run breakage,run ci github-runner" <clone>
julia scripts/release/release.jl registrable [--base base/Project.toml] Project.toml
julia scripts/release/release.jl tag-plan <clone>
```

- **`status`** says where a release stands, from the facts only — the tracking issue and
  its registration mentions, the release PR and its merge commit, the tag and its tree,
  the GitHub release, General's PR, the registries — and gives the phase of the
  [release recipe](https://github.com/control-toolbox/ct-agents/blob/main/recipes/release.md),
  the next action and what blocks it. A session that stopped, a remote run or a human all
  resume from the same answer; nothing is remembered. It refuses what would break the
  release: a tag on another commit than the merge, a registration comment already posted
  with no General PR (never post it twice, `REL6`), `main` moved past the merge commit
  before the registration, a registered tree that is not the tag's.
- **`gate`** is the table above.
- **`registrable`** is `REL4` alone, also on a developer's machine: the other registries of
  the depot are ignored, and the report names the betas that satisfy a bound General
  cannot.
- **`tag-plan`** is what [`release-tag.yml`](release-tag.md) tags.

Exit codes: 0 ready or nothing to do, 1 blocked, 2 usage error. Reports in Markdown, on
standard output and in the job summary.

## Tests

`scripts/release/test/runtests.jl`: unit tests on fakes (the registries, `gh`) and on
throwaway git repositories (a package released, changed, then a release branch: every
failure of the gate is produced and caught), integration tests against the local General.
`release-tests.yml` runs them on Julia 1.10, 1.12 and 1.13 whenever the scripts or the
release workflows change. The tool calls internals of Pkg
(`Pkg.Operations.resolve_versions!`, `Pkg.Registry.registry_info`, whose signature changed
in 1.13): the matrix guards them.
