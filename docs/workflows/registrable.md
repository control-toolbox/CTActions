# `registrable.yml`: a stable release resolves from General alone

[← Workflows of control-toolbox](../README.md)

Checks [`REL4`](https://github.com/control-toolbox/ct-conventions/blob/main/rules/release.md#rel4--a-stable-release-resolves-from-general-alone)
of ct-conventions: the package and each of its weak dependencies resolve in an
environment whose only registry is General. Caller: `Registrable.yml`, in every package.

The CI, coverage, documentation and breakage callers set `use_ct_registry: true`: they
resolve against ct-registry too, so they pass with a `[compat]` bound that only a beta
satisfies (`Dep = "0.9"` while General stops at `0.8.15`). General's AutoMerge rejects such
a release, after the tag. This workflow sees what AutoMerge will see.

## When it checks

On a pull request, only when the PR sets a **stable version** (no pre-release suffix)
other than the base's: that is, on a release PR. Any other PR, a beta release included,
succeeds at once with *not checked* and the reason in the job summary. By hand
(`workflow_dispatch`), or with `always: true`, the package is always checked, whatever
its version: useful before preparing a stable release from a `main` that is on a beta.

Cheap and GitHub-hosted (resolution only, nothing is downloaded but the registry): no
label, like [`spell-check.yml`](spell-check.md).

## Caller

```yaml
# .github/workflows/Registrable.yml
name: Registrable

on:
  pull_request:
    paths:
      - Project.toml
  workflow_dispatch:

jobs:
  call:
    uses: control-toolbox/CTActions/.github/workflows/registrable.yml@main
```

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `project` | `'Project.toml'` | The Project.toml to check |
| `julia_versions` | `'["1.10", "1"]'` | Julia versions the resolution runs on (one job each) |
| `always` | `false` | Check even a pull request that does not set a new stable version |
| `ctactions_ref` | `'main'` | Ref of CTActions the script is checked out from |

## The report

One table per Julia version in the job summary: the `[deps]` environment, then
`[deps]` plus each weak dependency (one at a time, so that two extensions are never
resolved together), each ✅ or ❌. For each bound that no version in General satisfies,
the versions of the other registries of the depot that do, and the resolver's error:

```text
- `CTParser = "0.9"`: satisfied in ct-registry: `0.9.0-beta`, …, `0.9.5-beta`.
```

On the runner the depot holds General only, so "other registries" is empty there; run
locally, with ct-registry installed, the report names the betas.

## Running it locally

The script ignores every registry of the depot but General, so it runs as is on a
developer's machine (General must be installed):

```bash
julia --startup-file=no scripts/registrable/registrable.jl path/to/Project.toml
# as on a pull request: checked only if the version is a new stable one
julia --startup-file=no scripts/registrable/registrable.jl --base base/Project.toml path/to/Project.toml
```

Exit code 0 when every environment resolves (or the check does not apply), 1 when one
does not, 2 on a usage error.

## Tests

`scripts/registrable/test/runtests.jl`: unit tests on parsed fixtures and a fake
registry, and integration tests resolving the fixtures against the local General
(`Example`, `OrderedCollections`; a bound General cannot satisfy stands for a beta-only
one). `registrable-tests.yml` runs them on Julia 1.10, 1.12 and 1.13, then the reusable
workflow on a fixture, whenever the script or the workflows change. The script calls two
internals of Pkg (`Pkg.Operations.resolve_versions!`, `Pkg.Registry.registry_info`, whose
signature changed in 1.13): the matrix is what guards them.
