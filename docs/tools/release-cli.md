# `release.jl`: the release CLI

[← Workflows of control-toolbox](../README.md)

`scripts/release/release.jl` is the one entry point of the release tool, for the agent, a
person and the workflows: every step of a release is checked the same way wherever it runs
([principle 2](../principles.md#2-yaml-wires-scripts-decide)). Julia 1.10 or later, the
standard library only, `gh` logged in for the commands that read GitHub. The commands of a
release, in the order of the
[recipe](https://github.com/control-toolbox/ct-agents/blob/main/recipes/release.md):
`facts`, `request`, then `status`, `gate`, `ready`, `merge`, `tag-plan`, `register` or
`register-beta`, `audit`; `finish` is the workflow's.

## Commands

```bash
julia scripts/release/release.jl status --repo control-toolbox/CTBase.jl [--version 0.30.12]
julia scripts/release/release.jl gate --base <base sha> --labels "run breakage,run ci github-runner" [--labels-info] <clone>
julia scripts/release/release.jl registrable [--base base/Project.toml] Project.toml
julia scripts/release/release.jl stable-release --base base/Project.toml Project.toml
julia scripts/release/release.jl tag-plan <clone>
julia scripts/release/release.jl ready --repo control-toolbox/CTBase.jl --pr 640
julia scripts/release/release.jl merge --repo control-toolbox/CTBase.jl --pr 640 [--confirm]
julia scripts/release/release.jl register --repo control-toolbox/CTBase.jl --version 0.30.12 [--post] [--on-commit]
julia scripts/release/release.jl audit --repo control-toolbox/CTBase.jl --version 0.30.12
julia scripts/release/release.jl lint-changelog [<clone>]
julia scripts/release/release.jl facts --repo control-toolbox/CTBase.jl --kind stable|beta [<clone>]
julia scripts/release/release.jl request --repo control-toolbox/CTBase.jl [--no-dispatch] .releases/v0.30.13.toml [<clone>]
julia scripts/release/release.jl register-beta --repo control-toolbox/CTBase.jl --version 0.31.0-beta [--confirm]
julia scripts/release/release.jl finish --repo control-toolbox/CTBase.jl --managers ocots [--version V --actor L --dir D] [--act start|merge|register|register-beta] [--by-hand]
```

- **`lint-changelog`**, **`facts`**, **`request`**, **`finish`**, **`register-beta`**: the
  request of a release and the workflow that runs it, see [release.md](../workflows/release.md#the-request)
  (the request) and [How the workflow works](../workflows/release.md#how-the-workflow-works)
  (`finish`, `register-beta`). `lint-changelog` checks the format of `[Unreleased]` in
  `CHANGELOG.md` and `BREAKING.md` (`CHG2`–`CHG4`), for anyone who edits them.

- **`status`** says where a release stands, from the facts only — the tracking issue and
  its registration mentions, the release PR and its merge commit, the tag and its tree,
  the GitHub release, General's PR, the registries, the bot's answer on the issue — and
  gives the phase of the
  [release recipe](https://github.com/control-toolbox/ct-agents/blob/main/recipes/release.md),
  the next action and what blocks it. A session that stopped, a remote run or a human all
  resume from the same answer; nothing is remembered. It refuses what would break the
  release: two tracking issues, a tag on another commit than the merge, an error answer of
  the bot or two mentions (never post twice, `REL6`), `main` moved past the merge commit
  before the registration, a registered tree that is not the tag's, a version registered
  without tag. It reads lists, never GitHub's search, whose index lags behind a new issue.
- **`gate`** checks a release PR against `REL1`–`REL7`: [what it checks](../workflows/release-gate.md#what-it-checks).
- **`registrable`** is `REL4` alone, also on a developer's machine: the other registries of
  the depot are ignored, and the report names the betas that satisfy a bound General
  cannot.
- **`stable-release`** says whether a `Project.toml` sets a stable version other than its
  base's (`stable=true|false`): the workflows then leave ct-registry out, so that the CI
  of a stable release PR resolves from General alone (`REL4`).
- **`tag-plan`** is what [`release-tag.yml`](../workflows/release-tag.md) tags.
- **`ready`** and **`merge`**: whether a release PR may be merged, from what actually ran on
  its head commit, and the merge at that commit: [The merge](../workflows/release-gate.md#the-merge).
- **`register`** builds and posts the registration comment of a stable (`REL6`): the bot's
  mention, the CHANGELOG entry (links made absolute at the tag) and the GitHub release's
  notes. It refuses unless `status` says phase 7, todo — so never twice, never for a beta,
  never once `main` has moved — and checks afterwards that the issue holds one mention
  (a mention the bot refused registered nothing and does not count).
  Without `--post` it is a dry run, which shows the comment with the mention masked, so
  that it can be pasted anywhere. The bot registers the head of `main` when asked on an
  issue, and a commit when asked on that commit: once `main` has moved past the merge
  commit, `status` says so, and `--on-commit` (asked explicitly, after a human's go) posts
  the comment on the merge commit instead; `status` counts the mentions and reads the bot's
  answers there too.
- **`audit`** judges a finished release, from the facts and never from what the agent says
  it did: whether it left the trail the recipe asks for. `status` says where a release
  stands; `audit` says whether one that stands at its end went the way the recipe requires.
  It checks that `status` says *done*; one tracking issue, closed, whose description is
  written and does not mention the bot; a comment with a state marker for the proposal
  and for each of the phases 3 to 8, in order, naming this release, the last one the final
  comment with every step ✅; for a stable, one registration mention, in the form
  `register` builds (a comment written by hand has another), and none for a beta; the
  release PR merged, never with GitHub's auto-merge, changing only `Project.toml` (its
  `version`), `CHANGELOG.md` and `BREAKING.md` (`REL7`), with the latest real run of each
  workflow on its head commit green, the gate among them; the tag on the merge commit, the
  GitHub release with notes, the registered tree equal to the tag's (`REL5`), General's
  PR merged; the release branch deleted. It only informs about the documentation of the
  tag (it never stops a release) and the jump over betas (`REL3`). Run it at the close of
  a release, or on one a colleague or another agent did. It cannot see *who* acted: a
  merge or a comment made by hand with the right content passes.

Exit codes: 0 ready or nothing to do (`audit`: the trail is complete), 1 blocked (`audit`: a
check failed), 2 usage error. Reports in Markdown, on
standard output and in the job summary.

## Where it is used

| Command | By |
| --- | --- |
| `gate`, `registrable` | [`release-gate.yml`](../workflows/release-gate.md) |
| `stable-release` | the action `add-ct-registry`, in `ci.yml`, `documentation.yml`, `breakage-suite.yml`, `breakage.yml` |
| `tag-plan` | [`release-tag.yml`](../workflows/release-tag.md) |
| `finish`, `register`, `register-beta`, `merge` | [`release.yml`](../workflows/release.md) |
| all | an agent following the recipe, or a person ([doing it by hand](https://github.com/control-toolbox/ct-agents/blob/main/guides/release.md#doing-it-by-hand)) |

## Tests

`scripts/release/test/runtests.jl`, run by `release-tests.yml` on Julia 1.10, 1.12 and
1.13: see [release-gate.md § Tests](../workflows/release-gate.md#tests).
