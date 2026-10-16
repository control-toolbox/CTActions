# `compat-helper.yml`: widen `[compat]` to new releases

[← Workflows of control-toolbox](../README.md)

Runs [CompatHelper](https://github.com/JuliaRegistries/CompatHelper.jl) (v3): for each
dependency with a release outside its `[compat]` entry, opens a PR adding it. Caller:
`CompatHelper.yml`, in every package.

## Caller

```yaml
# .github/workflows/CompatHelper.yml
name: CompatHelper

on:
  schedule:
    - cron: 0 0 * * *
  workflow_dispatch:

jobs:
  call:
    uses: control-toolbox/CTActions/.github/workflows/compat-helper.yml@main
    with:
      subdirs: '["", "docs"]'
```

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `subdirs` | `'["", "docs", "test"]'` | Directories whose `Project.toml` is checked (`""` is the package itself) |

No secrets are declared: it runs with `GITHUB_TOKEN` (the workflow requests
`contents: write` and `pull-requests: write`). `COMPATHELPER_PRIV` is set from
`DOCUMENTER_KEY`, which is empty unless the caller passes `secrets: inherit` (see
[Secrets](../conventions/secrets.md)). As with any PR opened by `GITHUB_TOKEN`, label the
PR to run the checks.

## Widening, then pruning

CompatHelper runs with **`KeepEntry()`**: a new release is added next to the old ones
(`JET = "0.9, 0.11, 0.12"`), never in place of them, so a package keeps working with the
versions its users may be pinned to. [`ci.yml`](ci.md) tests the newest versions on these
PRs (`force_latest_compatible_version`, except on Julia 1.10).

Old specifiers then pile up, and none can be dropped from inside one package: one may be
what Julia 1.10 still selects, or what another package's tests select. Dropping them is
the organization's monthly [`[compat]` prune](compat-prune.md): CompatHelper widens from
the top, the prune trims what no supported Julia version selects any more.
