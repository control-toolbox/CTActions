# Secrets and registries

[← Workflows of control-toolbox](../README.md)

## Secrets

| Secret | Where it is defined | Used by | Purpose |
| --- | --- | --- | --- |
| `SSH_KEY` | organization (all repositories) | `ci.yml`, `coverage.yml`, `documentation.yml`, `breakage.yml` | Add `ct-registry` (see below) |
| `DOCUMENTER_KEY` | organization (all repositories) | TagBot callers (`ssh:`); read by `documentation.yml` and `compat-helper.yml` (see the note) | Documenter deploy key; TagBot's SSH key |
| `CODECOV_TOKEN` → `codecov-secret` | organization (all repositories) | `coverage.yml` | Upload to Codecov |
| `PROJECT_TOKEN` → `project_token` | organization (all repositories) | `add-to-project.yml` | Write to the organization's project board |
| `CT_APP_CLIENT_ID`, `CT_APP_PRIVATE_KEY` | organization, **CTActions only** | `compat-prune-monthly.yml` (`publish` job) | Token of the organization's [GitHub App](github-app.md) |
| `CT_RUNNERS_CLIENT_ID`, `CT_RUNNERS_PRIVATE_KEY` | organization, the packages with a GPU CI | `select-gpu-runner.yml` | Token of the read-only App `ct-runners` ([details](../workflows/select-gpu-runner.md#the-github-app-ct-runners)) |
| `OCCIDATA_SSH_KEY`, `OCCIDATA_KNOWN_HOSTS` | CTActions | `occidata-runner-watchdog.yml` | SSH to `occidata-cluster.irit.fr` |
| `GITHUB_TOKEN` | built in | most workflows | Token of the repository the workflow runs in |

**Pass secrets explicitly, one by one** (`secrets: SSH_KEY: ${{ secrets.SSH_KEY }}`). Use
`secrets: inherit` (as `UpdateReadme.yml` callers do) only when the reusable workflow
needs the caller's whole set.

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
  `breakage.yml`), the caller passes `use_ct_registry: true` **and** `SSH_KEY`; the
  workflow then runs `julia-actions/add-julia-registry`, which clones over SSH. Set
  `use_ct_registry: false` for a package that needs General only.
- **In `compat-prune.yml`**, the registry is added over HTTPS
  (`Pkg.Registry.add(url="https://github.com/control-toolbox/ct-registry.git")`), with no
  key.

On Windows, `add-julia-registry` needs Git's own OpenSSH client and Pkg needs the CLI git
(`git_cli: true` on `julia-buildpkg`): `ci.yml` does both (see the comments in the
workflow). `coverage.yml`, `documentation.yml` and `breakage.yml` run on Ubuntu only.
