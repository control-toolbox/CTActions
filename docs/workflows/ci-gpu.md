# `ci-gpu.yml`: the GPU tests on one runner, chosen at run time

[← Workflows of control-toolbox](../README.md)

`ci.yml` on a single self-hosted GPU runner: `kkt` unless it is offline, else `occidata`
([`select-gpu-runner.yml`](select-gpu-runner.md)). For pushes to `main` and tags, where
running the GPU tests on both runners only waits for the slower one. Pull requests keep
their per-runner labels (`run ci kkt-runner`, `run ci occidata-runner`), so `occidata`
stays available on demand.

| Input | Default | Meaning |
| --- | --- | --- |
| `versions` | `["1"]` | Julia versions (JSON array) |
| `use_ct_registry` | `false` | Add ct-registry |
| `test_args` | `''` | Forwarded to `ci.yml` (e.g. `GPU`, CTDirect.jl) |

Secrets: `SSH_KEY` (ct-registry), `RUNNERS_STATUS_TOKEN` (see
[`select-gpu-runner.yml`](select-gpu-runner.md#the-secret-runners_status_token)).

The caller is the `test-gpu-main` job of [Split CI](ci.md#split-ci). Its jobs appear as
`test-gpu-main / test / test (1, kkt)`; it has no label guard, so the release gate treats
it as an ordinary job (it is skipped on a PR).
