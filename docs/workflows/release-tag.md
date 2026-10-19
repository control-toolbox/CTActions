# `release-tag.yml`: tag a merged release

[← Workflows of control-toolbox](../README.md)

Once a release PR is merged, tags its merge commit `vX.Y.Z` and creates the GitHub release
([`REL5`](https://github.com/control-toolbox/ct-conventions/blob/main/rules/release.md#rel5--version-tag-registry-and-github-release-agree)).
Caller: `ReleaseTag.yml`, in every package.

## What it does

On a push to `main` touching `Project.toml`, or by hand:

1. `release.jl tag-plan` reads the `version` of `Project.toml`. If `vX.Y.Z` is already
   tagged, there is nothing to do. Otherwise the target is the commit, on the first-parent
   history of `main`, that set this version — the merge commit of the release PR, even if
   other commits followed.
2. `gh release create vX.Y.Z --target <commit> --generate-notes`, with the notes since the
   previous **stable** for a stable (`--notes-start-tag`), since the previous release for a
   beta; a stable is `--latest`, a beta `--prerelease`.
3. The documentation workflow (`documentation_workflow`, `Documentation.yml` by default)
   is dispatched on the tag, so the documentation of the version is deployed.

A rerun does what is left and never tags twice. TagBot, later, finds the tag of a stable
already there.

**No credential but `GITHUB_TOKEN`.** A tag created with `GITHUB_TOKEN` triggers no
workflow, but `GITHUB_TOKEN` may dispatch one: the documentation runs with
`GITHUB_REF=refs/tags/vX.Y.Z`, and Documenter deploys a tag on `workflow_dispatch`. So the
caller only grants `contents: write` and `actions: write`, and its `Documentation.yml`
accepts `workflow_dispatch`. If the dispatch fails, the job fails; the tag is there, so a
rerun has nothing left to do: dispatch the documentation by hand
(`gh workflow run Documentation.yml --ref vX.Y.Z`).

## Caller

```yaml
# .github/workflows/ReleaseTag.yml
name: Release tag

on:
  push:
    branches: [main]
    paths: [Project.toml]
  workflow_dispatch:

permissions:
  contents: write
  actions: write

jobs:
  call:
    uses: control-toolbox/CTActions/.github/workflows/release-tag.yml@main
```

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `documentation_workflow` | `'Documentation.yml'` | The workflow run on the new tag; empty: none |
| `ctactions_ref` | `'main'` | Ref of CTActions the script is checked out from |
