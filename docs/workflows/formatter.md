# `formatter.yml`: JuliaFormatter

[← Workflows of control-toolbox](../README.md)

Formats every `.jl` file with JuliaFormatter's `BlueStyle()` and, when something
changed, opens (or updates) the PR `[AUTO] JuliaFormatter.jl run` from the branch
`auto-juliaformatter-pr`, labelled `formatting`, `automated pr`, `no changelog`. Caller:
`Formatter.yml`, in every package.

## Caller

```yaml
# .github/workflows/Formatter.yml
name: Formatter

on:
  schedule:
    - cron: '0 0 * * *'
  workflow_dispatch:

jobs:
  call:
    uses: control-toolbox/CTActions/.github/workflows/formatter.yml@main
```

No inputs, no secrets. The PR is opened with `GITHUB_TOKEN`
(`peter-evans/create-pull-request`), so it triggers no workflow: label it to run the
checks you want.

A repository can opt out without deleting its caller: `Formatter.yml.disabled` is ignored
by GitHub (CTDirect.jl). Rename it back to re-enable.
