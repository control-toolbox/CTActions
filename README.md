# CTActions

Centralized GitHub Actions workflows, issue templates, and configuration for the [control-toolbox](https://github.com/control-toolbox) organization's Julia packages.

## Overview

This repository provides **reusable workflows** (`workflow_call`) that every control-toolbox package can include via `uses: control-toolbox/CTActions/.github/workflows/<file>@main`. It also ships standard issue templates and a Dependabot configuration for keeping GitHub Actions versions up to date.

## Reusable workflows

| Workflow | Description | Key inputs |
|---|---|---|
| `ci.yml` | Build and test on a matrix of Julia versions, OS, and archs | `versions`, `runs_on`, `archs`, `use_ct_registry`, `test_args` |
| `coverage.yml` | Run tests and upload coverage to Codecov | `use_ct_registry` |
| `documentation.yml` | Build and deploy documentation with Documenter.jl | `use_ct_registry` |
| `formatter.yml` | Run JuliaFormatter (BlueStyle) and open a PR if needed | — |
| `compat-helper.yml` | Keep `[compat]` entries in `Project.toml` up to date | `subdirs` |
| `spell-check.yml` | Spell check with `typos` | `locale`, `extend-identifiers`, `config-path` |
| `breakage.yml` | Test downstream packages against a new version; comment results on PR | `pkgname`, `pkgpath`, `pkgversion`, `pkgbreak` |
| `add-to-project.yml` | Auto-add issues/PRs to the org GitHub project | `project-url`, `status` |
| `auto-assign.yml` | Auto-assign issues to maintainers | `assignees`, `numOfAssignee` |
| `update-readme.yml` | Generate README from `ABOUT.md`, `INSTALL.md`, `CONTRIBUTING.md` + badges | `template_file`, `package_name`, `repo_name`, `doc_url` |

## Scheduled / maintenance workflows

| Workflow | Schedule | Description |
|---|---|---|
| `occidata-runner-maintenance.yml` | Weekly (Mon 02:30 UTC) | Purge Julia cache, update TeXLive, rotate logs on self-hosted runner |
| `remove-julia.yml` | Weekly (Mon 01:23 UTC) | Remove stale Julia installations on self-hosted runner |

## Usage example

```yaml
# .github/workflows/CI.yml in a control-toolbox package
name: CI
on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    uses: control-toolbox/CTActions/.github/workflows/ci.yml@main
    with:
      versions: '["1.10", "1.12"]'
      use_ct_registry: true
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}
```

## Issue templates

Five templates are provided: **Bug report**, **Feature request**, **Documentation suggestion**, **Developers** (internal), and **Blank issue**. Discussions are redirected to [GitHub Discussions](https://github.com/control-toolbox/CTActions/discussions).

## Dependabot

Weekly updates for GitHub Actions versions (see `dependabot.yml`).

## Links

- [control-toolbox organization](https://github.com/control-toolbox)
- [Organization profile repo](https://github.com/control-toolbox/.github)
- [Discussions](https://github.com/orgs/control-toolbox/discussions)
