# `dispatch.yml`: central PR gate and label dispatcher

[← Workflows of control-toolbox](../README.md)

Centralizes the evaluation of pull-request events, labels, and repository configuration
(`.github/ci.toml`). Caller: `Dispatcher.yml`, in every package.

## The problem it solves

In earlier configurations, each package declared `on: pull_request: types: [labeled, synchronize, reopened]`
across multiple workflows (`CI.yml`, `Documentation.yml`, `Breakage.yml`, `ReleaseGate.yml`).
Adding multiple labels consecutively on an open pull request triggered duplicate runs for every workflow,
spawned uncontrolled parallel test runners on the same commit, and caused race conditions where older runs
overwrote or cancelled newer ones.

`dispatch.yml` and the caller `Dispatcher.yml` address this by:

1. **Exiting in `< 2s` on closed pull requests**:
   When following the `recipes/release.md` pattern (`close PR` → `add labels` → `reopen PR`),
   label events on the closed pull request terminate immediately without checking out code or scheduling jobs.
2. **Exiting in `< 2s` on unrelated labels**:
   Issue or pull request metadata labels (such as `bug`, `enhancement`, `flaky`) exit immediately and
   never enter the cancellation group, ensuring active test jobs are not aborted.
3. **Debouncing rapid label additions on open pull requests**:
   Consecutive label events on an open pull request enter `concurrency: group: pr-dispatch-<PR>` with
   `cancel-in-progress: true`. A short debounce window allows rapid label changes to cancel superseded runs,
   querying the live state and dispatching the complete set of required jobs in a single run.
4. **Declarative configuration via `.github/ci.toml`**:
   Repository-specific arguments (`versions`, `runs_on`, `test_args`, `fail_fast`, `targets`, `gpu_runner`)
   are declared once in `.github/ci.toml`, keeping `Dispatcher.yml` uniform across all repositories.

## Declarative configuration (`.github/ci.toml`)

```toml
# .github/ci.toml — repository CI configuration
use_ct_registry = true

[ci.github]
enabled = true
label = "run ci github-runner"
versions = ["1.10", "1.13"]
runs_on = ["ubuntu-latest", "macos-latest", "windows-latest"]
test_args = ""
fail_fast = true
# Optional hooks:
scope_script = ""
scope_test_dirs = []
upload_artifact_path = ""
upload_artifact_name = ""
smoke_test = false

[ci.occidata]
enabled = false
label = "run ci occidata-runner"
versions = ["1"]
runs_on = [["occidata"]]
test_args = ""
run_on_push = false

[ci.kkt]
enabled = false
label = "run ci kkt-runner"
versions = ["1"]
runs_on = [["kkt"]]
test_args = ""

[ci.gpu_main]
enabled = false
versions = ["1"]
test_args = ""

[documentation]
enabled = true
label = "run documentation"
preview_label = "documentation push preview"
gpu_runner = ""
gpu_timeout_minutes = 120

[breakage.packages]
enabled = true
label = "run breakage"
consumers = true
versions = ["latest", "stable"]
targets = []

[breakage.applications]
enabled = false
label = "run breakage applications"
consumers = false
versions = ["latest", "stable"]
targets = []

[release_gate]
enabled = true
julia_lowest = "1.10"
```

## Caller (`.github/workflows/Dispatcher.yml`)

