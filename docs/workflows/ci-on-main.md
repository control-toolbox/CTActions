# CI on `main`: the label `ci on main: changes only`

[← Workflows of control-toolbox](../README.md)

Every merge of a pull request is a push to `main`, and a push to `main` runs **everything**:
the tests (`ci.yml`), the coverage (`coverage.yml`), the breakage suite
(`breakage-suite.yml`) and the documentation (`documentation.yml`). That is the default, and
it stays the default: `main` must be green and the pull request was probably tested on one
runner only.

Sometimes it is wasted work: a pull request that only moves a pin in `AGENTS.md`, or that is
the formatter's. The label **`ci on main: changes only`**, set by hand on the pull request
before it is merged, asks for the economical run instead: **only the jobs that the merged
files can affect run on `main`.** Without the label nothing changes.

It is not a way to skip CI. It never skips a job whose inputs changed, it never applies
unless every condition below holds, and any doubt runs the job.

## The decision

A first job, `changes` (a call of [`guard.yml`](guard.md)), starts each of the four reusable
workflows. On a push to `main` it runs
[`scripts/ci-main/changes.jl`](../../scripts/ci-main/changes.jl), which answers `run=true` or
`run=false` for the job it guards; on any other event the script is not run and the guard
answers by itself (`true`, except for a pull request that is not open). The rules of the
script, **in this order**, stop at the first that applies:

