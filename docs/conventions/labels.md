# Labels: opt-in triggers on pull requests

[← Workflows of control-toolbox](../README.md)

Running the full matrix (CI on several OSes and GPU runners, breakage against every
downstream package, a documentation build) on every push to every PR is slow and
wasteful. Expensive workflows are therefore **opt-in per pull request, through a label**,
and always run on `push` to `main` and on tags, so that `main` stays green.

## The guard

The caller guards its job with:

```yaml
jobs:
  call:
    if: >
      github.event_name != 'pull_request' ||
      (github.event.action == 'labeled' && github.event.label.name == 'run ci github-runner') ||
      (github.event.action != 'labeled' && contains(github.event.pull_request.labels.*.name, 'run ci github-runner'))
    uses: control-toolbox/CTActions/.github/workflows/ci.yml@main
```

Read it as: **always run outside pull requests** (push, tag), and **on a pull request,
only when the label is present.** Add the label to a PR when you want that check; remove
and re-add it to re-trigger.

**Why two branches instead of a single `contains(...)`.** A `labeled` event fires once
*per label added*, and each firing re-evaluates the PR's *current, full* label set. If a
PR already carries `run ci github-runner` and you add an unrelated label (`bug`), that
`labeled` event still passes a plain `contains(...)` check and re-runs CI for nothing.
Gating the `labeled` branch on `github.event.label.name` (the label *just* added) fixes
that: only adding the trigger label itself starts a run. Other events (`synchronize`,
`reopened`) have no "label that fired", so they fall back to `contains(...)`.

## The `types:` list, without `opened`

The `if:` guard is half the gate. The other half is which pull-request events the caller
subscribes to. For a label-gated workflow:

```yaml
on:
  pull_request:
    types: [labeled, synchronize, reopened]   # NOT `opened`
```

**`opened` is not just redundant but harmful.** Applying a label while opening a PR
(`gh pr create --label …`, or picking labels in the web form) emits **two** events,
`opened` **and** `labeled`. With `opened` in the list, both pass the guard and the
workflow runs **twice on the same commit**; on a self-hosted GPU runner that is a
duplicated job for nothing (measured on CTFlows.jl#354: two runs created at `20:04:59`
and `20:05:00`).

**Dropping it loses nothing:**

| Situation | Event that fires | Covered without `opened`? |
| --- | --- | --- |
| PR opened **with** the label | `labeled` | ✅ `labeled` fires even when the label is set at creation |
| PR opened **without** the label | `opened` only | ✅ nothing should run; the guard would reject it anyway |
| Label added later | `labeled` | ✅ |
| New commits pushed | `synchronize` | ✅ |

**Keep `reopened`.** Reopening a closed PR does not re-emit `labeled`, so a PR that still
carries its label would never re-run without it.

**Prefer this to `concurrency: cancel-in-progress`.** A concurrency group would also
collapse the duplicate, but it cancels a *running* job, and on the self-hosted GPU runner
cancelling a Julia process was seen to leave an orphan process (`Terminate orphan
process: pid (julia)`) and a very slow next run. Not subscribing to the useless event has
no such side effect. (A documentation caller with a GPU pass does use a concurrency
group, for another reason: see [documentation.yml](../workflows/documentation.md#ordering-the-deployments).)

**The rule is for guarded, opt-in workflows only.** Workflows that are not label-gated
keep `opened`, and some exist only for it: `AddToProject.yml` uses `types: [opened]` and
`AutoAssign.yml` `types: [opened, reopened]`. Formatter and SpellCheck set no `types:`
at all, which is right for a cheap GitHub-hosted check.

So the test is simple: **does the job carry a `contains(… .labels.*.name, …)` guard?** If
yes, `types: [labeled, synchronize, reopened]`; if not, whatever events the job needs.

## The vocabulary

Labels are the user-facing trigger surface, so their names are **the same in every
repository**: someone applying a label from habit in a sibling repository, or scripting
across the organization, must not find that it silently does nothing here. A repository
chooses *which* labels it defines, never *how they are spelled*.

| Label | Triggers | Used in (2026-10-16) |
| --- | --- | --- |
| `run ci github-runner` | `ci.yml` on GitHub-hosted runners | every core package |
| `run ci occidata-runner` | `ci.yml` on the self-hosted `occidata` GPU runner | OptimalControl, CTParser, CTDirect, CTFlows, CTSolvers, CTLie |
| `run ci kkt-runner` | `ci.yml` on the self-hosted `kkt` GPU runner | CTFlows, CTSolvers |
| `run breakage` | `breakage.yml` against downstream **packages** | every package with downstream packages |
| `run breakage applications` | `breakage.yml` against downstream **applications and tutorials** | OptimalControl |
| `run documentation` | `documentation.yml` on the PR | every package with a documentation site |
| `documentation push preview` | **Modifier, not a trigger**: with `run documentation`, the PR build also deploys its preview (`previews/PR<n>`); alone it does nothing ([details](../workflows/documentation.md#pr-previews)) | every package with a documentation site |
| `run probe` | the capability probes (`CPUProbe.yml`, `GPUProbe.yml`, [details](../workflows/per-repo.md#probes)) | CTFlows, CTSolvers |

**CI labels are named after the runner, not the workload:** `run ci <runner>-runner`.
The GitHub-hosted job is not "the CPU job", it is the job on GitHub's runners; the others
are defined by the machine they land on. The label, the `runs_on` value and the job name
then say the same thing, and a new runner gets its label without inventing a new
adjective.

Deprecated spellings, to rename wherever they remain (see
[Recipes](../recipes.md#rename-a-label-across-the-organization)): `run ci` (single job),
`run ci cpu` / `run ci gpu`, `run GPU`, and the bare `github-runner` / `kkt-runner` /
`occidata-runner`.

> On CTParser.jl's `main` (2026-10-16), `CI.yml` still guards on `github-runner` and
> `kkt-runner` while the repository's labels are `run ci github-runner` and
> `run ci occidata-runner`; CTParser.jl#326 (waiting for merge) aligns the guards.

## Creating the labels

Labels are defined per repository. When you bootstrap one, create those its callers
reference:

```bash
gh label create "run ci github-runner" --color 78f620 --description "Trigger CI on GitHub-hosted runners"
gh label create "run documentation" --description "Build the documentation on this PR"
```

A label used in a guard but missing from the repository (or the other way round) fails
silently: nothing runs. Workflows that are not PR-gated (scheduled, push-only) need no
label.
