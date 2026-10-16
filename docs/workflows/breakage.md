# `breakage.yml`: test the downstream packages

[← Workflows of control-toolbox](../README.md)

Answers *"if I merge this PR, do the packages that depend on this one still pass?"*:
clones a downstream package at its `latest` (default branch) or `stable` (newest tag)
version, `dev`s the PR's package into it, runs its tests (or builds its docs), and
comments a result table on the PR. Caller: `Breakage.yml`, in every package with
downstream consumers in the ecosystem (see [Repositories](../repositories.md)).

## Caller

```yaml
# .github/workflows/Breakage.yml (CTBase)
name: Breakage

on:
  pull_request:
    types: [labeled, synchronize, reopened]

jobs:
  break:
    if: >
      (github.event.action == 'labeled' && github.event.label.name == 'run breakage') ||
      (github.event.action != 'labeled' && contains(github.event.pull_request.labels.*.name, 'run breakage'))
    strategy:
      fail-fast: false
      matrix:
        pkgname: [CTDirect, CTFlows, CTModels, CTParser, CTSolvers, OptimalControl]
        pkgversion: [latest, stable]
    uses: control-toolbox/CTActions/.github/workflows/breakage.yml@main
    with:
      pkgname: ${{ matrix.pkgname }}
      pkgpath: control-toolbox
      pkgversion: ${{ matrix.pkgversion }}
      use_ct_registry: true
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}
```

## Inputs and secrets

| Input | Default | Meaning |
| --- | --- | --- |
| `pkgname` | required | Downstream package, without `.jl` |
| `pkgpath` | required | Its GitHub owner (`control-toolbox`, or a user for an application) |
| `pkgversion` | required | `latest` (default branch), `stable` (newest `v*` tag), or a ref |
| `pkgbreak` | `'test'` | `test` (run its tests) or `doc` (build its docs) |
| `use_ct_registry` | `false` | Add `ct-registry` (needs `SSH_KEY`) |

| Secret | |
| --- | --- |
| `SSH_KEY` | for `ct-registry` |

## What it does

Each matrix entry runs on `ubuntu-latest` (Julia 1) and records a ✅/❌ badge with the
version of the PR's package the downstream one declared; the `comment` job gathers them
in a `Name | Latest | Stable` table, posted on the PR or updating the previous comment of
`github-actions[bot]`. A failure does not fail the job: read the table.

**Who tests what:**

- a **foundation** package (CTBase) lists every package above it (CTDirect, CTFlows,
  CTModels, CTParser, CTSolvers, OptimalControl);
- the **umbrella** package (OptimalControl) tests downstream **applications and
  tutorials**: `run breakage` for OptimalControlProblems and Tutorials, and
  `run breakage applications` for the applications, most with `pkgbreak: doc` and some
  outside the organization (`pkgpath: agustinyabo`, …);
- a **leaf** repository with no internal dependents has no `Breakage.yml`.