| # | Situation | Answer |
| --- | --- | --- |
| 1 | not a push to `main` (a pull request, a tag, a manual run, the cron) | **run** |
| 2 | no merged pull request is found for the pushed commit | **run** |
| 3 | the pull request does not carry the label | **run** |
| 4 | the pull request is a release PR (its branch starts with `release/`) | **run** |
| 5 | the label was not set by an allowed login (see [Who may set it](#who-may-set-it)) | **run** |
| 6 | no earlier green run of this job on `main`, or the base is not an ancestor | **run** |
| 7 | the pull request is **formatting only** (see below) | **skip** |
| 8 | no file changed since the base can affect the job | **skip** |
| 9 | at least one can | **run** |

So the label is honoured only when it was set by the right person, on a pull request that is
not a release, and when there is a trustworthy point to compare with.

### The base: the last time the job really passed

The files compared are those changed **since the last run of this job on `main` in which it
ran and passed**, not since the previous commit. Two cases show why:

- If the tests failed on `main` and the next pull request, labelled, only touches the
  documentation, comparing with the previous commit would say "no source changed" and skip
  the tests, hiding the failure. Comparing with the last run where the tests *passed*, the
  failing change is in the diff, and the tests run.
- A job skipped by this very mechanism reports `success` without having tested anything. It
  must not become a base, or the base would move past changes that nobody tested. The script
  reads the **jobs** of each earlier run (`actions/runs/<id>/jobs`) and takes the latest run
  in which a matching job has the conclusion `success`; a run where it was `skipped` is
  passed over, and so is a run where it failed or was cancelled.

If there is no such run (a new repository, history rewritten, the base is not an ancestor of
the pushed commit), the job runs.

### What can affect a job

The changed files are matched against the job's scope, by path from the root of the
repository:

| Job | Scope | Runs if a changed file is in… |
| --- | --- | --- |
| tests (`ci.yml`) | `tests` | `src/`, `ext/`, `test/`, `Project.toml` |
| coverage (`coverage.yml`) | `coverage` | `src/`, `ext/`, `test/`, `Project.toml` |
| breakage (`breakage-suite.yml`) | `breakage` | `src/`, `ext/`, `Project.toml` |
| documentation (`documentation.yml`) | `docs` | `docs/`, `src/`, `ext/`, `Project.toml` |

Besides, a file never affects any job when it is a root file of documentation or
configuration: `*.md` (`AGENTS.md`, `CHANGELOG.md`, `README.md`…), `.gitignore`, `LICENSE`,
`CITATION.cff`, `_typos.toml`, `.markdownlint.json`, `.JuliaFormatter.toml`, `formatter.lock`.
A file in one of the known directories of another scope (`docs/` for the tests, `test/` for
the documentation) does not affect this one. **Anything else counts**: `.github/` (a
workflow change can change what runs), a new top-level directory, a file the script does not
know. When the script cannot tell, the job runs.

The documentation scope includes `src/` and `ext/` because the API pages are generated from
the docstrings.

### Formatting only

A pull request opened by the formatter workflow (`formatter.yml`, title
`[AUTO] JuliaFormatter.jl run`) changes whitespace and layout, never behaviour. With the
label, **nothing runs** (rule 7) when both hold:

- **every commit** of the pull request has the headline `Format .jl files`, and there is at
  least one;
- **every changed file** is a `.jl` file.

The second condition is a guard: a pull request that mixes the formatter's commit with
another change, or that touches a `.md` or a `.toml`, is not formatting only and goes
through the file rules above. The rule still needs the label, the allowed login and a green
base: it does not let anyone skip CI by choosing a commit message.

### The breakage baseline

A release PR compares its breakage report with the run of `breakage-suite.yml` on its **base
commit** (`REL1`): it downloads the artifact `breakage-<group>` of that run. A Breakage run
skipped on `main` would leave the next release PR without a baseline. So when the suite is
skipped, the job `carry-baseline` downloads the artifact of the base run (the last real one)
and uploads it again under the skipped run: the baseline is carried forward and a release PR
still finds it.

## Who may set it

Only the logins in the organization variable **`CT_CI_CHANGES_ONLY_ACTORS`**
(comma-separated, set under the organization's *Actions → Variables*), `ocots` when the
variable is empty. The script reads who last put the label on the pull request
(`issues/<n>/events`, event `labeled`) and compares; anyone else's label is ignored and
everything runs. The list is meant to grow one login at a time.

## Release pull requests

Never. A release PR (branch `release/v…`) is always tested in full on `main`: the label is
ignored (rule 4). The release recipe (`recipes/release.md` in ct-agents) does not add it.

## What the guarded workflows look like

Each of `ci.yml`, `coverage.yml`, `breakage-suite.yml` and `documentation.yml` starts with
the job `changes`, a call of [`guard.yml`](guard.md) with the scope and the id of the job it
guards. The guard also skips a pull request that is not open, which has nothing to do with the
label; on a push to `main` it checks out the repository (whole history) and CTActions, then
runs the composite action `.github/actions/changes-only`. Its first real job gets:

```yaml
needs: changes
if: ${{ !cancelled() && needs.changes.outputs.run != 'false' }}
```

Read it as: **run, unless `changes` said `false`.** For a pull request, a tag or a manual run
the guard answers `true` (except a pull request that is not open, see [guard.md](guard.md));
if `changes` fails, its output is empty and the job runs too (`!cancelled()` instead of the
default `success()` of a `needs`). The callers in each package do not change.

**Every job downstream of a guarded job needs the same care.** The default condition of a job
is `success()`, which is false when a job *anywhere upstream* was skipped, not only a direct
`needs`. A job that needs `build`, itself guarded and run, is skipped if a job above it was
skipped. The guard itself always runs for that reason (it has no `if`). A job that needs a job
that may be skipped by a rule carries `!cancelled()` and tests the result of the job it needs
(`needs.build.result == 'success'`) in its own `if`, as `break` and `select-gpu` do. Without
it, `breakage-suite.yml` ran no cell on a pull request (the former `changes` was skipped
outside a push to `main`), and the report failed with *no result* for every cell.

The composite action's outputs are `run`, `base_run` (the id of the run the diff started
from) and `reason`; the reason is also written to the job summary, one line per guarded job,
for example *since 1a2b3c4, no change can affect `test` (3 files, scope tests)*.

## Testing a change to this mechanism

The reusable workflows take an input `ctactions_ref` (default `main`): the ref of CTActions
whose scripts the `changes` job checks out. To try a branch of CTActions from a package,
point the caller at the workflow of the branch and pass the same ref:

```yaml
jobs:
  call:
    uses: control-toolbox/CTActions/.github/workflows/ci.yml@my-branch
    with:
      ctactions_ref: my-branch
```

The script has unit tests, on fakes of `gh` and `git` and on throwaway repositories
(`julia scripts/ci-main/test/runtests.jl`; the workflow `ci-main-tests.yml` runs them when
the scripts or the guarded workflows change).

## Limits

- A change that does not appear in the repository does not appear in the diff: a new release
  of a dependency in the registry. The weekly integration run (`CronIntegration.yml`)
  covers it.
- The label is per pull request, set before the merge. Adding it after the merge does
  nothing.
- A skipped `documentation.yml` does not redeploy the `dev` documentation for that commit.
  With the rules above that only happens when nothing the documentation is built from
  changed.
