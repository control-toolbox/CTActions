# Pull-request triggers: the choices

[← Workflows of control-toolbox](../README.md)

Why the checks of a pull request are started the way they are: labels, a dispatcher,
commit statuses, a guard job, cancellation of superseded runs, and a reduced run on `main`.
For the person who maintains these workflows or wonders why five mechanisms answer what
looks like one question. How to use them: [the guide](../guides/pull-requests.md); how each
behaves: the pages it links to.

The failures and dates come from the runs, issues and commits cited. The alternatives
*set aside* in choices 1 and 3 were not recorded at the time: they are written afterwards,
to make the reasoning explicit.

## The problem

A package's full check is costly: tests on three OSes and up to two GPU runners (six jobs of
30 to 50 minutes, GPU runners that are few and shared), the breakage of every downstream
package, a documentation build of twenty minutes. Running all of it on every push of every
pull request is slow for the developer and blocks the runners for everyone. Running too
little lets a failure reach `main`.

The answer has two halves that never change: **on a pull request, the developer chooses
what runs; on `main` and on tags, everything runs**
([principle 6](../principles.md#6-expensive-is-opt-in-main-runs-everything)). Every
mechanism below exists because a simpler version of one of these halves failed in a way
that was observed.

## The chain

```
label added ──► Labels.yml ──► label-dispatch.yml ──► workflow_dispatch of CI / Documentation / Breakage
                                  (plan.sh: label → workflow)          │
                                                                       ├─ concurrency: a newer run of the same PR cancels it
                                                                       ├─ guard.yml: run, unless the PR is closed (or, on main, changes-only says no)
                                                                       └─ pr-status.yml: a commit status, pending → result
merge ──► push to main ──► the same workflows, everything, unless `ci on main: changes only` (scripts/ci-main)
```

## The choices

### 1. Labels, not paths or comments

**Chosen**: a label per check, named after where it runs (`run ci <runner>-runner`), the
same spelling in every repository.

**Set aside.**
- *`paths:` filters*: they decide from the files, not from what the developer needs; a
  change of `src/` would always start the GPU runs. The file-based decision is kept for
  `main` only, where it is safe to be conservative (choice 6).
- *Comment commands* (`/run ci`): a bot to run, comments to parse, and no visible state on
  the pull request; a label shows at a glance what was asked.
- *Run everything, cancel by hand*: the runners are busy before anyone cancels.

**Cost.** Labels must exist in each repository and be spelled exactly; a label missing on
one side fails silently. Hence one vocabulary for the organization
([Labels](../conventions/labels.md#the-vocabulary)).

### 2. A dispatcher, not `pull_request: labeled` in each workflow

**First model** (until 2026-11-10): `CI.yml`, `Documentation.yml`, `Breakage.yml` listened
to `pull_request: [labeled, synchronize, reopened]` and guarded their jobs with an `if:`
on the labels. Two refinements came from measurements:
- the `if:` reads **the label just added** on `labeled`, so that adding `bug` to a pull
  request carrying `run ci github-runner` does not rerun the CI;
- `opened` is **not** in the `types:` list: a pull request opened with a label emits
  `opened` and `labeled`, and the GPU job ran twice (CTFlows.jl#354).

**What still failed.** A label is not a filter of the event: **every label created a run of
each of the three workflows**, its jobs skipped by the `if:`. The pull request page showed
that latest run, all skipped, and hid the CI still running behind it; each label left about
thirty skipped jobs in the Checks.

**Chosen** (CTActions#149): the heavy workflows no longer listen to `pull_request`.
`Labels.yml` calls `label-dispatch.yml`, which maps the label to a workflow
(`scripts/label-dispatch/plan.sh`, tested) and starts it with `workflow_dispatch`, passing
`pr` and a `target`. One label, one run; runs of different labels accumulate side by side.

**Cost.**
- A dispatched run is **not in the Checks tab** nor in the checks a branch protection can
  require: GitHub lists there only the runs of the pull request's own events. Hence choice 3.
- It tests the **head of the branch**, not the merge commit `refs/pull/<n>/merge`.
- Every dispatched workflow must declare every input it is given, or the dispatch fails.
- A fork's pull request cannot be dispatched.
- Two models coexist until every package has moved; the older one is documented in
  [Labels](../conventions/labels.md#the-guard).

### 3. Commit statuses, to see the dispatched runs

**Chosen**: `pr-status.yml`, called at the start and the end of `ci.yml`,
`documentation.yml`, `breakage-suite.yml` when the run has `pr`, posts a commit status per
run (`CI / kkt`, `Documentation`, `Breakage / packages`), plus `Documentation / preview`
linking to the preview, which Documenter posts only on a `pull_request` event.

**Set aside**: the Checks API (a check run belongs to the App that creates it, and
`GITHUB_TOKEN` cannot attach one to another workflow's run in a way the pull request lists).

**Cost.** The calling job needs `statuses: write`; without it, the run works but shows
nowhere on the pull request.

### 4. Cancel superseded runs, in the callee, per pull request

**Chosen**: a `concurrency` group in the four reusable workflows, ending with the pull
request number, `cancel-in-progress` on a pull request only. A push cancels the run of the
previous commit; nothing else is cancelled; on `main`, a tag, a schedule, the group is the
run itself, so nothing is cancelled or queued.

**Set aside.**
- *In the callers*: under the first model, a run whose calling job was skipped (a label
  that changes nothing) entered the group and cancelled the tests in progress. In the
  callee, a run enters the group only when it really runs.
- *For every event*: `main` needs one result per commit (coverage, the deployed `dev`
  documentation, the breakage baseline of the next release).

**Why not cancel more.** Cancelling a Julia process on the self-hosted GPU runner was seen
to leave an orphan process and a slow next run: not subscribing to a useless event
(`opened`, choice 2) is preferred to cancelling its run.

**Cost.** Groups must keep apart what must not cancel each other: the caller's name, the
runner (`runner_type`, `runs_on`), the breakage group. A group shared by a caller and its
callee deadlocks, hence the `ctactions-` prefix.

### 5. One guard job, which always runs

**Chosen**: `guard.yml`, the first job of `ci.yml`, `coverage.yml`, `breakage-suite.yml`
and `documentation.yml`, answers *do the jobs below run?*: no for a pull request that is
not open; on `main`, what choice 6 decides; yes otherwise. Its downstream jobs use
`!cancelled() && needs.changes.outputs.run != 'false'`.

**Why.** A label event runs a pull request's workflows **even when it is closed**: closing
CTBase#636 and re-adding its labels started 21 runs in a minute. And the answer was about
to be repeated in four workflows.

**Why it always runs.** A skipped job makes every job downstream of it, however far,
skipped under the default `success()`: the former `changes` job, skipped outside `main`,
skipped the whole breakage suite of a pull request. A guard that fails outputs nothing,
which is not `'false'`: a broken guard never hides a test
([principle 7](../principles.md#7-in-doubt-the-safe-side)).

### 6. On `main`, everything, with one opt-out that cannot hide a failure

**Chosen**: everything runs on a push to `main`. The label `ci on main: changes only`, set
before the merge, makes `main` run only the jobs the merged files can affect
(`scripts/ci-main/changes.jl`, tested). It is honoured only when: set by a login of
`CT_CI_CHANGES_ONLY_ACTORS`; not a release pull request; there is a green base for that
job. Files are compared with **the last run where the job ran and passed**, not with the
previous commit; anything the script does not know counts as a change.

**Why the base is the last green run.** Comparing with the previous commit would let a
documentation-only merge skip the tests after a failing one, and a skipped job (which
reports success) would move the base past untested changes.

**Why opt-in and restricted.** It saves runners on merges that change nothing that runs (a
pin in `AGENTS.md`, a formatter pull request), but it is a way to run less on `main`: the
decision stays with a few maintainers, one pull request at a time.

**Cost.** A skipped breakage run would leave the next release without a baseline: the job
`carry-baseline` copies the last real one forward. A skipped documentation does not
redeploy `dev` for that commit.

## What it costs, all together

Five mechanisms where the first model had one `if:`. Each is small, tested or
self-checking, and answers a failure that was seen; together they are hard to hold in one's
head, which is what [the guide](../guides/pull-requests.md) and this page are for. The
simplification left is to retire the first model once every package has `Labels.yml`:
then the `if:` guards on labels, the `types:` rule and the coexistence notes go.

## Timeline

| Date | Change | Answer to |
| --- | --- | --- |
| 2026-10 | label vocabulary named after runners; `opened` dropped from `types:` | labels spelled differently per repository; double GPU runs (CTFlows.jl#354) |
| 2026-10-21 | `ci on main: changes only` (eac188e); `guard.yml`, skip a closed pull request (9bd0a24) | full runs of trivial merges; 21 runs on a closed pull request (CTBase#636) |
| 2026-11-05 | superseded runs cancelled in the reusable workflows (a0b7ed9) | runs of an old commit occupying the GPU runners |
| 2026-11-10 | `label-dispatch.yml` (CTActions#149), `pr-status.yml` | skipped runs hiding the CI in progress; dispatched runs invisible on the pull request |
| 2026-11-11 | restart labels (`restart_labels`, `restart_prefix`) | a CI scope chosen by label (OptimalControlProblems.jl) |
