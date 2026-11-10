# label-dispatch.yml

[← Workflows of control-toolbox](../README.md)

Starts, for a label added to a pull request, the workflow of that label, and only that
one. Caller: `Labels.yml`, the same in every package.

## Why

The heavy workflows (`CI.yml`, `Documentation.yml`, `Breakage.yml`) used to listen to
`pull_request: labeled`. A label is not a filter of that event: **every label created a
run of each of them**, with the `if:` of the caller skipping the jobs. The guards
(see [Labels](../conventions/labels.md)) kept the run in progress alive, but the new run of
the same workflow, all jobs skipped, was the one the pull request page showed. The CI still
running was hidden behind it, and each label left about thirty skipped jobs in the Checks.

Now the heavy workflows do not listen to `pull_request`. They listen to
`workflow_dispatch`, and `label-dispatch.yml` dispatches them, one run per label:
runs started by different labels **accumulate** on the pull request, side by side.

Nothing is cancelled when a label is added: a run is cancelled only by a newer run of the
same workflow, the same target and the same pull request
([Superseded runs](superseded-runs.md)).

## What it dispatches

| Event | Dispatched |
| --- | --- |
| `labeled` | the workflow of the label just added; nothing for a label that starts nothing (`bug`) |
| `synchronize`, `reopened` | the workflow of **every** label the pull request carries |

| Label | Workflow | Inputs |
| --- | --- | --- |
| `run ci github-runner` | `CI.yml` | `target=github` |
| `run ci occidata-runner` | `CI.yml` | `target=occidata` |
| `run ci kkt-runner` | `CI.yml` | `target=kkt` |
| `run breakage` | `Breakage.yml` | `target=packages` |
| `run breakage applications` | `Breakage.yml` | `target=applications` |
| `run documentation` | `Documentation.yml` | `preview=true` or `false` |
| `documentation push preview` | modifier, see below | |

The mapping is in [`scripts/label-dispatch/plan.sh`](../../scripts/label-dispatch/plan.sh),
with its tests. Every dispatch also passes `pr`, the number of the pull request.

`documentation push preview` starts nothing alone. Added after `run documentation`, it
dispatches the documentation again, with `preview=true`.

Not dispatched: a pull request that is not open, and a pull request from a fork (its
branch cannot be dispatched, and its token is read-only). The job's summary says so.
`unlabeled` is not subscribed: removing a label does not cancel a run.

## In a package

```yaml
# .github/workflows/Labels.yml
name: Labels

on:
  pull_request:
    types: [labeled, synchronize, reopened]

jobs:
  call:
    permissions:
      contents: read
      actions: write
    uses: control-toolbox/CTActions/.github/workflows/label-dispatch.yml@main
```

```yaml
# .github/workflows/CI.yml: the other callers follow the same pattern
name: CI
run-name: "CI ${{ inputs.target }}${{ inputs.pr && format(' #{0}', inputs.pr) || '' }}"

on:
  push:
    branches: [main]
    tags: '*'
  workflow_dispatch:
    inputs:
      pr:
        description: 'Pull request number, set by label-dispatch.yml'
        required: false
        default: ''
      target:
        description: 'github, occidata or kkt'
        required: false
        default: ''

jobs:
  test-cpu-github:
    if: github.event_name == 'push' || inputs.target == 'github'
    uses: control-toolbox/CTActions/.github/workflows/ci.yml@main
    with: { ... }
```

A dispatched workflow **declares every input it is given** (`pr`; `target` for CI and
Breakage; `preview` for Documentation), or the dispatch fails with `Unexpected inputs`.
A `workflow_dispatch` by hand has no `pr`: for the breakage suite it is the run that
becomes the baseline of the next release PR, as before.

## What the reusable workflows do with `pr`

Inside a reusable workflow `github.event` is the caller's event, so `github.event.inputs.pr`
is readable without passing it through every caller.

- `ci.yml`, `documentation.yml`, `breakage-suite.yml`, `breakage.yml`: the concurrency
  group ends with the pull request number, and a run with `pr` is cancelled by a newer one
  of the same group.
- `breakage-suite.yml`: the base commit, the baseline and the comment come from the pull
  request read through the API.
- `documentation.yml`: `preview=true` sets `DOCUMENTER_PUSH_PREVIEW`, and the build runs
  with `GITHUB_EVENT_NAME=pull_request` and `GITHUB_REF=refs/pull/<pr>/merge`, which is
  what Documenter needs to deploy `previews/PR<pr>`. The GPU pass is skipped, as on any
  pull request.

## What changes in the run

- A dispatched run checks out the **head of the branch**, not the merge commit of the pull
  request (`refs/pull/<n>/merge`) that a `pull_request` run tests.
- The run belongs to the head commit, so it is in the pull request's checks, with the
  names of the callers' jobs. A branch protection that requires a check by name must be
  checked once a package has moved.
- A run is named by `run-name`, for example `CI kkt #42`.

## Testing a change

`label-dispatch-tests.yml` runs the tests of the mapping. The dispatch itself is tested on
a pull request of a package whose `Labels.yml` points to the branch of CTActions
(`label-dispatch.yml@<branch>`, with `ctactions_ref: <branch>`):

1. A label: one run, the one of the label, and a `Labels` run of a few seconds.
2. A second label while the first run goes on: both run, nothing is cancelled.
3. A push: each labelled workflow restarts once, the previous run is cancelled.
4. `bug`: nothing is dispatched.
5. `documentation push preview` after `run documentation`: the preview is deployed.
