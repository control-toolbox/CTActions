# GitHub workflows of control-toolbox

How the control-toolbox organization runs GitHub Actions across its repositories. Read
this before creating a repository, before adding or editing a workflow, or when
wondering why a workflow is (or is not) present in a package.

Two repositories go with this documentation:
[`CTActions`](https://github.com/control-toolbox/CTActions), the central workflow
library (this repository), and
[`CTAppTemplate.jl`](https://github.com/control-toolbox/CTAppTemplate.jl), the template
a new package starts from.

## The philosophy

### Centralize, then call

A control-toolbox repository **does not define its CI logic**. The logic lives once in
`CTActions`, as **reusable workflows** (`on: workflow_call`). Every package ships only
thin **callers** that delegate to them:

```yaml
# .github/workflows/CI.yml, in any package
jobs:
  call:
    uses: control-toolbox/CTActions/.github/workflows/ci.yml@main
    with:
      runs_on: '["ubuntu-latest", "macos-latest", "windows-latest"]'
      use_ct_registry: true
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}
```

- **Single source of truth.** A CI fix or an action bump is made once in `CTActions`;
  every repository picks it up on its next run, since callers pin `@main`.
- **Thin, declarative callers.** A caller only says *which* shared workflow to call, on
  *which events*, with *which inputs and secrets*. No step logic.
- **Consistency.** Every package tests, builds its docs, formats and spell-checks the
  same way.
- **Easy onboarding.** A new repository copies the callers from the template and
  inherits the whole pipeline.

| Layer | Location | File name | Example |
| --- | --- | --- | --- |
| **Reusable** (the logic) | `CTActions/.github/workflows/` | `kebab-case.yml` | `ci.yml` |
| **Caller** (the trigger) | `<package>/.github/workflows/` | `PascalCase.yml` | `CI.yml` |

Callers reference a reusable workflow by its full path, pinned to `@main`:
`control-toolbox/CTActions/.github/workflows/<name>.yml@main`. A frozen pipeline (for a
release branch, say) pins a tag or a commit of `CTActions` instead.

### Expensive checks are opt-in, through labels

Running the full matrix (CI on three OSes and GPU runners, breakage against every
downstream package, a documentation build) on every push to every PR is slow and
wasteful. Expensive workflows therefore run on a pull request only when it carries a
**trigger label** (`run ci github-runner`, `run documentation`, `run breakage`, …), and
always on `push` to `main` and on tags. The guard, the `types:` list and the label
vocabulary are in [Labels](conventions/labels.md).

### The organization acts as one, through CTActions

A few workflows are not called by packages: they run in `CTActions` itself, on a
schedule, for the whole organization (the self-hosted runners, the `[compat]` prune).
When one of them must write to other repositories, it does so as the organization's
GitHub App, [`control-toolbox-bot`](conventions/github-app.md), never with a personal
token.

## The workflows

### Reusable workflows (called by packages)

| Workflow | Caller | Role | Runs on a PR |
| --- | --- | --- | --- |
| [`ci.yml`](workflows/ci.md) | `CI.yml` | Test suite over a Julia × OS × arch matrix, on GitHub-hosted or self-hosted (GPU) runners | label `run ci <runner>` |
| [`coverage.yml`](workflows/coverage.md) | `Coverage.yml` | Test suite with coverage, uploaded to Codecov | no (push and tags) |
| [`documentation.yml`](workflows/documentation.md) | `Documentation.yml` | Build and deploy the documentation; optional GPU upgrade pass; opt-in PR previews | label `run documentation` |
| [`documentation-preview-cleanup.yml`](workflows/documentation-preview-cleanup.md) | `DocPreviewCleanup.yml` | Remove the previews of closed PRs from `gh-pages` | on close |
| [`breakage.yml`](workflows/breakage.md) | `Breakage.yml` | Test downstream packages against the PR; comment a result table | label `run breakage` |
| [`formatter.yml`](workflows/formatter.md) | `Formatter.yml` | JuliaFormatter (BlueStyle), as an automatic PR | no (nightly) |
| [`spell-check.yml`](workflows/spell-check.md) | `SpellCheck.yml` | Spell check with `typos` | every PR |
| [`release-gate.yml`](workflows/release-gate.md) | `ReleaseGate.yml` | The gate of a release PR: `REL1`–`REL7` (number, changelog, diff, something to release, run labels, General alone); a required check | every PR (passes at once when the version does not change) |
| [`release-tag.yml`](workflows/release-tag.md) | `ReleaseTag.yml` | Tag the merge commit of a release PR and create its GitHub release, as the organization's App | push to `main` touching `Project.toml` |
| [`compat-helper.yml`](workflows/compat-helper.md) | `CompatHelper.yml` | PRs widening `[compat]` to new releases | no (daily) |
| [`update-readme.yml`](workflows/update-readme.md) | `UpdateReadme.yml` | Regenerate `README.md` from a template and the organization's shared texts | no (weekly) |
| [`auto-assign.yml`](workflows/auto-assign.md) | `AutoAssign.yml` | Assign new issues and PRs to a maintainer | on open |
| [`add-to-project.yml`](workflows/add-to-project.md) | `AddToProject.yml` | Add new issues and PRs to the organization's project board | on open |

### Workflows that run in CTActions

| Workflow | Role | Trigger |
| --- | --- | --- |
| [`compat-prune-monthly.yml`](workflows/compat-prune.md) | The organization's `[compat]` prune (logic: reusable `compat-prune.yml`): one PR per repository, one tracking issue in CTActions | monthly (1st, 04:00 UTC), by hand |
| [`compat-prune-tests.yml`](workflows/compat-prune.md#tests) | Self-test of the prune: its test suite, then a real dry-run audit | PR or push touching it, by hand |
| [`release-tests.yml`](workflows/release-gate.md#tests) | Self-test of the release tool (`scripts/release`) on Julia 1.10, 1.12, 1.13 | PR or push touching it, by hand |
| [`occidata-runner-maintenance.yml`](workflows/occidata-runner-maintenance.md) | Clean the `occidata` self-hosted runner (git config, caches, logs, TeXLive) | weekly (Mon 02:30 UTC), by hand |
| [`occidata-runner-watchdog.yml`](workflows/occidata-runner-watchdog.md) | Restart, over SSH, the `occidata` runner jobs that stopped | daily (03:15 UTC), by hand |

### Workflows that live in a package

TagBot (every package), `setup-repo` (template), JOSS, probes, targeted and cron CI,
benchmarks: see [Workflows defined in a package](workflows/per-repo.md).

## The rest of this documentation

| Page | Content |
| --- | --- |
| [Labels](conventions/labels.md) | Label-gated triggers: the `if:` guard, the `types:` list (no `opened`), the label vocabulary |
| [Required checks](conventions/required-checks.md) | The checks of `main` a PR must pass, one aggregator per theme (`ci-ok`, `docs-ok`), the settings for auto-merge |
| [Runners](conventions/runners.md) | GitHub-hosted and self-hosted runners: `occidata` (GPU on demand), `kkt`, `pinwheel`; the split CI |
| [Secrets and registries](conventions/secrets.md) | Every secret, who uses it; `ct-registry` and `SSH_KEY` |
| [GitHub App](conventions/github-app.md) | `control-toolbox-bot`: what it is, how to use it in a new workflow, how to extend it |
| [Repositories](repositories.md) | Which repository has which workflow, and why |
| [Recipes](recipes.md) | A new repository, an organization-wide change, the checklist |
