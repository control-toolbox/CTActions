# `release-gate.yml`: the gate of a release pull request

[← Workflows of control-toolbox](../README.md)

Checks a release PR against the release rules of ct-conventions,
[`REL1`–`REL7`](https://github.com/control-toolbox/ct-conventions/blob/main/rules/release.md).
Caller: `ReleaseGate.yml`, in every package. Its result is one of the conditions that
`release.jl ready` checks before a release PR is merged (see [The merge](#the-merge)).

A PR that does not change the `version` of `Project.toml` is not a release: the job passes
at once, saying so, with the format problems of `[Unreleased]` as information (ℹ️ `CHG2`,
`release.jl lint-changelog`): a changelog written out of format is said in the PR that
writes it, not at the release. Cheap and GitHub-hosted: no label.

## What it checks

| Rule | Check |
| --- | --- |
| `REL6` | on **every** PR, a release or not: the registration bot is mentioned neither in the PR's title or description nor in a commit message |
| — | name and uuid unchanged |
| `REL2` | the suffix is none or `-beta`; the triple is above every version in General, ct-registry and the tags |
| `REL5` | the tag `vX.Y.Z` does not exist yet |
| `REL1` | the bump is breaking exactly when the changelog since the reference (the last stable for a stable, the last release for a beta) has a `💥 Breaking Changes` section; the version is the one REL1 and REL2 give |
| `REL3` | for a stable, a jump in General is explained by betas (then reported: `[merge approved]` will be needed), else fails. `status` reads the same jump from the registries and mentions `[merge approved]` on General's PR only then |
| `CHG2` | the entry `## [X.Y.Z] - YYYY-MM-DD` is the first one, under an empty `[Unreleased]`, with its `✅ Compatibility` subsection |
| `CHG3`, `CHG4` | `BREAKING.md` has a `##` entry naming the version |
| — | the PR changes `Project.toml`, `CHANGELOG.md`, `BREAKING.md` only, and only the version in `Project.toml` |
| — | the release files hold no replacement character (U+FFFD) and are valid UTF-8: a broken encoding, which an editing tool can leave in a heading, fails |
| `REL7` | since the tag of the reference, something reaches a user: `src/`, `ext/`, `docs/`, or `Project.toml` beyond the version |
| — | the PR has every run label of the package's workflows (one GPU label is enough: `kkt` or `occidata`; `run probe` is not needed): a label-gated job without its label is *skipped*, and a skipped job reports success. In the workflow this line is ℹ️, never ❌: the gate runs once per label added, so its first runs see some labels only; `release.jl ready` requires every gated job to have run. Locally (`--labels` without `--labels-info`) a missing label fails |
| — | for a package with a `Documentation.yml`, the label `documentation push preview` is on the PR; ℹ️ when it is not (the workflows do not require it, but without it no preview is deployed) |
| `REL4` | a stable resolves from General alone, weak dependencies included, on the lowest Julia (`julia_lowest`) and the newest |

The packages' CI uses ct-registry (`use_ct_registry: true`), but not on a pull request that
sets a stable version: the `add-ct-registry` action skips it there (see
[`ci.md`](ci.md#what-it-does)), so the CI and the gate fail for the same reason. The gate stays
the one that says which bound fails; it runs with General only.

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

`labeled` and `unlabeled` are in the `types`: adding a label reruns the gate, which reads the labels of that event.

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `julia_lowest` | `'1.10'` | The lowest Julia version REL4 resolves on |
| `ctactions_ref` | `'main'` | Ref of CTActions the script is checked out from |

## The merge

A release PR is merged by `release.jl merge` (or by a human after `release.jl ready`),
never by GitHub's auto-merge on the strength of check names. A label-gated workflow runs
once per label added; a run whose jobs are all skipped — the label added was another one —
reports *success*, and GitHub shows the latest result of a check name: a check can look
green while the real tests failed or still run.

`ready` reads what actually ran on the head commit of the PR (the Actions runs and their
jobs, not the checks). The runs of the PR's own events (`pull_request`) count, and so do the
ones [label-dispatch.yml](label-dispatch.md) dispatched on its branch (`workflow_dispatch`:
the list of runs does not say which PR they belong to, the branch does). A package's guard
is read from its callers, `contains(… .labels.*.name, '<label>')` or `inputs.target ==
'<target>'`; the documentation workflow, which has no guard, is the one that takes the
dispatch input `preview` (`run documentation`). For each workflow, the **latest run that executed jobs** counts; it
must be complete, every job in it passed or was skipped, and every job gated by a label
the release needs ran and passed (of the GPU jobs, the one of the GPU label on the PR:
`kkt`, else `occidata`). The release gate must have run and passed; the PR must be open,
not a draft, up to date with `main`, without conflict. A run in progress means *wait*.

`merge` runs `ready` again and merges with `--match-head-commit`: GitHub refuses if the head
of the PR changed between the check and the merge. It merges `release/v…` branches only,
and only with `--confirm`.

## The release tool

The gate is one command of `scripts/release/release.jl`, which the agent, a person and the
workflows call the same way. Every command, its options and its exit codes:
[the release CLI](../tools/release-cli.md).

## Tests

`scripts/release/test/runtests.jl`: unit tests on fakes (the registries, a GitHub whose
state follows the comments posted) and on throwaway git repositories (a package released,
changed, then a release branch: every failure of the gate is produced and caught); a
property test, 2000 random histories of stables and betas, each number checked against
`REL1`–`REL3`; integration tests against the local General. Mutating a rule (the fresh
triple of `REL2`, the guard of `register`) makes them fail.
`release-tests.yml` runs them on Julia 1.10, 1.12 and 1.13 whenever the scripts or the
release workflows change. The tool calls internals of Pkg
(`Pkg.Operations.resolve_versions!`, `Pkg.Registry.registry_info`, whose signature changed
in 1.13): the matrix guards them.
