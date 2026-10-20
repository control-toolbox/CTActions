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

Secrets: `SSH_KEY` (ct-registry), `CT_RUNNERS_CLIENT_ID` and `CT_RUNNERS_PRIVATE_KEY` (see
[`select-gpu-runner.yml`](select-gpu-runner.md#the-github-app-ct-runners)).

The caller is the `test-gpu-main` job of [Split CI](ci.md#split-ci). Its jobs appear as
`test-gpu-main / test / test (1, kkt)`; it has no label guard, so the release gate treats
it as an ordinary job (it is skipped on a PR).

## Scheduled and manual runs

Nothing in `ci-gpu.yml` is specific to a push: any workflow can call it, for example a
weekly integration run (`test_args: 'cron'`), so that it too takes `kkt` unless it is
offline, else `occidata`. CTFlows.jl's `CronIntegration.yml` does it; a package adding such
a cron copies the job:

```yaml
  test-gpu:
    uses: control-toolbox/CTActions/.github/workflows/ci-gpu.yml@main
    with:
      use_ct_registry: true
      test_args: 'cron'
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}
      CT_RUNNERS_CLIENT_ID: ${{ secrets.CT_RUNNERS_CLIENT_ID }}
      CT_RUNNERS_PRIVATE_KEY: ${{ secrets.CT_RUNNERS_PRIVATE_KEY }}
```

The package's repository must be allowed to read the organization secrets
`CT_RUNNERS_*` (organization settings → Secrets → *Repository access*).
