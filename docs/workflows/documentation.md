# `documentation.yml`: build and deploy the documentation

[← Workflows of control-toolbox](../README.md)

Builds the documentation (`docs/make.jl`, Julia 1.12, `ubuntu-latest`) and deploys it to
`gh-pages`. Optionally, a second pass on a self-hosted GPU runner redeploys it with real
GPU output. On a PR, the build runs only with the `run documentation` label, and deploys
a preview only with `documentation push preview`. Caller: `Documentation.yml`, in every
package with a documentation site.

## Caller

```yaml
# .github/workflows/Documentation.yml
name: Documentation

on:
  push:
    branches: [main]
    tags: '*'
  pull_request:
    types: [labeled, synchronize, reopened]

jobs:
  call:
    # `run documentation` is the only trigger; adding the preview label to a PR that
    # already has it re-runs the build
    if: >
      github.event_name != 'pull_request' ||
      (contains(github.event.pull_request.labels.*.name, 'run documentation') &&
        (github.event.action != 'labeled' ||
         github.event.label.name == 'run documentation' ||
         github.event.label.name == 'documentation push preview'))
    uses: control-toolbox/CTActions/.github/workflows/documentation.yml@main
    with:
      use_ct_registry: true
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}
```

## Inputs and secrets

| Input | Default | Meaning |
| --- | --- | --- |
| `use_ct_registry` | `false` | Add `ct-registry` (needs `SSH_KEY`) |
| `gpu_runner` | `''` | Labels of a self-hosted GPU runner for the upgrade pass (JSON array, e.g. `'["occidata"]'`); empty disables it |
| `gpu_timeout_minutes` | `120` | Timeout of the upgrade pass; budget for a cold build |

| Secret | |
| --- | --- |
| `SSH_KEY` | for `ct-registry` |

The deployment uses `GITHUB_TOKEN`; `DOCUMENTER_KEY` is read but not declared (see the
note in [Secrets](../conventions/secrets.md)).

## PR previews

Deploying a preview of every PR build fills `gh-pages` with `previews/PR<n>` directories
nobody looks at. The workflow therefore passes `DOCUMENTER_PUSH_PREVIEW` to `make.jl`:
`"true"` only on a PR carrying the `documentation push preview` label (inside a reusable
workflow `github.event` is the caller's event, so the PR's labels are visible). The
caller's `make.jl` reads it:

```julia
# docs/make.jl
DocumenterVitepress.deploydocs(;
    repo=repo_url * ".git",
    devbranch="main",
    push_preview=get(ENV, "DOCUMENTER_PUSH_PREVIEW", "false") == "true",
)
```

`run documentation` alone builds the docs on the PR without deploying anything; with
`documentation push preview` as well, the build deploys the preview; the preview label
alone does nothing. A `make.jl` that still hardcodes `push_preview=true` ignores the
variable. Previews are removed once the PR is closed, by
[`documentation-preview-cleanup.yml`](documentation-preview-cleanup.md).

## GPU upgrade pass

With `gpu_runner` set, a second job `build-gpu` runs on that runner, on push and tags only
(never on a PR):

- `build` (GitHub-hosted) always runs first and deploys, unchanged: publishing never
  depends on a self-hosted box being online;
- `build-gpu` starts only once `build` has published (`needs: build`), and with
  `continue-on-error: true` it never fails the workflow: on success it redeploys the same
  site with real GPU output; on failure or a long SLURM queue, the published site stays.

This is *publish then upgrade*, not *attempt GPU then fall back*: a documentation job both
builds and deploys (`deploydocs` runs inside `make.jl`), so a single job cannot fall back,
and putting a self-hosted box on the critical path of publishing would be a reliability
regression. `build-gpu` runs its builds through `$OCCIDATA_GPU_RUN`, moves `TMPDIR`
off the node's `/tmp`, re-runs the build scripts of the docs environment (a persistent
depot can miss a package's build output, e.g. KNITRO.jl's `deps/deps.jl`), and retries
once after purging `compiled/`.

Used by OptimalControl.jl (`gpu_runner: '["occidata"]'`, `gpu_timeout_minutes: 180`,
CTActions#71, OptimalControl.jl#885) and CTSolvers.jl (`gpu_runner: '["kkt"]'`).

### Ordering the deployments

With a GPU pass, an older run's `build-gpu`, finishing long after a newer `build`, must
not redeploy older content over it. A concurrency group per ref queues the runs; on a PR
(no GPU pass) cancelling the older run is safe and saves time:

```yaml
# .github/workflows/Documentation.yml of a caller that sets gpu_runner
concurrency:
  group: documentation-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

While a run is in progress, GitHub keeps only the newest pending run of the group: a
burst of merges builds the first and the last commit. Tags carry their own ref and never
wait for `main`. Queuing rather than cancelling on `main` avoids killing a Julia process
on the self-hosted runner (see [Labels](../conventions/labels.md#the-types-list-without-opened)).
