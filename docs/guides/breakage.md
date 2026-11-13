# Breakage: will my change break the packages that use mine?

[← Workflows of control-toolbox](../README.md)

For a developer of a control-toolbox package that other packages depend on. How to ask,
how to read the report, and what it means for a release. How to start a check on a pull
request in general: [the pull-request guide](pull-requests.md); why it is built so:
[design: breakage](../design/breakage.md).

## In short

- Add the label **`run breakage`** to your pull request. OptimalControl also has
  **`run breakage applications`**, for the applications and tutorials built on it.
- The suite tests **every package of the organization that loads yours**, each at its
  **latest** (default branch) and its **stable** (newest tag, a beta included), with your
  branch in place of your package.
- One comment on the pull request, kept up to date; a status `Breakage / packages` in the
  merge box; the table also in the run's summary.
- **A red cell does not fail the check.** Breaking a downstream package is allowed; then
  the next release must have a breaking number.

## Reading the report

| Column | Question it answers |
| --- | --- |
| **latest** | will the next version of that package, as it is on its `main`, still work with yours? |
| **stable** | will what users have installed of that package still work with yours? |

Each cell says the ref tested and the version of your package it resolved.

| You see | It means | What to do |
| --- | --- | --- |
| all ✅ | nothing downstream breaks | nothing |
| ❌ in **latest** only | the downstream `main` relies on something you change | coordinate: a pull request on that package, merged with or after yours |
| ❌ in **stable** | users of that package will break once you release | the release must be breaking (`REL1`); say it in the changelog's *Breaking changes* |
| ❌ also on `main` before your change | already broken, not by you | ignore for your pull request; the release report marks it ℹ️ |
| a package missing | it does not load yours in its `Project.toml` (or is excluded) | see [which packages are tested](../workflows/breakage-suite.md#which-packages-are-tested) |
| no comment, a fork | a fork's token cannot comment | read the run's summary |

## On a release pull request

The suite is evidence for the version number. It compares the **stable** column of the
release pull request with the run on its **base commit**:

| Stable on the base | Stable on the release | Verdict |
| --- | --- | --- |
| ✅ | ❌ | the release breaks this package: a non-breaking number **fails** the check |
| ❌ | ❌ | already broken: reported, counts for nothing |
| ✅ | ✅ | nothing |

It also fails when there is **no run on the base commit** (nothing to compare with) or when
cells have no result. The run on `main` after each merge is that baseline: keep the `push`
trigger, or run the suite by hand on `main` before a release.

## Setting up a package

1. `Breakage.yml` calling [`breakage-suite.yml`](../workflows/breakage-suite.md#caller), on
   `push` to `main` and `workflow_dispatch`, dispatched by `Labels.yml` for `run breakage`.
2. **No list of packages**: they are derived from the organization's `Project.toml` files.
   Declare in `targets` only what those files do not show: an application owned outside the
   organization, a documentation build (`"break": "doc"`).
3. A package with no consumer may keep `Breakage.yml`: the suite passes with an empty plan
   and starts testing the first package that loads it.
4. Two suites (packages, applications): call it twice with two `group`s; the second sets
   `consumers: false` and declares its `targets`.

To see what your package would get, from its checkout:

```bash
julia scripts/breakage/consumers.jl list --project Project.toml
```

## The pages behind it

| Subject | Page |
| --- | --- |
| The suite, its inputs, the consumers, the verdict | [`breakage-suite.yml`](../workflows/breakage-suite.md) |
| The baseline carried over a skipped run on `main` | [CI on `main`](../workflows/ci-on-main.md#the-breakage-baseline) |
| `REL1` | [ct-conventions](https://github.com/control-toolbox/ct-conventions/blob/main/rules/release.md) |
| Why it is built this way | [design: breakage](../design/breakage.md) |
