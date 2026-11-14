# The documentation of a package: build, preview, deploy

[← Workflows of control-toolbox](../README.md)

For a developer of a control-toolbox package with a documentation site. How to check the
docs of a pull request, how to see a preview, what is deployed when. Why it is built so:
[design: documentation](../design/documentation.md).

## In short

| You want | Do | Result |
| --- | --- | --- |
| to know the docs still build | label `run documentation` | a build, nothing deployed; status `Documentation` |
| to see them online | `run documentation` **and** `documentation push preview` | the build deploys `previews/PR<n>`; status `Documentation / preview` with the link |
| the `dev` docs updated | merge to `main` | built and deployed as `dev` |
| the docs of a version | the tag of a release | built on the tag by [`release-tag.yml`](../workflows/release-tag.md), deployed as `vX.Y.Z` and `stable` |

`documentation push preview` alone does nothing; added after `run documentation`, it
rebuilds with the preview. The preview is removed once the pull request is closed.

## What to know

- Built on `ubuntu-latest`, Julia 1.12, from `docs/make.jl`; deployed to `gh-pages` with
  `GITHUB_TOKEN`.
- `make.jl` must read the preview from the environment, never hardcode it:

  ```julia
  push_preview = get(ENV, "DOCUMENTER_PUSH_PREVIEW", "false") == "true"
  ```

- A preview is built from **the head of your branch** (a dispatched run), not from its
  merge with `main`.
- The API pages are generated from the docstrings: a change to `src/` can break the docs,
  which is why `ci on main: changes only` counts `src/` for the documentation.
- A failed documentation build of a **tag** does not undo the release: rerun it
  (`gh workflow run Documentation.yml --ref vX.Y.Z`).

## Docs with real GPU output

OptimalControl.jl and CTSolvers.jl publish examples run on a GPU. Their `Documentation.yml`
sets `gpu_runner` (`'auto'`: `kkt` if online and idle, else `occidata` if online and idle,
else no GPU pass for that run): on `main` and tags, after the normal build has **already
published**, a second job rebuilds on the GPU runner and redeploys. If it fails, waits too
long or finds no idle runner, the published site stays. Never on a pull request. Such a caller also sets a `concurrency` group per ref, so that an older GPU pass
never redeploys over a newer build ([ordering the deployments](../workflows/documentation.md#ordering-the-deployments)).

## Setting up a package

1. `Documentation.yml` calling [`documentation.yml`](../workflows/documentation.md#caller),
   on `push` (and tags) and `workflow_dispatch` with the inputs `pr` and `preview`.
2. `docs/make.jl` reading `DOCUMENTER_PUSH_PREVIEW`.
3. `DocPreviewCleanup.yml` calling
   [`documentation-preview-cleanup.yml`](../workflows/documentation-preview-cleanup.md).
4. The labels `run documentation` and `documentation push preview`, and `Labels.yml`
   ([the pull-request guide](pull-requests.md#setting-up-a-package)).

## When something goes wrong

| Symptom | Likely cause |
| --- | --- |
| The build passed but no preview | `documentation push preview` missing; `make.jl` does not read `DOCUMENTER_PUSH_PREVIEW`; a pull request from a fork (no deployment) |
| The preview link is a 404 for a minute | GitHub Pages publishing after the push to `gh-pages` |
| `gh-pages` full of old previews | `DocPreviewCleanup.yml` missing; run it by hand once, it clears every stale preview |
| The GPU pass failed on `main` | nothing is lost: the site from the normal build stays; see the run of `build-gpu` |

## The pages behind it

| Subject | Page |
| --- | --- |
| The workflow, previews, the GPU pass, ordering | [`documentation.yml`](../workflows/documentation.md) |
| Removing previews | [`documentation-preview-cleanup.yml`](../workflows/documentation-preview-cleanup.md) |
| The docs of a tag | [`release-tag.yml`](../workflows/release-tag.md) |
| The GPU runners | [the testing guide](testing.md), [Runners](../conventions/runners.md) |
| Why it is built this way | [design: documentation](../design/documentation.md) |
