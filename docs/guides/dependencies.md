# Dependencies: `[compat]` widened by CompatHelper, pruned once a month

[← Workflows of control-toolbox](../README.md)

For a developer of a control-toolbox package: what the two bots do to your `[compat]`
entries, and what to do with their pull requests. The detailed reasoning of the prune is in
[`compat-prune.md` § Why](../workflows/compat-prune.md#why) and
[§ How it decides](../workflows/compat-prune.md#how-it-decides).

## In short

| Bot | When | Pull request | What you do |
| --- | --- | --- | --- |
| [CompatHelper](../workflows/compat-helper.md) | daily, in each package | adds a new release of a dependency **next to** the old ones (`JET = "0.9, 0.11, 0.12"`) | label it (`run ci github-runner`, …): the CI tests it with the newest versions allowed; merge when green |
| [`[compat]` prune](../workflows/compat-prune.md) | monthly (1st, 04:00 UTC), from CTActions, for the whole organization | `ct/compat-prune`, by `ct-prune-compat[bot]`: drops the specifiers no supported Julia version selects any more, anywhere in the ecosystem | review the table, merge as it is; **nothing to release**; push nothing to its branch |

Everything the prune decided is in one tracking issue of CTActions, `[compat] prune
report`: what was pruned, what drifted, what was rejected, what caps a newest specifier
([reading the report](../workflows/compat-prune.md#reading-the-report)).

## Why two bots

- **Widen without dropping** (`KeepEntry()`): a new release is added, the old ones kept, so
  that a package keeps working with what its users may be pinned to.
- **Old specifiers cannot be dropped from inside one package**: whether `JET 0.9` is still
  used depends on what Julia 1.10 selects, and on the test and docs environments of every
  other package. Only an audit of the whole ecosystem, on every supported Julia, can say.
- **A prune is proved, not guessed**: it is kept only if every resolved manifest stays
  identical. So it changes no version anyone gets, the pull requests can be merged in any
  order, and none needs a release.
- **In doubt, nothing** ([principle 7](../principles.md#7-in-doubt-the-safe-side)): an
  environment that fails to resolve withholds every prune of that run.
- **One identity for the organization**: the prune writes to several repositories, so it
  acts as the App `ct-prune-compat`, whose pull requests run the CI
  ([GitHub Apps](../conventions/github-app.md)).

## When to look closer

| You see | Meaning |
| --- | --- |
| A CompatHelper pull request red on Julia 1.10 only | the newest versions are not forced there (Pkg would pick versions that need a newer Julia); the failure is real on 1.10 |
| A prune pull request with **drift** | the default branch changed since the registered version; it resolves itself after the next release |
| **Blocked** in the report | the newest specifier of an entry is never selected, capped by the packages listed: lift the cap upstream if it matters |
| **Withheld** | an environment did not resolve; fix it, then run the prune by hand |

## Setting up a package

`CompatHelper.yml` calling [`compat-helper.yml`](../workflows/compat-helper.md), with the
`subdirs` that have a `Project.toml`. For the prune to audit a new package: add it to the
`packages` default of `compat-prune.yml` and to the installation of `ct-prune-compat`
([recipes](../recipes.md#a-new-repository), step 13).
