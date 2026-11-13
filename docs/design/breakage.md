# Breakage: the choices

[← Workflows of control-toolbox](../README.md)

Why the downstream packages are tested the way they are. For the person who maintains
`breakage-suite.yml` or `scripts/breakage`. How to use it: [the guide](../guides/breakage.md);
how it behaves: [`breakage-suite.yml`](../workflows/breakage-suite.md).

The failures and dates come from the commits cited and from the pages of the workflows.

## The question

control-toolbox is a stack: CTBase under CTModels, CTParser, CTDirect, CTFlows, CTSolvers,
all under OptimalControl, with applications and tutorials on top. A change at the bottom
can break any layer above, and the package's own tests cannot see it. Breakage answers
*"if I merge this, do the packages that use mine still pass?"*, and, at a release, *"is the
version number honest about it?"*

## The choices

### 1. One report, not a comment per cell

**Before**: `breakage.yml`, called once per matrix cell by the package's caller. Each cell
rewrote the pull request's comment with the results present at that moment, so the last
one to write could post an incomplete table, and the comment was found by the bot's id.

**Chosen** (a6eb887, 2026-10-18): `breakage-suite.yml`, three stages in one workflow:
`plan` (the cells), `break` (one job per cell, each writing its result as a file),
`report` (once: the table, the summary, an artifact `breakage-<group>`, one comment found by
its marker `<!-- ct-breakage:<group> -->`). The verdict is computed by a script
(`scripts/breakage/report.jl`), tested, from files ([principle 2](../principles.md#2-yaml-wires-scripts-decide)).

**Cost**: two workflows coexist until every caller has moved (CTActions#162).

### 2. Consumers derived, by uuid, from every place a package can be loaded

**Before**: each caller listed its downstream packages in a matrix, by hand. A new package
that started to load CTBase was tested only once someone remembered to add it.

**Chosen** (02fc2b1, 2026-10-19): `scripts/breakage/consumers.jl` reads the `Project.toml`
files of the organization's packages (default branch, at the time of the run) and keeps
those that load the package under test, by **uuid** (a rename does not lose a consumer), in
`[deps]`, `[weakdeps]` (an extension), `[extras]` and `test/Project.toml` (its tests).
Archived repositories and forks are left out; an `EXCLUDED` list names the others, each
with its reason ([principle 4](../principles.md#4-facts-not-memory-derive-do-not-list)).

**Kept by hand**: what no `Project.toml` shows, declared in `targets`: an application
outside the organization, a documentation build.

**Cost**: a run reads every package of the organization through the API; if the
organization cannot be read, `plan` fails and nothing runs (never an empty list mistaken
for "no consumer"). Conversely, a package with no consumer gets an **empty plan that
passes** (66c741a), so that it can keep its `Breakage.yml` and pick up its first consumer
without a change.

### 3. Two columns: latest and stable

**latest** (the consumer's default branch) warns early: the next release of that package
would break. **stable** (its newest tag, a beta included) is what users have: the column
that decides a version number. Only **stable** counts for `REL1`; a ❌ in latest is for
coordination.

### 4. A breaking change is allowed; a dishonest number is not

A downstream failure **never fails the check by itself**: breaking a consumer is
sometimes the point. On a release pull request, the report compares the stable column with
the run on the **base commit**: ✅ then ❌ means the release breaks that package, and a
non-breaking number fails. A package already failing on the base counts for nothing.

**Why compare with the base and not just read the release's column**: a consumer can be
broken for reasons unrelated to the release (a new dependency, its own bug); only a change
of state is evidence about the release.

**In doubt, fail** ([principle 7](../principles.md#7-in-doubt-the-safe-side)): no run on the
base commit, or cells without a result, fail a release pull request instead of passing
blind. Hence the run on every push to `main`, the baseline of the next release, and, when
`ci on main: changes only` skips it, the job `carry-baseline` that copies the last real
artifact forward ([ci on main](../workflows/ci-on-main.md#the-breakage-baseline)).

### 5. ct-registry kept on a stable release

The CI of a stable release pull request leaves ct-registry out, so that the package
resolves from General alone (`REL4`). Breakage keeps it (`skip_on_stable: 'false'`): the
**consumers** may need betas of their own, and the question here is theirs, not the
release's installability.

### 6. Robust to the rest of the machinery

- Forks (2a9c091): the suite runs, the report stays in the run's summary (a fork's token
  cannot comment).
- The guard job always runs (8c24a34, 9bd0a24): a skipped `changes` job had skipped every
  `break` cell of a pull request, and the report failed with *no result* everywhere
  ([pull-request triggers § 5](pull-request-triggers.md#5-one-guard-job-which-always-runs)).
- Dispatched by label since 2026-11-10, with a commit status `Breakage / <group>`.

## Known limits

- The `Project.toml` files are read on the default branch at the time of the run: a package
  that starts to load yours appears as *a new target, no result on the base* on the first
  release pull request after.
- `plan` and `break` are exercised by the callers only; the scripts (`consumers.jl`,
  `report.jl`) have tests, including the ecosystem as read on 2026-10-19.

## Timeline

| Date | Change | Answer to |
| --- | --- | --- |
| before 2026-10 | `breakage.yml`, a matrix listed in each caller, a comment per cell | — |
| 2026-10-18 | `breakage-suite.yml`: one report, the `REL1` check of a release (a6eb887) | incomplete tables; no check of the number |
| 2026-10-19 | consumers derived from the `Project.toml` files (02fc2b1) | consumers forgotten in the lists |
| 2026-10-20 | forks run the suite (2a9c091) | 403 on the comment |
| 2026-10-21 | the `break` jobs run on a pull request (8c24a34); `guard.yml` (9bd0a24); the baseline carried over (eac188e) | a skipped job skipping the whole suite; a release without baseline |
| 2026-11-07 | nothing to test is an empty plan (66c741a) | a package with no consumer failing |
| 2026-11-10 | dispatched by label, a commit status | see [pull-request triggers](pull-request-triggers.md) |
| 2026-11-13 | `breakage.yml` removed, its last caller (CTAppTemplate.jl) moved | #162 |
