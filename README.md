# CTActions

Centralized GitHub Actions workflows, issue templates and configuration for the
[control-toolbox](https://github.com/control-toolbox) organization's Julia packages.

## What is here

- **Reusable workflows** (`on: workflow_call`) that every package calls with a thin
  caller: `uses: control-toolbox/CTActions/.github/workflows/<name>.yml@main`. CI,
  coverage, documentation, breakage, formatting, spell check, CompatHelper, README
  generation, issue assignment, project board.
- **Workflows for the whole organization**, run here on a schedule: the monthly
  [`[compat]` prune](docs/workflows/compat-prune.md) of every CT\* package, the
  maintenance and watchdog of the `occidata` self-hosted runner.
- The organization's **GitHub App**, [`control-toolbox-bot`](docs/conventions/github-app.md),
  used by the workflows that write to other repositories.
- Issue templates and the Dependabot configuration.

## Documentation

**[docs/README.md](docs/README.md)**: the philosophy (centralize then call, opt-in
labels), the catalog of every workflow with its page, and the conventions:

| Page | Content |
| --- | --- |
| [Labels](docs/conventions/labels.md) | Opt-in triggers on pull requests, and their vocabulary |
| [Runners](docs/conventions/runners.md) | GitHub-hosted and self-hosted (GPU) runners, split CI |
| [Secrets and registries](docs/conventions/secrets.md) | Every secret, `ct-registry` |
| [GitHub App](docs/conventions/github-app.md) | `control-toolbox-bot`, and how to use it for something new |
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
  pull_request:
    types: [labeled, synchronize, reopened]

jobs:
  test-cpu-github:
    if: >
      github.event_name != 'pull_request' ||
      (github.event.action == 'labeled' && github.event.label.name == 'run ci github-runner') ||
      (github.event.action != 'labeled' && contains(github.event.pull_request.labels.*.name, 'run ci github-runner'))
    uses: control-toolbox/CTActions/.github/workflows/ci.yml@main
    with:
      runs_on: '["ubuntu-latest", "macos-latest", "windows-latest"]'
      use_ct_registry: true
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}
```

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
