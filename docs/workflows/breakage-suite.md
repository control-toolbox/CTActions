# `breakage-suite.yml`: test the downstream packages, report once

[← Workflows of control-toolbox](../README.md)

Tests the packages that depend on this one against it, and reports **once**: one table in
the job summary, one PR comment per group kept up to date, one artifact. Caller:
`Breakage.yml`. Replaces `breakage.yml` (removed, CTActions#162); why, in
[design: breakage](../design/breakage.md).

## What it does

- **`plan`**, once: the targets of the suite. They are **derived** by
  [`scripts/breakage/consumers.jl`](../../scripts/breakage/consumers.jl), not listed in the
  caller: every package of the organization that loads the package under test, read from
  the `Project.toml` files (see [Which packages are tested](#which-packages-are-tested)),
  plus the `targets` the caller declares. The table of targets, with where each comes from,
  is in the job summary. The job fails, and nothing else runs, when the organization cannot
  be read. When there is nothing to test (no consumer, no declared target), the list is
  empty: no cell runs, the report says so and the suite passes, so that a package keeps its
  `Breakage.yml` while it has no consumer.
- **`break`**, one job per cell: a downstream package × `latest` (its default branch) or
  `stable` (its newest tag, a beta included). The cell runs the package's tests (`test`)
  or builds its docs (`doc`) with the package under test `dev`ed, and writes its result
  (status, tested ref, the version of this package it resolved) as a file. A failure does
  not fail the job.
- **`report`**, once: gathers the cells in a table, writes `breakage.toml` (artifact
  `breakage-<group>`) and the summary, and comments on the PR, updating its own comment
  (found by the marker `<!-- ct-breakage:<group> -->`).

**On a release PR** (the `version` of `Project.toml` changes), the report checks
[`REL1`](https://github.com/control-toolbox/ct-conventions/blob/main/rules/release.md#rel1--version-numbers-follow-semver-as-pkg-reads-it):
it takes the `breakage-<group>` artifact of the run of the same workflow on the **base
commit**, and compares the **stable** column (the last release of each downstream package):

| Stable, base | Stable, PR | Meaning |
| --- | --- | --- |
| ✅ | ❌ | the release breaks this package: the version must be breaking, else the job fails |
| ❌ | ❌ | already broken without the release: reported, says nothing |
| ✅ | ✅ | nothing |

A downstream failure is expected from a breaking change and never fails the job by itself;
an inconsistent number does. A release PR also fails when there is no run on the base
commit to compare with, or when cells have no result: callers therefore run the suite on
push to `main` (the baseline of the next release PR) and by hand.

## Caller

```yaml
# .github/workflows/Breakage.yml
name: Breakage
run-name: "Breakage ${{ inputs.target }}${{ inputs.pr && format(' #{0}', inputs.pr) || '' }}"

on:
  push:
    branches: [main]
  workflow_dispatch:          # by Labels.yml for `run breakage`, or by hand (the baseline)
    inputs:
      pr:     { required: false, default: '' }
      target: { required: false, default: '' }

jobs:
  call:
    if: inputs.pr == '' || inputs.target == 'packages'
    uses: control-toolbox/CTActions/.github/workflows/breakage-suite.yml@main
    with:
      use_ct_registry: true
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}
```

`inputs.pr` is empty on a push and on a run by hand: the suite runs; on a pull request,
[label-dispatch](label-dispatch.md) passes `pr` and `target=packages` (`run breakage`) or
`target=applications` (`run breakage applications`). A caller still on `pull_request` guards
the job on the label `run breakage` ([Labels](../conventions/labels.md#the-guard)).

No list of packages: the consumers are derived. A package with two suites (OptimalControl:
`run breakage` for its packages, `run breakage applications` for the applications) calls it
twice, with two `group`s; the second one declares its `targets` and sets `consumers: false`
(its applications are not packages that load OptimalControl). A heavy suite may leave out
the `push` trigger and be run by hand on `main` before a release.

## Which packages are tested

A package of the organization (a non-archived, non-fork repository `X.jl` whose
`Project.toml` has a `name` and a `uuid`) is a **consumer** of P, by uuid, when P is in:

| Where | Why it counts |
| --- | --- |
| `[deps]` of `Project.toml` | the package loads P |
| `[weakdeps]` of `Project.toml` | an extension loads P |
| `[extras]` of `Project.toml` | its tests (or a test target) load P |
| `[deps]` of `test/Project.toml` | its tests load P |

Left out: P itself, archived repositories, forks, and the repositories listed in `EXCLUDED`
in `consumers.jl`, each with its reason (the template of a new package; a package whose
compat is out of date until it is updated). What the `Project.toml` files do not show is
declared by the caller in `targets`: an application owned outside the organization, a
documentation build (`"break": "doc"`). A declared target replaces the derived one of the
same package, owner and check.

```bash
# what a package would get, from its checkout (needs `gh`, authenticated)
julia scripts/breakage/consumers.jl list --project Project.toml
julia scripts/breakage/consumers.jl plan --project Project.toml --declared '[{"name": "Tutorials", "break": "doc"}]'
```

The `Project.toml` files read are those of the default branch of each package, at the time
of the run: a package that starts to load P is tested from then on, and the report says
`has no result on the base (a new target)` for it on the first release PR.

## Inputs and secrets

| Input | Default | Meaning |
| --- | --- | --- |
| `targets` | `'[]'` | JSON list of declared targets, added to the derived ones: `{"name", "owner", "break"}`, the package without `.jl`, its GitHub owner (default `control-toolbox`), `test` (default) or `doc` |
| `consumers` | `true` | Derive the consumers from the `Project.toml` files; `false` for the declared `targets` only |
| `versions` | `'["latest", "stable"]'` | The versions of each package |
| `group` | `'packages'` | Name of the suite: its comment and its artifact |
| `use_ct_registry` | `false` | Add `ct-registry` (needs `SSH_KEY`) |
| `ctactions_ref` | `'main'` | Ref of CTActions the scripts are checked out from |

## Tests

`scripts/breakage/test/runtests.jl`: the verdict (not a release; a release breaking
nothing, breaking something with or without a breaking number, only the stable column
counting, no baseline, missing cells, a new target, `test` and `doc` cells apart, nothing to
test) and the files written; the consumers (each place a package may be loaded from, the uuid and not the
name, archived repositories, forks, exclusions, a repository that cannot be read being an
error and not an empty list, nothing to test being an empty list and not an error, the
declared targets and their validation, the command line,
the ecosystem as it was read on 2026-10-19). The reading of GitHub is replaced by a fake,
as in the release tests. `breakage-tests.yml` runs them when the script or the workflow
change. The `plan` and `break` jobs themselves are exercised by the callers.

## Superseded runs

On a pull request, a new run cancels the previous one of the same workflow and pull request;
nothing is cancelled on `main` or on a tag. See [Superseded runs](superseded-runs.md).

## On a push to `main`: the label `ci on main: changes only`

The first job, `changes`, decides whether the jobs of this workflow run on a push to `main`.
Without the label `ci on main: changes only` on the merged pull request they always run;
with it, they run only if a changed file can affect them. The input `ctactions_ref`
(default `main`) is the ref of CTActions whose scripts `changes` runs, to test a change. See
[CI on `main`](ci-on-main.md).
