# Running the checks of a pull request

[← Workflows of control-toolbox](../README.md)

For a developer of a control-toolbox package: what runs on your pull request, how to ask
for the rest, where to see the results, and what happens when it is merged. The pages of
each mechanism are linked at the end; why it is built this way is in
[design: pull-request triggers](../design/pull-request-triggers.md).

## In short

- **Cheap checks run by themselves** on every pull request: spell check, the release gate,
  the labels workflow.
- **Expensive checks run when you add their label**: the tests, the documentation, the
  breakage of the downstream packages. One label, one run.
- **A push restarts what your labels asked for**, and cancels the run of the previous
  commit.
- **Results are commit statuses** in the merge box (`CI / github`, `Documentation`,
  `Breakage / packages`), each linking to its run, not entries of the *Checks* tab.
- **On `main` everything runs** after the merge, unless a maintainer set
  `ci on main: changes only` on the pull request.

## Asking for a check

| You want | Add the label | Runs |
| --- | --- | --- |
| the tests on GitHub's runners (Linux, macOS, Windows) | `run ci github-runner` | `CI.yml`, target `github` |
| the tests on a GPU | `run ci occidata-runner` or `run ci kkt-runner` | `CI.yml` on that runner |
| the documentation build | `run documentation` | `Documentation.yml` |
| … and its preview online | `documentation push preview` too (alone it does nothing) | the documentation again, deployed to `previews/PR<n>` |
| whether the packages that depend on yours still pass | `run breakage` (`run breakage applications` in OptimalControl) | `Breakage.yml` |

Labels are spelled the same in every repository; a repository defines only those it uses
([the vocabulary](../conventions/labels.md#the-vocabulary)). A label that starts nothing
(`bug`) dispatches nothing.

**Order does not matter, and labels do not compete**: two labels give two runs, side by
side; adding one never cancels another's run.

## What you see

- In the **merge box**: one commit status per dispatched run, `pending` then `success`,
  `failure` or `error` (cancelled), linking to the run. With a preview, a second status
  `Documentation / preview` links to it.
- In the **Actions** tab: runs named `CI github #42`, `Documentation #42`, …
- A short `Labels` run, a few seconds, for each label event: it is the dispatcher.
- **Not** in the *Checks* tab: GitHub lists there only the runs of the pull request's own
  events, and these runs are dispatched. A branch protection requiring a check by name
  does not see them.

A dispatched run tests **the head of your branch**, not the merge with `main` that a
`pull_request` run would test. Keep the branch up to date before relying on it.

## Running again

| Situation | What to do |
| --- | --- |
| You pushed a commit | nothing: every labelled workflow restarts once, the previous run is cancelled |
| A run failed for an external reason (a runner, the network) | *Re-run* the run, or remove and re-add its label |
| You want to stop asking for a check | remove its label: later pushes no longer start it (the run in progress is not cancelled) |
| The pull request was closed and reopened | the labelled workflows run again on reopening |

Labels added or removed **while the pull request is closed** start nothing past a first
job of a few seconds ([guard](../workflows/guard.md)): do not close a pull request to
label it quietly.

## After the merge

The merge is a push to `main`, and a push to `main` runs **everything**: the tests on every
runner the package calls, the coverage, the breakage suite (which also becomes the baseline
of the next release), the documentation deployed as `dev`.

**`ci on main: changes only`** asks for less: set on the pull request **before** the merge,
by a login of `CT_CI_CHANGES_ONLY_ACTORS`, it makes `main` run only the jobs the merged
files can affect (a pin moved in `AGENTS.md`, a formatter pull request). It never skips a
job whose inputs changed, it is ignored on a release pull request, and any doubt runs the
job ([details](../workflows/ci-on-main.md)).

## From a fork

A pull request from a fork is not dispatched (its branch cannot be, and its token is
read-only). A maintainer who wants the expensive checks pushes the branch to the
repository and labels a pull request opened from there. Cheap checks run as usual; see
[pull requests from a fork](../conventions/secrets.md#pull-requests-from-a-fork).

## Setting up a package

1. `Labels.yml`, calling [`label-dispatch.yml`](../workflows/label-dispatch.md#in-a-package)
   on `pull_request: [labeled, synchronize, reopened]`.
2. `CI.yml`, `Documentation.yml`, `Breakage.yml` on `push` (and tags) and
   `workflow_dispatch`, **without** `pull_request`, declaring the inputs they are given
   (`pr`; `target` for CI and Breakage; `preview` for Documentation), their jobs guarded on
   `inputs.target` ([CI caller](../workflows/ci.md#caller)).
3. The labels they use, created in the repository
   ([creating the labels](../conventions/labels.md#creating-the-labels)): a label missing
   on either side fails silently.
4. A package whose CI scope depends on labels (`test <env> backend`) names them in
   `Labels.yml` (`restart_labels`, `restart_prefix`) and subscribes it to `unlabeled`.

A package still on the older model (`pull_request` in `CI.yml` with an `if:` on the
labels) keeps working; see [Labels](../conventions/labels.md#the-guard) for the rules of
that model.

## When nothing happens

| Symptom | Likely cause |
| --- | --- |
| A label added, no run | the label is spelled differently from the vocabulary, or missing from the package's `Labels.yml` mapping; the pull request is closed; it comes from a fork (the `Labels` run's summary says so for these two) |
| The dispatch fails with `Unexpected inputs` | the called workflow does not declare an input it is given (`pr`, `target`, `preview`) |
| A run but no status in the merge box | the caller does not give `statuses: write` to the job that calls the reusable workflow |
| The run finished but the pull request shows an old result | look at the status, not the *Checks* tab |
| Everything ran on `main` despite `changes only` | the label was set by a login not in `CT_CI_CHANGES_ONLY_ACTORS`, after the merge, on a release PR, or there was no green base: the job summary gives the reason |

## The pages behind it

| Mechanism | Page |
| --- | --- |
| Label → workflow, the dispatch | [`label-dispatch.yml`](../workflows/label-dispatch.md) |
| The commit statuses | [label-dispatch: status of a dispatched run](../workflows/label-dispatch.md#status-of-a-dispatched-run) (`pr-status.yml`) |
| The first job of each heavy workflow: run or not | [`guard.yml`](../workflows/guard.md) |
| A push cancels the previous run | [Superseded runs](../workflows/superseded-runs.md) |
| `ci on main: changes only` | [CI on `main`](../workflows/ci-on-main.md) |
| The label vocabulary, the older `pull_request` model | [Labels](../conventions/labels.md) |
| Why it is built this way | [design: pull-request triggers](../design/pull-request-triggers.md) |
