# Superseded runs of a pull request

[← Workflows of control-toolbox](../README.md)

On a pull request, a push starts the CI, the documentation and the breakage suite again.
Without the rule below the runs of the previous commit would go on to the end although
nobody needs them: six test jobs of 30 to 50 minutes per run, GPU runners that are scarce,
and a result that arrives later because the runners are busy.

**A new run of a pull request cancels the previous run of the same workflow on the same
pull request.** Nothing else is ever cancelled.

## Where it is declared

In the reusable workflows, at the level of the workflow:

| Workflow | Group |
| --- | --- |
| `ci.yml` (also reached through `ci-gpu.yml`) | `ctactions-ci-<caller>-<runner_type>-<runs_on>-<pull request>` |
| `documentation.yml` | `ctactions-documentation-<caller>-<pull request>` |
| `breakage-suite.yml` | `ctactions-breakage-suite-<caller>-<group>-<pull request>` |
| `breakage.yml` | `ctactions-breakage-<caller>-<pkgname>-<pkgpath>-<pkgbreak>-<pkgversion>-<pull request>` |

```yaml
concurrency:
  group: ctactions-ci-${{ github.workflow }}-${{ inputs.runner_type }}-${{ inputs.runs_on }}-${{ github.event.pull_request.number || github.run_id }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

- **`<caller>`** is `github.workflow`, the name of the *calling* workflow: the CI, the
  documentation and the breakage of one pull request do not cancel each other.
- **`runner_type` and `runs_on`** keep apart the calls of one caller workflow. CTFlows.jl
  calls `ci.yml` for the GitHub-hosted, `kkt` and `occidata` runners in one `CI.yml`: three
  runs of the same pull request that must not cancel one another.
- **`<pull request>`** is the number of the pull request. On any other event (a push to
  `main`, a tag, a schedule, a manual run) it is `github.run_id`, so the group is the run
  itself: **nothing is cancelled and nothing waits.** This matters: a group shared by
  pushes to `main` with `cancel-in-progress: false` would queue them and drop the pending
  ones, and `main` must have one result per commit (coverage, deployed documentation).
- **The prefix `ctactions-…`** differs from every group of a caller. A caller and a callee
  in the same group wait for each other for ever.

## Runs started by a label

A run started by [`label-dispatch.yml`](label-dispatch.md) is a `workflow_dispatch` with
the input `pr`. For these four workflows it counts as a run of that pull request: the
group ends with `github.event.inputs.pr`, and `cancel-in-progress` is on. A push cancels
the run of each labelled workflow, a label never cancels the run of another one: their
groups differ by workflow and, in `ci.yml`, by runner.

## Why not in the callers

The package workflows run on label events (`labeled`, `unlabeled`) and guard their calling
job with an `if`. A label that changes nothing (`bug`, or `run ci github-runner` which also
starts the documentation and the breakage) creates a run whose calling job is skipped. A
`concurrency` in the caller would be entered by that run and cancel the tests in progress.
In the callee it is entered only when the calling job really runs.

## What is not cancelled

- Runs on `main` and on tags.
- `release-tag`, `compat-prune`, `documentation-preview-cleanup`, `update-readme`, the
  release gate, TagBot and CompatHelper: serialized where it matters (`cancel-in-progress:
  false`), or cheap.
- The runs of an older commit when you read a release: `release.jl ready` and `merge` look
  at the head commit only.

A label that matters (a scope label such as `test JuMP backend`, or `run ci github-runner`
when the CI was off) starts a run that cancels the previous one of the pull request, which
is the intended effect: what runs has changed.

## Testing a change

The rule cannot be seen on a single run. Use a pull request of a package whose callers
point to the branch of CTActions (`uses: control-toolbox/CTActions/.github/workflows/ci.yml@<branch>`):

1. Two pushes in a row: the first run is cancelled, the second runs.
2. A label that changes nothing during a run: nothing is cancelled.
3. Calls of one caller workflow with different `runs_on`: not cancelled by each other.
4. A push to `main`: never cancelled.

`ci-gpu.yml` calls `ci.yml@main`, so the GPU runs follow `main`'s `ci.yml`.
