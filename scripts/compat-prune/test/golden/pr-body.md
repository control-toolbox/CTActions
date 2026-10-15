<!-- ct-compat-prune -->

Drops the `[compat]` specifiers that no supported Julia version selects, in any
environment of the control-toolbox packages (joint, tests and docs of every package).
Without them every audited manifest is unchanged: this PR changes no version that
these environments resolve, needs no release of its own, and can be merged in any
order with the PRs of the other packages.

| file | dependency | before | after | selected |
| --- | --- | --- | --- | --- |
| `Project.toml` | `Dep1` | `0.5, 0.6, 0.7` | `0.6, 0.7` | 0.7.2 on 1.12; 0.6.4 on 1.10 |
| `docs/Project.toml` | `Doc` | `0.9, 1` | `1` |  |

Opened by the [`compat-prune`](https://github.com/control-toolbox/CTActions/blob/main/.github/workflows/compat-prune.yml) workflow (tracking issue: https://github.com/example-org/Root.jl/issues/100, [audit run](https://github.com/example-org/Root.jl/actions/runs/1)). The branch is rewritten by every run: push nothing to it.
