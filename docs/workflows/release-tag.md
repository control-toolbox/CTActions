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

A rerun does what is left and never tags twice. TagBot, later, finds the tag of a stable
already there.

**As the organization's App.** A tag created with `GITHUB_TOKEN` triggers no workflow, so
the documentation of the stable version would not deploy. The job mints a token of
[`control-toolbox-bot`](../conventions/github-app.md) for the repository, with
`contents: write` only; the App's secrets must be visible to the package (organization
settings, see [Extending it](../conventions/github-app.md#extending-it)).

## Caller

```yaml
# .github/workflows/ReleaseTag.yml
name: Release tag

on:
  push:
    branches: [main]
    paths: [Project.toml]
  workflow_dispatch:

jobs:
  call:
    uses: control-toolbox/CTActions/.github/workflows/release-tag.yml@main
    secrets:
      CT_APP_CLIENT_ID: ${{ secrets.CT_APP_CLIENT_ID }}
      CT_APP_PRIVATE_KEY: ${{ secrets.CT_APP_PRIVATE_KEY }}
```

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `ctactions_ref` | `'main'` | Ref of CTActions the script is checked out from |
