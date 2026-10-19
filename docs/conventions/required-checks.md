# Required checks and aggregators

[← Workflows of control-toolbox](../README.md)

The checks of `main` that a pull request must pass before it is merged, by a human or by
auto-merge. They are what makes a release safe: with them required and auto-merge on, a
release PR that breaks a rule cannot be merged, whoever drives it (see
[`release-gate.yml`](../workflows/release-gate.md)).

## One check per theme, with a stable name

A required check is named after its job, and a matrix or a split CI names its jobs after
their parameters (`test-cpu-github (1.10, ubuntu-latest)`, …): the list would change with
every matrix. So each caller workflow ends with one **aggregator** job, which needs
every other job of the workflow, and only it is required. Each has its own name: two
checks of the same name would make the requirement ambiguous.

| Required check | Workflow | Covers |
| --- | --- | --- |
| `call / gate` | `ReleaseGate.yml` | `REL1`–`REL7` on a release PR; passes at once otherwise |
| `ci-ok` | `CI.yml` | every CI job: GitHub-hosted, `kkt`, `occidata`, smoke tests |
| `docs-ok` | `Documentation.yml` | the build, and the GPU pass if any |
| `call / report` | `Breakage.yml` | the breakage report, and `REL1` against the base on a release PR |

`needs:` only reaches the jobs of the same workflow: an aggregator cannot gather several
workflows, hence one per theme, not one for all.

## The aggregator

```yaml
  ci-ok:
    # The one required check of this workflow: a stable name, whatever the matrix.
    if: always()
    needs: [test-cpu-github, test-gpu-kkt, test-gpu-occidata]
    runs-on: ubuntu-latest
    steps:
      - name: Every job passed or was skipped
        env:
          RESULTS: ${{ toJSON(needs.*.result) }}
        run: |
          echo "$RESULTS"
          jq -e 'all(. == "success" or . == "skipped")' <<< "$RESULTS"
```

`if: always()` makes it run, and report, when a job it needs failed or was cancelled: then
it fails. Without it, it would be skipped, and a skipped required check passes.

## Rules

- **No `paths:` filter on a workflow with a required check.** A check that never starts
  never reports, and the PR waits forever.
- **A skipped job passes.** A label-gated job without its label is skipped, so the
  aggregator passes on a PR without labels: that is right for an ordinary PR. On a release
  PR, the release gate requires every run label of the workflows, so the jobs run.
- **`strict`**: the branch must be up to date with `main`; a PR whose base moved runs its
  checks again.
- The settings are per repository (a human, or `gh api` with the human's approval):

  ```bash
  gh api -X PATCH "repos/$REPO" -F allow_auto_merge=true
  gh api -X PATCH "repos/$REPO/branches/main/protection/required_status_checks" \
    -F strict=true -f 'checks[][context]=call / gate' -f 'checks[][context]=ci-ok' \
    -f 'checks[][context]=docs-ok' -f 'checks[][context]=call / report'
  ```
