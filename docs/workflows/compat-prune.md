# `compat-prune`: the organization's `[compat]` prune

[← Workflows of control-toolbox](../README.md)

Once a month, finds the `[compat]` specifiers that no supported Julia version selects any
more, across all CT\* packages at once, proves that dropping them changes no resolved
version, and opens one PR per repository that has some, plus one tracking issue in
CTActions. Decided in OptimalControl.jl#986; built in CTActions#95.

| File | Role |
| --- | --- |
| `.github/workflows/compat-prune-monthly.yml` | The trigger: monthly (1st, 04:00 UTC) and by hand |
| `.github/workflows/compat-prune.yml` | The logic (reusable): `audit` job (read-only), `publish` job (writes) |
| `.github/workflows/compat-prune-tests.yml` | The [self-test](#tests) |
| `scripts/compat-prune/` | The scripts (Julia), and `test/` |

No package carries a caller: the prune is the organization's, and lives here.

## Why

[CompatHelper](compat-helper.md) runs with `KeepEntry()`: a new release is added next to
the old ones (`JET = "0.9, 0.11, 0.12"`), so a package keeps working with what its users
may be pinned to. Old specifiers pile up, and **none can be dropped from inside one
package**: `JET 0.9` may still be what Julia 1.10 selects, `CUDSS 0.7` what another
package's tests select. Whether a specifier is still used depends on every package of the
ecosystem, on every supported Julia version, and on their test and docs environments.
The prune answers that question for all of them together.

It **only prunes**. Widening stays with CompatHelper (and [Breakage](breakage.md)); an
entry whose newest specifier is never selected is reported, with what caps it, but not
changed.

## How it decides

1. **What is audited.** Each package at the version the joint resolution of all of them
   selects, its files read from its **registered** tree (not from a branch). Seventeen
   environments: the joint one, plus the test environment (`test/Project.toml` or
   `[targets] test`) and the docs environment of each package, each on every Julia version
   (`1.10`, `1.12`, `1.13`). Resolution calls Pkg's resolver only: nothing is downloaded or
   installed, and **one registry snapshot** serves the whole audit (about 4 minutes on a
   runner).
2. **Where an entry applies.** An entry of `Project.toml` applies wherever its package is
   resolved at its audited version; an entry of `test/` or `docs/` only in that very
   environment.
3. **Classification of each entry with several specifiers:**

   | Status | Meaning | Action |
   | --- | --- | --- |
   | **prune** | Some specifiers, older than the newest one in use, are selected nowhere it applies | drop them |
   | **keep** | Every specifier is in use somewhere | none |
   | **blocked** | The newest specifier is never selected | none; reported with the packages that cap it (its obsolete older specifiers, if any, are a separate prune) |
   | **idle** | The entry is resolved nowhere it applies | none |
   | **withheld** | An environment failed to resolve: what it uses is unknown | none: **no prune at all** that run |

4. **Proof.** Every prune is simulated by intersecting the compat of the environments
   where it applies, all prunes together, on every Julia version. It is kept only if
   **every manifest stays identical**; an environment that changes rejects its culprits
   (tested alone), and the round is repeated until stable. A prune therefore changes no
   resolved version: the PRs can be merged in any order and need no release.
5. **Edits.** The accepted prunes are re-applied to fresh clones of the default branches,
   one `[compat]` line at a time, never copied from the audit: `edited`, `already` (the
   branch already has it), or `drift` (the branch no longer has the audited line: left
   untouched and reported).

## What it publishes

- **One PR per repository** with edits, from the branch `ct/compat-prune`, by
  `ct-prune`: a table `file | dependency | before | after | selected` (the
  versions each kept specifier resolves to, per Julia version) and a link to the issue.
  The branch is rewritten by every run: **push nothing to it**; merge it as it is.
- **One tracking issue** in CTActions, `[compat] prune report` (hidden marker
  `<!-- ct-compat-prune -->`):

  | Section | Content |
  | --- | --- |
  | Audit | environments resolved per Julia version, entries examined by status, registry snapshot, and (folded) the entries kept or idle, with why |
  | Summary | counts: to prune (open PRs), merged awaiting release, drift, rejected, withheld, blocked |
  | To prune | per repository, with its PR |
  | Merged, awaiting release | prunes on the default branch, not yet in a registered version |
  | Drift | audited lines the default branch no longer has |
  | Rejected | prunes the simulation refused, and why |
  | Withheld | why nothing was pruned |
  | Blocked | newest specifiers never selected, and what caps them (information) |
  | Audited versions | the version of each package, its repository and files |

**Idempotence.** A rerun rewrites the PRs and the issue in place; the branch is pushed only
when its content changes. A repository with nothing left gets its PR closed (with a
comment) and its branch deleted. When nothing is left at all, the issue is closed; it is
reopened, never recreated, by the next run that finds something. Every write goes through
the REST API, with a token of the [GitHub App](../conventions/github-app.md).

## Reading the report

| You see | What to do |
| --- | --- |
| A prune PR | Review the table, merge. Nothing to release for it |
| **Drift** | The default branch changed since the registered version (e.g. an unreleased branch). It resolves itself once that version is registered; nothing to do |
| **Rejected** | A specifier looks unused but dropping it changes a manifest (usually through another package's compat). Kept; nothing to do |
| **Withheld** | An environment did not resolve: fix that first (the reason is in the job log), then rerun |
| **Blocked** | The newest specifier of an entry is never selected, capped by the packages listed (or by the resolver's preference). Information: lift the cap upstream if it matters |

## Running it

**By hand:** *Actions* → **Compat prune (monthly)** → *Run workflow*. `dry_run: true` (the
default by hand) runs only the read-only `audit` job: report and diff in the job summary,
everything in the `compat-prune` artifact (30 days). `dry_run: false` publishes.

**The schedule** publishes: the 1st of every month, 04:00 UTC. A manual run stays a dry run (`dry_run` is ticked by default) unless you untick it.

**Inputs of `compat-prune.yml`:**

| Input | Default | Meaning |
| --- | --- | --- |
| `packages` | the 8 CT\* packages (CTBase, CTParser, CTModels, CTLie, CTFlows, CTDirect, CTSolvers, OptimalControl) | Registered names, JSON |
| `julia_versions` | `'["1.10","1.12","1.13"]'` | juliaup channels; the last one is the newest (blockers are probed there) |
| `dry_run` | `true` | Audit and report only |
| `ctactions_ref` | `main` | Ref of CTActions the scripts are taken from (the monthly workflow passes its own commit) |
| `tracking_repo` | `control-toolbox/CTActions` | Repository of the tracking issue |

| Secret | |
| --- | --- |
| `CT_PRUNE_COMPAT_CLIENT_ID`, `CT_PRUNE_COMPAT_PRIVATE_KEY` | The [GitHub App](../conventions/github-app.md); needed by `publish` only |

`ct-registry` is added over HTTPS (it is public): no `SSH_KEY`.

**Locally** (juliaup, with the audited channels installed):

```bash
julia scripts/compat-prune/audit.jl \
  '["CTBase","CTParser","CTModels","CTLie","CTFlows","CTDirect","CTSolvers","OptimalControl"]' \
  '["1.10","1.12","1.13"]' /tmp/audit
scripts/compat-prune/checkout.sh /tmp/audit /tmp/checkouts
julia scripts/compat-prune/edit.jl /tmp/audit /tmp/checkouts     # edits the clones in place
julia scripts/compat-prune/report.jl /tmp/audit                  # /tmp/audit/report.md
```

`audit.jl` needs `gh` (authenticated) to read the registered trees; it updates the
registries once at its start. Nothing is published locally unless you run `publish.jl`.

## Tests

`scripts/compat-prune/test/`, one file per script (`test_collect.jl`, `test_envs.jl`,
`test_classify.jl`, `test_validate.jl`, `test_audit.jl`, `test_edit.jl`, `test_report.jl`,
`test_publish.jl`), plus:

- **non-regression** (`test_regression.jl`): a frozen snapshot of the real ecosystem
  (`fixtures/snapshot-2026-10-15/`), its environments, classification and edits compared
  with golden files;
- **golden files** (`golden/`) for the issue and PR bodies; regenerate with
  `COMPAT_PRUNE_UPDATE_GOLDEN=1` and review the diff;
- **publishing** against a stateful fake GitHub REST API and real bare git repositories,
  over four successive runs (create, rerun unchanged, after the merge, a new prune);
- **integration** (`test_integration.jl`, `COMPAT_PRUNE_INTEGRATION=1`): the scripts as
  commands, on real registered packages.

```bash
COMPAT_PRUNE_INTEGRATION=1 julia scripts/compat-prune/test/runtests.jl
```

`compat-prune-tests.yml` runs them on Julia 1.10, 1.12 and 1.13 for every PR or push
touching `scripts/compat-prune/` or `compat-prune*.yml`, then a real dry-run audit through
`compat-prune.yml`. The `audit` job also runs the tests before auditing.