```yaml
name: Dispatcher

on:
  pull_request:
    types: [opened, labeled, unlabeled, synchronize, reopened]

concurrency:
  group: ${{ (github.event_name == 'pull_request' && github.event.pull_request.state == 'open' && (github.event.action != 'labeled' && github.event.action != 'unlabeled' || startsWith(github.event.label.name, 'run ') || github.event.label.name == 'documentation push preview' || github.event.label.name == 'release')) && format('pr-dispatch-{0}', github.event.pull_request.number) || format('pr-dispatch-ignore-{0}', github.run_id) }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' && github.event.pull_request.state == 'open' && (github.event.action != 'labeled' && github.event.action != 'unlabeled' || startsWith(github.event.label.name, 'run ') || github.event.label.name == 'documentation push preview' || github.event.label.name == 'release') }}

jobs:
  dispatch:
    if: >-
      github.event_name != 'pull_request' ||
      (github.event.pull_request.state == 'open' &&
       (github.event.action != 'labeled' && github.event.action != 'unlabeled' ||
        startsWith(github.event.label.name, 'run ') ||
        github.event.label.name == 'documentation push preview' ||
        github.event.label.name == 'release'))
    uses: control-toolbox/CTActions/.github/workflows/dispatch.yml@main

  release-gate:
    needs: dispatch
    if: needs.dispatch.outputs.run_release_gate == 'true'
    uses: control-toolbox/CTActions/.github/workflows/release-gate.yml@main
    with:
      julia_lowest: ${{ needs.dispatch.outputs.release_gate_julia_lowest }}

  test-cpu-github:
    needs: dispatch
    if: needs.dispatch.outputs.run_ci_github == 'true'
    uses: control-toolbox/CTActions/.github/workflows/ci.yml@main
    with:
      versions: ${{ needs.dispatch.outputs.ci_github_versions }}
      runs_on: ${{ needs.dispatch.outputs.ci_github_runs_on }}
      runner_type: 'github'
      use_ct_registry: ${{ needs.dispatch.outputs.use_ct_registry == 'true' }}
      test_args: ${{ needs.dispatch.outputs.ci_github_test_args }}
      fail_fast: ${{ needs.dispatch.outputs.ci_github_fail_fast == 'true' }}
      upload_artifact_path: ${{ needs.dispatch.outputs.ci_github_upload_artifact_path }}
      upload_artifact_name: ${{ needs.dispatch.outputs.ci_github_upload_artifact_name }}
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}

  test-gpu-occidata:
    needs: dispatch
    if: needs.dispatch.outputs.run_ci_occidata == 'true'
    uses: control-toolbox/CTActions/.github/workflows/ci.yml@main
    with:
      versions: ${{ needs.dispatch.outputs.ci_occidata_versions }}
      runs_on: ${{ needs.dispatch.outputs.ci_occidata_runs_on }}
      runner_type: 'self-hosted'
      use_ct_registry: ${{ needs.dispatch.outputs.use_ct_registry == 'true' }}
      test_args: ${{ needs.dispatch.outputs.ci_occidata_test_args }}
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}

  test-gpu-kkt:
    needs: dispatch
    if: needs.dispatch.outputs.run_ci_kkt == 'true'
    uses: control-toolbox/CTActions/.github/workflows/ci.yml@main
    with:
      versions: ${{ needs.dispatch.outputs.ci_kkt_versions }}
      runs_on: ${{ needs.dispatch.outputs.ci_kkt_runs_on }}
      runner_type: 'self-hosted'
      use_ct_registry: ${{ needs.dispatch.outputs.use_ct_registry == 'true' }}
      test_args: ${{ needs.dispatch.outputs.ci_kkt_test_args }}
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}

  documentation:
    needs: dispatch
    if: needs.dispatch.outputs.run_documentation == 'true'
    uses: control-toolbox/CTActions/.github/workflows/documentation.yml@main
    with:
      use_ct_registry: ${{ needs.dispatch.outputs.use_ct_registry == 'true' }}
      gpu_runner: ${{ needs.dispatch.outputs.documentation_gpu_runner }}
      gpu_timeout_minutes: ${{ fromJSON(needs.dispatch.outputs.documentation_gpu_timeout_minutes) }}
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}
      CT_RUNNERS_CLIENT_ID: ${{ secrets.CT_RUNNERS_CLIENT_ID }}
      CT_RUNNERS_PRIVATE_KEY: ${{ secrets.CT_RUNNERS_PRIVATE_KEY }}

  breakage-packages:
    needs: dispatch
    if: needs.dispatch.outputs.run_breakage_packages == 'true'
    uses: control-toolbox/CTActions/.github/workflows/breakage-suite.yml@main
    with:
      group: packages
      use_ct_registry: ${{ needs.dispatch.outputs.use_ct_registry == 'true' }}
      consumers: ${{ needs.dispatch.outputs.breakage_packages_consumers == 'true' }}
      versions: ${{ needs.dispatch.outputs.breakage_packages_versions }}
      targets: ${{ needs.dispatch.outputs.breakage_packages_targets }}
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}

  breakage-applications:
    needs: dispatch
    if: needs.dispatch.outputs.run_breakage_applications == 'true'
    uses: control-toolbox/CTActions/.github/workflows/breakage-suite.yml@main
    with:
      group: applications
      use_ct_registry: ${{ needs.dispatch.outputs.use_ct_registry == 'true' }}
      consumers: ${{ needs.dispatch.outputs.breakage_applications_consumers == 'true' }}
      versions: ${{ needs.dispatch.outputs.breakage_applications_versions }}
      targets: ${{ needs.dispatch.outputs.breakage_applications_targets }}
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}
```

## Inputs and outputs

| Input | Default | Meaning |
| --- | --- | --- |
| `config` | `'.github/ci.toml'` | Path to the repository CI configuration file |
| `debounce_seconds` | `5` | Sleep duration on `labeled`/`unlabeled` events to debounce rapid changes |
| `ctactions_ref` | `'main'` | Ref of CTActions whose scripts are used |

The outputs include all `run_*` booleans (`'true'` or `'false'`) and all configured arguments
forwarded to downstream reusable workflows.
