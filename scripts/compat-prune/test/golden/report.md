<!-- ct-compat-prune -->

Audit of the `[compat]` entries of the control-toolbox packages, by the [`compat-prune`](https://github.com/control-toolbox/CTActions/blob/main/.github/workflows/compat-prune.yml) workflow on 2026-10-15 19:48 UTC ([run](https://github.com/example-org/Root.jl/actions/runs/1)), for Julia 1.10, 1.12, 1.13. This body is rewritten by every run: do not edit it.

A prune drops `[compat]` specifiers that no environment selects, on no Julia version, and leaves every resolved manifest (joint, tests and docs of every package) unchanged. PRs can therefore be merged in any order, and need no release of their own.

## Audit

| Julia | environments resolved |
| --- | --- |
| 1.10 | 3 / 4 (failed: joint) |
| 1.12 | 4 / 4 |

9 multi-specifier `[compat]` entries examined: 4 with lanes to prune, 1 rejected, 2 blocked, 1 kept (every lane in use), 1 idle (resolved nowhere they apply), 1 withheld.

Registries: General (tree aff17d8a1e3e), ct-registry (commit 0123456789ab).

<details><summary>Entries left as they are (2)</summary>

| entry | compat | status | why |
| --- | --- | --- | --- |
| Alpha `test/Project.toml` `Gpu` | `5, 6` | idle | not resolved where the entry applies |
| Beta `Project.toml` `Dep3` | `0.9, 1` | keep | every lane in use: 1.2.0 on 1.12; 0.9.4 on 1.10 |

</details>

## Summary

|  | entries |
| --- | --- |
| to prune (open PRs) | 3 |
| merged, awaiting release | 1 |
| drift (not edited) | 1 |
| rejected by validation | 1 |
| withheld | 1 |
| blocked (information) | 2 |

## To prune

### Alpha — https://github.com/example-org/Alpha.jl/pull/12

| file | dependency | before | after | selected |
| --- | --- | --- | --- | --- |
| `Project.toml` | `Dep1` | `0.5, 0.6, 0.7` | `0.6, 0.7` | 0.7.2 on 1.12; 0.6.4 on 1.10 |
| `test/Project.toml` | `Tool` | `1, 2` | `2` | 2.0.0 on 1.10, 1.12 |

### Beta

| file | dependency | before | after | selected |
| --- | --- | --- | --- | --- |
| `Project.toml` | `Dep1` | `0.6, 0.7` | `0.7` | 0.7.2 on 1.12 |

## Merged, awaiting release

| entry | after |
| --- | --- |
| Beta `Project.toml` `Tool` | `2` |

## Drift

The default branch differs from the registered version: not edited.

| entry | audited | detail |
| --- | --- | --- |
| Alpha `docs/Project.toml` `Doc` | `0.8, 0.9` | `0.9, 1` on the default branch, `0.8, 0.9` audited |

## Rejected

| entry | where | reason |
| --- | --- | --- |
| Beta `Project.toml` `Weak` | Beta/test@1.10 | manifest differs: A 1.0.0 → 1.1.0 \| odd second line |

## Withheld

Baseline failed in joint@1.10: lanes used there are unknown.

| entry | would drop |
| --- | --- |
| Alpha `Project.toml` `Dep2` | `1` |

## Blocked

The newest specifier is never selected: information only, nothing is edited.

| entry | newest | capped by |
| --- | --- | --- |
| Alpha `docs/Project.toml` `Doc` | `1` | Beta, Documenter |
| Beta `Project.toml` `Weak` | `0.2` | resolver preference |

## Audited versions

| package | version | repository |
| --- | --- | --- |
| Alpha | 0.3.1 | [example-org/Alpha.jl](https://github.com/example-org/Alpha.jl) |
| Beta | 1.2.0-beta | [example-org/Beta.jl](https://github.com/example-org/Beta.jl) |
