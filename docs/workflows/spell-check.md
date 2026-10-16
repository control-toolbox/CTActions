# `spell-check.yml`: spelling

[← Workflows of control-toolbox](../README.md)

Checks the spelling of the repository with [`crate-ci/typos`](https://github.com/crate-ci/typos).
Caller: `SpellCheck.yml`, in every package. Cheap and GitHub-hosted: it runs on every PR
event, with no label.

## Caller

```yaml
# .github/workflows/SpellCheck.yml
name: Spell Check

on:
  pull_request:
  workflow_dispatch:

jobs:
  call:
    uses: control-toolbox/CTActions/.github/workflows/spell-check.yml@main
    with:
      config-path: '_typos.toml'
```

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `config-path` | `''` | A `typos` configuration in the repository; when empty, one is generated from the two inputs below |
| `locale` | `'en'` | Locale of the generated configuration |
| `extend-identifiers` | `''` | Lines `identifier = "identifier"` for its `[default.extend-identifiers]` |

The generated configuration excludes `*.json`, `*.toml` and `*.svg`. A package with its
own `_typos.toml` (OptimalControl.jl) controls everything there.
