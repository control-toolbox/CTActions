# Documentation: the choices

[← Workflows of control-toolbox](../README.md)

Why the documentation of a package is built and deployed the way it is. For the person who
maintains `documentation.yml` and `documentation-preview-cleanup.yml`. How to use them:
[the guide](../guides/documentation.md).

The failures and dates come from the commits and pages cited.

## The choices

### 1. Previews on request, removed on close

**Before**: `make.jl` hardcoded `push_preview=true`, so every pull request build deployed
`previews/PR<n>` to `gh-pages`, nobody removed them, and the branch grew.

**Chosen**: two labels with two roles. `run documentation` builds (does it still build?);
`documentation push preview` is a **modifier**, not a trigger: with the first, the build
also deploys. The workflow passes the decision to `make.jl` as `DOCUMENTER_PUSH_PREVIEW`.
`documentation-preview-cleanup.yml`, on the close of a pull request, removes the previews of
**every** pull request no longer open (so its first run cleared the backlog), in a normal
commit, never a force push, retried on a rejected push: a deployment running at the same
time is never lost.

**Cost**: `make.jl` must read the variable; a package that still hardcodes `true` ignores
it.

### 2. A dispatched build that Documenter takes for a pull request

Since the dispatch by label (CTActions#149), the build is a `workflow_dispatch`, and
Documenter deploys a preview only on a `pull_request` event. The workflow sets
`GITHUB_EVENT_NAME=pull_request` and `GITHUB_REF=refs/pull/<pr>/merge` for the build when it
has `pr` and `preview=true` (0aefac7), and posts the status `Documentation / preview` with
the link, which Documenter would otherwise post only on a real `pull_request` event.

**Cost**: a dependency on how Documenter reads its environment; a change there breaks the
previews, not the builds.

### 3. Publish, then upgrade on a GPU

Some examples are worth showing with real GPU output. A documentation job both builds and
deploys (`deploydocs` runs inside `make.jl`), so a single job cannot "try the GPU, fall back
to the CPU".

**Chosen** (2e2a6d5, 2026-09-02): `build` on GitHub's runners always runs first and
publishes; `build-gpu`, on `main` and tags only, starts once `build` has published and
redeploys with GPU output, with `continue-on-error`. Publishing never depends on a
self-hosted machine being online ([principle 7](../principles.md#7-in-doubt-the-safe-side)).

**Around it**: the same care as the GPU tests (`$OCCIDATA_GPU_RUN`, `TMPDIR`, a retry after
purging `compiled/`), plus re-running the build scripts of the docs environment, because a
persistent depot can miss a package's build output (88a63e6, KNITRO.jl's `deps/deps.jl`);
`gpu_runner: 'auto'` picks `kkt` unless offline (45cf317).

**Ordering**: an older run's `build-gpu`, finishing late, must not redeploy over a newer
`build`. The caller sets a `concurrency` group per ref that **queues** runs on `main`
(cancelling a Julia process on the self-hosted runner was seen to leave orphans) and
cancels on a pull request, where there is no GPU pass.

### 4. The docs of a tag, dispatched by the tag workflow

A tag created with `GITHUB_TOKEN` starts no workflow, so `release-tag.yml` dispatches
`Documentation.yml` on the tag (`workflow_dispatch` is allowed), and Documenter deploys a
tag on `workflow_dispatch`. A failed build is reported, not retried: the release is not
undone ([design of the release](https://github.com/control-toolbox/ct-agents/blob/main/design/release.md), choice 7).

### 5. `GITHUB_TOKEN`, not a deploy key

The deployment uses `GITHUB_TOKEN` (`contents: write` from the caller). `DOCUMENTER_KEY` is
declared optional and passed by no caller today (see
[Secrets](../conventions/secrets.md) and CTActions#100).

## Known limits

- `documentation.yml` has no test of its own: it is linted and exercised by every package's
  runs.
- A documentation run skipped on `main` by `ci on main: changes only` does not redeploy
  `dev` for that commit; it only happens when nothing the docs are built from changed.

## Timeline

| Date | Change | Answer to |
| --- | --- | --- |
| 2026-02-09 | inputs and secrets of the workflow (3537259) | — |
| 2026-09-02 | GPU upgrade pass, publish then upgrade (2e2a6d5) | GPU examples without risking the publication |
| 2026-10-15 | preview cleanup, concurrency of the docs (c078f09) | `gh-pages` growing; an old GPU pass over a new build |
| 2026-10-16 | rebuild the docs environment in `build-gpu` (88a63e6) | a build output missing from the persistent depot |
| 2026-10-20 | `gpu_runner: 'auto'` (45cf317) | `kkt` offline |
| 2026-11-10 | dispatched by label; preview as a `pull_request` for Documenter; status with the link (fd6610b, 0aefac7, 77f7981) | see [pull-request triggers](pull-request-triggers.md) |
