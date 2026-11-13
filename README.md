# CTActions

Centralized GitHub Actions workflows, issue templates and configuration for the
[control-toolbox](https://github.com/control-toolbox) organization's Julia packages.

## What is here

- **Reusable workflows** (`on: workflow_call`) that every package calls with a thin
  caller: `uses: control-toolbox/CTActions/.github/workflows/<name>.yml@main`. CI,
  coverage, documentation, breakage, formatting, spell check, CompatHelper, README
  generation, issue assignment, project board, and the **release** of a package, from its
  request to its registration ([`release.yml`](docs/workflows/release.md)).
- **The release tool**, [`scripts/release/release.jl`](docs/workflows/release-gate.md#the-release-tool):
  the facts and the request of a release, its gate, the checked merge, the registration,
  the audit; and `release.jl lint-changelog`, the format of `[Unreleased]` for anyone who
  edits a changelog.
- **Workflows for the whole organization**, run here on a schedule: the monthly
  [`[compat]` prune](docs/workflows/compat-prune.md) of every CT\* package, the
  maintenance and watchdog of the `occidata` self-hosted runner.
- The organization's **GitHub Apps**, [`ct-prune-compat`](docs/conventions/github-app.md),
  used by the workflows that write to other repositories, and
  [`ct-release`](docs/conventions/github-app.md#ct-release-the-app-of-the-releases), which
  opens, merges and registers releases, in the jobs of an approved environment only.
- Issue templates and the Dependabot configuration.

## Documentation

**[docs/README.md](docs/README.md)**: the philosophy (centralize then call, opt-in
labels), the catalog of every workflow with its page, and the conventions:

| Page | Content |
| --- | --- |
| [Principles](docs/principles.md) | The rules behind every workflow and script, and a checklist for a change |
| [Labels](docs/conventions/labels.md) | Opt-in triggers on pull requests, and their vocabulary |
| [Runners](docs/conventions/runners.md) | GitHub-hosted and self-hosted (GPU) runners, split CI |
| [Secrets and registries](docs/conventions/secrets.md) | Every secret, `ct-registry` |
| [GitHub Apps](docs/conventions/github-app.md) | `ct-prune-compat`, `ct-release`, and how to use one for something new |
| [Repositories](docs/repositories.md) | Which repository has which workflow, and why |
| [Recipes](docs/recipes.md) | A new repository, a change across the organization |

## Usage example

```yaml
# .github/workflows/CI.yml in a control-toolbox package
name: CI
on:
  push:
    branches: [main]
    tags: '*'
  workflow_dispatch:          # started by Labels.yml when a `run ci …` label is added to a PR
    inputs:
      pr:     { required: false, default: '' }
      target: { required: false, default: '' }

jobs:
  test-cpu-github:
    if: github.event_name == 'push' || inputs.target == 'github'
    uses: control-toolbox/CTActions/.github/workflows/ci.yml@main
    with:
      runs_on: '["ubuntu-latest", "macos-latest", "windows-latest"]'
      use_ct_registry: true
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}
```

On a pull request the expensive workflows run on demand, by label: the package's
`Labels.yml` calls [`label-dispatch.yml`](docs/workflows/label-dispatch.md), which starts
the workflow of the label just added.

More callers: one per page in [`docs/workflows/`](docs/workflows/).

## Issue templates

Five templates: **Bug report**, **Feature request**, **Documentation suggestion**,
**Developers** (internal) and **Blank issue**. Discussions are redirected to
[GitHub Discussions](https://github.com/orgs/control-toolbox/discussions).

## Dependabot

Weekly updates of the GitHub Actions versions (`.github/dependabot.yml`).

## Links

- [control-toolbox organization](https://github.com/control-toolbox)
- [Organization profile repository](https://github.com/control-toolbox/.github)
- [Discussions](https://github.com/orgs/control-toolbox/discussions)
