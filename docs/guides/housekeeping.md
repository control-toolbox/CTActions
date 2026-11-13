# Housekeeping: formatting, spelling, README, assignment, project board

[← Workflows of control-toolbox](../README.md)

The small workflows every package carries, what they do to your repository, and what you
do about them. Their choices are few and stated here; there is no separate design page.

| Workflow | When | What it does | What you do |
| --- | --- | --- | --- |
| [Formatter](../workflows/formatter.md) | nightly, by hand | formats every `.jl` with JuliaFormatter (`BlueStyle()`); when something changed, opens or updates the pull request `[AUTO] JuliaFormatter.jl run` | label it to run the checks, merge it; `ci on main: changes only` lets its merge skip the tests ([formatting only](../workflows/ci-on-main.md#formatting-only)) |
| [Spell check](../workflows/spell-check.md) | every pull request | `typos` on the repository, with the package's `_typos.toml` or a generated configuration | fix the word, or add it to `_typos.toml` |
| [Update README](../workflows/update-readme.md) | weekly, by hand | regenerates `README.md` from `README.template.md` and the organization's shared texts; opens `Update README (<date>)` when it changed | edit the template, never `README.md`; merge the pull request |
| [Auto assign](../workflows/auto-assign.md) | an issue or pull request opened or reopened | assigns a maintainer | nothing |
| [Add to project](../workflows/add-to-project.md) | an issue or pull request opened | adds it to the organization's board, status `Todo` | nothing |
| [CompatHelper](../workflows/compat-helper.md) | daily | see [Dependencies](dependencies.md) | |

## The pull requests of bots

The Formatter, Update README and CompatHelper pull requests are opened with
`GITHUB_TOKEN`: **they start no workflow by themselves**. Add the labels of the checks you
want ([the pull-request guide](pull-requests.md)); a label added by a person dispatches
normally.

## Setting up a package

Copy the callers from the template (`CTAppTemplate.jl`) or from CTBase.jl; see
[A new repository](../recipes.md#a-new-repository). Specifics:

- `UpdateReadme.yml` needs `README.template.md` and its inputs (`package_name`,
  `repo_name`, `doc_url`); without the template the caller skips itself.
- `AddToProject.yml` only in a repository tracked on the board; it needs `PROJECT_TOKEN`.
- To stop the Formatter in one repository without deleting it, rename the caller
  `Formatter.yml.disabled` (CTDirect.jl).

## Why

- **Bots open pull requests, they never push to `main`**: a change to the repository is
  reviewed and goes through the same checks as any other
  ([principle 9](../principles.md#9-a-person-decides-what-a-tool-cannot)).
- **`GITHUB_TOKEN` for them, not an App**: their pull requests need no CI unless someone
  asks for it, and the token reaches only its own repository
  ([principle 8](../principles.md#8-least-privilege-one-identity-per-power)). The cost is
  the label to add by hand.
- **Spell check without a label**: it is cheap and GitHub-hosted
  ([principle 6](../principles.md#6-expensive-is-opt-in-main-runs-everything)).
- **Assignment and the board react to `opened`**, unlike the label-gated workflows: they
  are actions "on creation" ([Labels](../conventions/labels.md#the-types-list-without-opened)).
- **One README template, shared texts in control-toolbox/.github**: the texts common to
  every package are written once ([principle 1](../principles.md#1-centralize-then-call)).
- **`PROJECT_TOKEN`, a token of its own**: `GITHUB_TOKEN` cannot write to an
  organization's project. An App with the *Projects* permission could replace it; not done.
