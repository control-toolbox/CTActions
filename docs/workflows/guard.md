# `guard.yml`: whether the jobs below run

[← Workflows of control-toolbox](../README.md)

The first job of [`ci.yml`](ci.md), [`coverage.yml`](coverage.md),
[`breakage-suite.yml`](breakage-suite.md) and [`documentation.yml`](documentation.md), in the
job `changes`. It answers one question, *do the jobs that follow run?*, so that the four
workflows do not repeat the answer. It is not called by a package.

## The rules

In this order, the first that applies wins:

| # | Situation | `run` |
| --- | --- | --- |
| 1 | a **pull request that is not open**: a label added or removed while it is closed (or merged) | **false** |
| 2 | a push to `main`: the label `ci on main: changes only` decides, see [ci-on-main.md](ci-on-main.md) | `true` or `false` |
| 3 | anything else: an open pull request, a tag, a manual run, the cron | `true` |

Rule 1 exists because **a label event runs the workflows of a pull request whether it is open
or not**. Measured on CTBase#636: closing the pull request, removing and re-adding its four
labels started 21 runs in a minute, among them a full CI, a breakage suite and two
documentation builds. Closing a pull request to add its labels quietly does not work, and
reopening it ran everything a second time. With rule 1 the runs of a closed pull request stop
at this job, a few seconds, and only the reopening runs the tests (the pull request is open
then).

## The job always runs

The job has no `if`. That is deliberate: a job that is skipped makes every job *downstream of
it, however far*, skipped too under the default condition `success()`, even when a job in
between ran. The previous job `changes`, skipped outside a push to `main`, did exactly that to
`break` in `breakage-suite.yml`. With a job that always runs, a downstream job can use the
usual condition:

```yaml
needs: changes
if: ${{ !cancelled() && needs.changes.outputs.run != 'false' }}
```

Read it as: **run, unless the guard said `false`.** If the guard itself fails its output is
empty, not `'false'`, and the job runs: a broken guard never hides a test.

## Calling it

```yaml
changes:
  permissions:
    contents: read
    pull-requests: read
    actions: read
  uses: control-toolbox/CTActions/.github/workflows/guard.yml@main
  with:
    scope: tests        # tests, coverage, breakage or docs
    job: test           # the id of the guarded job: test, coverage, break, build
    ctactions_ref: ${{ inputs.ctactions_ref }}
    actors: ${{ vars.CT_CI_CHANGES_ONLY_ACTORS }}
```

| Input | Default | Meaning |
| --- | --- | --- |
| `scope` | required | What the guarded job tests (rule 2) |
| `job` | required | Id of the guarded job, as it appears in the names of the jobs of the run (rule 2) |
| `ctactions_ref` | `main` | Ref of CTActions whose scripts rule 2 runs |
| `actors` | `''` | Logins allowed to set the label; empty means the default list of the script |

| Output | |
| --- | --- |
| `run` | `'true'` or `'false'` |
| `base_run` | Id of the run the diff started from (rule 2), empty otherwise |
| `reason` | Why, one line (also in the job summary) |

## Testing a change

`guard-tests.yml` calls the guard on a pull request of CTActions and checks that `run` is
`true` when the pull request is open. To see rule 1, add a label to a **closed** pull request
that changes the guard: the same workflow then expects `false`.

The `uses:` of the four callers points at `guard.yml@main`, and a `uses:` cannot take an
expression: the guard of a branch is not used by `ci.yml@my-branch` unless that branch pins
`guard.yml@my-branch` in the four callers. To try a change of the guard from a package, pin it
in a commit of the branch, and drop that commit before merging.
