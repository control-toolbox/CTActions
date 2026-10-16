# `documentation-preview-cleanup.yml`: remove stale previews

[← Workflows of control-toolbox](../README.md)

Removes from `gh-pages` the documentation preview (`previews/PR<n>`) of **every** pull
request that is no longer open. Caller: `DocPreviewCleanup.yml`, in every package that
deploys previews ([`documentation.yml`](documentation.md#pr-previews)).

## Caller

```yaml
# .github/workflows/DocPreviewCleanup.yml
name: Documentation preview cleanup

on:
  pull_request:
    types: [closed]
  workflow_dispatch:

jobs:
  call:
    # A PR from a fork gets a read-only token, and its build never deployed a preview.
    if: >
      github.event_name == 'workflow_dispatch' ||
      github.event.pull_request.head.repo.full_name == github.repository
    permissions:
      contents: write
      pull-requests: read
    uses: control-toolbox/CTActions/.github/workflows/documentation-preview-cleanup.yml@main
```

No inputs, no secrets: it uses `GITHUB_TOKEN`, hence the caller's `permissions:`.

## What it does

- Skips a repository with no `gh-pages` branch.
- For each `previews/PR<n>`, reads the PR's state; removes the preview when the PR is not
  open, keeps it (with a warning) when the state cannot be read.
- Removes them in one normal commit, never a force push, so a deployment running at the
  same time is never lost; a rejected push is rebased and retried (3 attempts).
- One cleanup at a time per repository (concurrency group).

Because it removes every stale preview, not only the closed PR's, the first run also
clears the backlog left by `push_preview=true`; `workflow_dispatch` runs it on demand.
