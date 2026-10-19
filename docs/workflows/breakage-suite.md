# `breakage-suite.yml`: test the downstream packages, report once

[← Workflows of control-toolbox](../README.md)

Tests the packages that depend on this one against it, and reports **once**: one table in
the job summary, one PR comment per group kept up to date, one artifact. Caller:
`Breakage.yml`. Replaces [`breakage.yml`](breakage.md), whose cells each rewrote the
comment with the results present at that moment (the last one to write could post an
incomplete table) and which found its comment by the bot's id; `breakage.yml` stays until
every caller has moved.

## What it does

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

on:
  pull_request:
    types: [labeled, synchronize, reopened]
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  call:
    if: >
      github.event_name != 'pull_request' ||
      (github.event.action == 'labeled' && github.event.label.name == 'run breakage') ||
      (github.event.action != 'labeled' && contains(github.event.pull_request.labels.*.name, 'run breakage'))
    uses: control-toolbox/CTActions/.github/workflows/breakage-suite.yml@main
    with:
      targets: >-
        [{"name": "CTDirect"}, {"name": "CTFlows"}, {"name": "CTModels"},
         {"name": "CTParser"}, {"name": "CTSolvers"}, {"name": "OptimalControl"}]
      use_ct_registry: true
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}
```

A package with two suites (OptimalControl: `run breakage` for its packages, `run breakage
applications` for the applications) calls it twice, with two `group`s; a heavy suite may
leave out the `push` trigger and be run by hand on `main` before a release.

## Inputs and secrets

| Input | Default | Meaning |
| --- | --- | --- |
| `targets` | required | JSON list of `{"name", "owner", "break"}`: the package without `.jl`, its GitHub owner (default `control-toolbox`), `test` (default) or `doc` |
| `versions` | `'["latest", "stable"]'` | The versions of each package |
| `group` | `'packages'` | Name of the suite: its comment and its artifact |
| `use_ct_registry` | `false` | Add `ct-registry` (needs `SSH_KEY`) |
| `ctactions_ref` | `'main'` | Ref of CTActions the scripts are checked out from |

## Tests

`scripts/breakage/test/runtests.jl`: the verdict (not a release; a release breaking
nothing, breaking something with or without a breaking number, only the stable column
counting, no baseline, missing cells, `test` and `doc` cells apart) and the files written.
`breakage-tests.yml` runs them when the script or the workflow change. The `break` job
itself is exercised by the callers.
