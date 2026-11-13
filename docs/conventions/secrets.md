# Secrets and registries

[← Workflows of control-toolbox](../README.md)

## Secrets

| Secret | Where it is defined | Used by | Purpose |
| --- | --- | --- | --- |
| `SSH_KEY` | organization (all repositories) | `ci.yml`, `coverage.yml`, `documentation.yml`, `breakage-suite.yml` | Add `ct-registry` (see below) |
| `DOCUMENTER_KEY` | organization (all repositories) | TagBot callers (`ssh:`); read by `documentation.yml` and `compat-helper.yml` (see the note) | Documenter deploy key; TagBot's SSH key |
| `CODECOV_TOKEN` → `codecov-secret` | organization (all repositories) | `coverage.yml` | Upload to Codecov |
| `PROJECT_TOKEN` → `project_token` | organization (all repositories) | `add-to-project.yml` | Write to the organization's project board |
| `CT_PRUNE_COMPAT_CLIENT_ID`, `CT_PRUNE_COMPAT_PRIVATE_KEY` | organization, **CTActions only** | `compat-prune-monthly.yml` (`publish` job) | Token of the organization's [GitHub App](github-app.md) |
| `CT_RELEASE_CLIENT_ID`, `CT_RELEASE_PRIVATE_KEY` | **the environments `release` and `release-autonomous` of each package**, not the repository nor the organization | `release.yml` (jobs `start`, `merge`, `register`) | Token of the App [`ct-release`](github-app.md#ct-release-the-app-of-the-releases): only the jobs of the environment, after its approval, can mint it |
| `CT_RELEASE_REGISTRATION_TOKEN` (recommended) | the same environments, set by [`setup.sh`](../workflows/release.md#setting-it-up) | `release.yml` (job `register`) | The token of a release manager who is a **public** member of the organization, for the registration comment of a stable: the registration bot takes no comment of an App. Without it, the comment is handed to a person ([details](../workflows/release.md#the-registration-comment)) |
| `CT_RUNNERS_CLIENT_ID`, `CT_RUNNERS_PRIVATE_KEY` | organization (all repositories) | `select-gpu-runner.yml` | Token of the read-only App `ct-runners` ([details](../workflows/select-gpu-runner.md#the-github-app-ct-runners)) |
| `OCCIDATA_SSH_KEY`, `OCCIDATA_KNOWN_HOSTS` | CTActions | `occidata-runner-watchdog.yml` | SSH to `occidata-cluster.irit.fr` |
| `GITHUB_TOKEN` | built in | most workflows | Token of the repository the workflow runs in |

The organization **variable** `CT_RELEASE_MANAGERS` (comma-separated logins) lists who may
hand a release to [`release.yml`](../workflows/release.md). Not a secret: who
may release is public; changing it needs an organization owner.

**Pass secrets explicitly, one by one** (`secrets: SSH_KEY: ${{ secrets.SSH_KEY }}`). Use
`secrets: inherit` (as `UpdateReadme.yml` callers do) only when the reusable workflow
needs the caller's whole set, or the secrets of an environment: those reach a job of a
reusable workflow only when the caller inherits (`Release.yml`, see
[release.md](../workflows/release.md#caller)).

> **Note.** A reusable workflow only sees the secrets it declares under
> `workflow_call.secrets` and that its caller passes, or every secret with
> `secrets: inherit`. `documentation.yml` and `compat-helper.yml` declare
> `DOCUMENTER_KEY` as optional, and their callers pass `SSH_KEY` only (or nothing): the
> key is empty there, and the documentation deploys with `GITHUB_TOKEN`. A caller that
> needs it passes it. `lint-workflows.yml` (actionlint) refuses a secret read without
> being declared.

**`GITHUB_TOKEN` is limited to its own repository**, and what it pushes or opens does not
trigger other workflows (no CI on a PR it opens). A workflow that must write to other
repositories, or open PRs that run CI, uses the [GitHub App](github-app.md); not a
personal access token.

## `ct-registry`

Several packages depend on ecosystem packages registered in
[`control-toolbox/ct-registry`](https://github.com/control-toolbox/ct-registry) rather than
in General. The registry is **public**.

- **In the reusable workflows** (`ci.yml`, `coverage.yml`, `documentation.yml`,
  `breakage-suite.yml`), the caller passes `use_ct_registry: true` **and** `SSH_KEY`; the
  workflow then runs `julia-actions/add-julia-registry`, which clones over SSH. Set
  `use_ct_registry: false` for a package that needs General only.
- **In `compat-prune.yml`**, the registry is added over HTTPS
  (`Pkg.Registry.add(url="https://github.com/control-toolbox/ct-registry.git")`), with no
  key.

On Windows, `add-julia-registry` needs Git's own OpenSSH client and Pkg needs the CLI git
(`git_cli: true` on `julia-buildpkg`): `ci.yml` does both (see the comments in the
workflow). `coverage.yml`, `documentation.yml` and `breakage-suite.yml` run on Ubuntu only.

## Pull requests from a fork

A pull request from a fork runs with **no secret and a read-only `GITHUB_TOKEN`**.
The workflows degrade instead of failing with an obscure message:

| Workflow | On a fork's pull request |
| --- | --- |
| `ci.yml`, `documentation.yml`, `breakage-suite.yml` | run; `ct-registry` is added from its public HTTPS URL (composite action `.github/actions/add-ct-registry`, a notice in the log) instead of with `SSH_KEY` |
| `breakage-suite.yml` | the report is in the run's summary; no PR comment (it would be a 403) |
| `auto-assign.yml`, `add-to-project.yml` | skipped: the maintainer assigns and adds the PR by hand |
| `documentation.yml` | the build runs, no preview is deployed |

Never `pull_request_target` for what runs the PR's code (CI, breakage, documentation):
it would hand the secrets to it. A dependency that only a beta in `ct-registry` satisfies
resolves the same way, since the registry is the same.
