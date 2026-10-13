# GitHub workflows — the control-toolbox philosophy

How the control-toolbox organization manages GitHub Actions across all its
repositories. Read this **before creating a new repo**, before adding or editing a
workflow, or when wondering why a given workflow is (or is not) present in a given
package.

The companion of this file in practice is the **[`CTActions`](https://github.com/control-toolbox/CTActions)**
repository (the central workflow library) and the **[`CTAppTemplate.jl`](https://github.com/control-toolbox/CTAppTemplate.jl)**
repository (the bootstrap template for a new package).

---

## 1. The core idea: centralize, then call

A control-toolbox repository **does not define its CI logic**. The logic lives **once**
in `CTActions`, as a set of **reusable workflows** (`on: workflow_call`). Every package
ships only a thin **caller** that delegates to `CTActions`:

```yaml
# .github/workflows/CI.yml  — in any package
jobs:
  call:
    uses: control-toolbox/CTActions/.github/workflows/ci.yml@main
    with:
      runs_on: '["ubuntu-latest", "macos-latest", "windows-latest"]'
      use_ct_registry: true
    secrets:
      SSH_KEY: ${{ secrets.SSH_KEY }}
```

`runs_on` should list all three GitHub-hosted OSes — Windows included. `CTBase` is the
most up-to-date reference caller to copy from; it also carries a Windows-specific smoke
test (`test-selection-smoke` in `CI.yml`) added after a real regression where Windows'
backslash-separated relative paths silently broke a forward-slash glob (see §5).

Why this design:

- **Single source of truth.** Fixing a CI bug or bumping an action version is done
  once in `CTActions`; every repo picks it up on its next run (callers pin `@main`).
- **Thin, declarative callers.** A package's workflow file only says *which* shared
  workflow to call, on *which events*, with *which inputs/secrets*. No step logic.
- **Consistency.** All packages test, build docs, format, and spell-check the same way.
- **Easy onboarding.** A new repo copies the caller files from the template; it
  inherits the whole pipeline for free.

### Naming convention

| Layer | Location | Filename style | Example |
| --- | --- | --- | --- |
| **Reusable** (the logic) | `CTActions/.github/workflows/` | `kebab-case.yml` | `ci.yml` |
| **Caller** (the trigger) | `<package>/.github/workflows/` | `PascalCase.yml` | `CI.yml` |

Callers always reference the reusable workflow by its full path **pinned to `@main`**:
`control-toolbox/CTActions/.github/workflows/<name>.yml@main`.

---

## 2. The second idea: label-gated triggers

Running the full matrix (CI on several OSes, breakage against every downstream package,
a Documenter build) on **every push to every PR** is slow and wasteful. So expensive
workflows are **opt-in per pull request via a label**. The caller guards its job with:

```yaml
jobs:
  call:
    # A 'labeled' event fires once per label added, and re-evaluates against the PR's
    # *current* full label set — so adding several labels in a row would otherwise
    # re-run this job on every subsequent label add. Only react to 'labeled' when it's
    # this specific label; for other trigger types (synchronize/reopened), fall back to
    # checking the current label set as before.
    if: >
      github.event_name != 'pull_request' ||
      (github.event.action == 'labeled' && github.event.label.name == 'run ci') ||
      (github.event.action != 'labeled' && contains(github.event.pull_request.labels.*.name, 'run ci'))
    uses: control-toolbox/CTActions/.github/workflows/ci.yml@main
```

Read this `if` as: **always run on `push`/`tag`** (the `main` branch must stay green),
but **on a pull request, only run when the `run ci` label is present.** You add the
label to a PR when you want that check; you remove/re-add it to re-trigger (the caller
also listens to the `labeled` event).

**Why the guard is split into two branches instead of a single `contains(...)`.** A
`labeled` event fires once *per label added*, and each firing re-evaluates the PR's
*current, full* label set. If a PR already carries `run ci` and you add an unrelated
label (say `bug`), that `labeled` event still passes a plain `contains(...)` check and
re-runs CI for no reason. Gating the `labeled` branch on `github.event.label.name`
(the label that was *just* added) fixes that: only labeling the PR with `run ci` itself
triggers a run; other trigger types (`synchronize`, `reopened`) fall back to the
simple `contains(...)` check since there is no single "label that fired" to compare
against. This is the pattern actually in use (`CI.yml`, `Breakage.yml`,
`Documentation.yml`) across `CTBase`, `CTFlows.jl`, `CTModels.jl`, `CTSolvers`, `CTLie`.

### The `types:` list — and why `opened` must **not** be there

The `if` guard is only half the gate. The other half is which pull-request events the
caller subscribes to. For a **label-gated** workflow, the list is:

```yaml
on:
  pull_request:
    types: [labeled, synchronize, reopened]   # NOT `opened`
```

**Why `opened` is not just redundant but harmful.** Applying a label while opening a PR
(`gh pr create --label "kkt-runner"`, or picking labels in the web UI form) emits **two**
events: `opened` **and** `labeled`. With `opened` in the list, both match, the `if` guard
passes for both, and the workflow runs **twice on the same commit**. On a self-hosted GPU
runner that is a duplicated billed job for zero information. Measured on
`CTFlows.jl#354`: two runs created at `20:04:59` and `20:05:00`.

**Why dropping it loses nothing** — walk the four ways a label-gated run can legitimately
start:

| Situation | Event that fires | Covered without `opened`? |
| --- | --- | --- |
| PR opened **with** the label | `labeled` | ✅ — `labeled` fires even when the label is set at creation |
| PR opened **without** the label | `opened` only | ✅ — nothing should run; the `if` guard would reject it anyway |
| Label added later | `labeled` | ✅ |
| New commits pushed | `synchronize` | ✅ |

The second row is the key insight: a PR opened *without* the label must not run, so
subscribing to `opened` can only ever produce a run that the `if` guard rejects — or, when
the label *is* present, a duplicate of the `labeled` run. Either way it adds nothing.

**Keep `reopened`.** Reopening a closed PR does **not** re-emit `labeled`, so a PR that
still carries its label would never re-run without it. `reopened` is what covers that case;
it is not interchangeable with `labeled`.

**Prefer this over `concurrency: cancel-in-progress`.** A concurrency group would also
collapse the duplicate, but it cancels a *running* job — and on the self-hosted GPU runner
cancelling a Julia process was observed to leave an orphan process behind
(`Terminate orphan process: pid (julia)`) and a pathologically slow next run. Not
subscribing to the useless event is cheaper and has no such side effect.

**The rule is specific to `if`-guarded, opt-in workflows.** Workflows that are *not*
label-gated legitimately keep `opened` — indeed some exist only to react to it:
`AddToProject.yml` uses `types: [opened]` and `AutoAssign.yml` uses
`types: [opened, reopened]`, because adding a PR to the board and assigning a reviewer are
exactly "on creation" actions. Formatter and SpellCheck set no `types:` filter at all and
run on every PR event, which is also correct for a cheap GitHub-hosted check.

So the discriminator is simple: **does the job carry a `contains(… .labels.*.name, …)`
guard?** If yes, `types: [labeled, synchronize, reopened]`. If no, subscribe to whatever
events the job actually needs.

### The trigger labels

| Label | Triggers | Used in |
| --- | --- | --- |
| `run ci` | CI test matrix (single job) | most packages |
| `github-runner` | CI on GitHub-hosted runners | packages with split CI: OptimalControl, CTParser.jl, CTDirect.jl, CTFlows.jl, CTSolvers, CTLie |
| `kkt-runner` | **Retired** — `kkt` is no longer a registered self-hosted runner in the org at all (`gh api orgs/control-toolbox/actions/runners` lists only `occidata-runner` and `pinwheel`). No `CI.yml` in the fleet defines a job for it any more. The label survives only as an unused leftover in OptimalControl, CTFlows.jl and CTLie — delete it there rather than reuse it. | none |
| `occidata-runner` | CI on the self-hosted `occidata` GPU runner — the fleet's sole self-hosted CUDA CI target now that `kkt` is retired | every package with GPU-relevant code: OptimalControl, CTParser.jl, CTDirect.jl, CTFlows.jl, CTSolvers, CTLie |
| `run GPU` | dedicated GPU test job | CTDirect (older, pre-split-CI pattern — not up to date, see §3.3) |
| `run breakage` | breakage tests against downstream **packages** | core packages |
| `run breakage applications` | breakage against downstream **applications/tutorials** | OptimalControl |
| `run documentation` | full Documenter build on the PR | most packages |
| `run probe` | standalone capability-probe scripts (see `CPUProbe.yml`/`GPUProbe.yml`, §3.3) | CTFlows.jl |

**Split-CI labels are named after the *runner*, not the workload.** The two halves of a
split `CI.yml` (§3.1) are gated by **`github-runner`** and **`occidata-runner`** — not by
the older `run ci cpu` / `run ci gpu`, which are deprecated and must be renamed wherever
they still exist. The runner-based naming is the accurate one: the GitHub-hosted job is not
meaningfully "the CPU job", it is the job that runs on GitHub's runners (and happens to
exercise CPU paths); the other job is defined by the self-hosted machine it lands on. Naming
the label after the runner also keeps the label, the `runs_on` value and the job name saying
the same thing, and it extends by construction to a future runner (`<name>-runner`) without
inventing a new workload adjective — that is exactly how `occidata-runner` itself started
(added to CTFlows.jl on 2026-08-24, when it was a *second* self-hosted GPU box alongside
`kkt` for heavier GPU workloads specifically). `kkt-runner` was the first label this
convention produced and is now the retired one — the convention outlives any one runner.

**This vocabulary is fleet-wide, not a per-repo choice.** Labels are the user-facing
trigger surface: someone applying a label from muscle memory in a sibling repo, or
scripting across the org, must not discover that `run ci cpu` silently does nothing here
and `github-runner` silently does nothing there. §7's "per-repo trigger change" licence
covers *which* labels a repo defines, never *how they are spelled*.

Labels are defined per-repo (GitHub repository labels). When you bootstrap a new repo,
create the labels you intend to use (`gh label create "run ci" --color 78f620
--description "Trigger CI"`, etc.). Workflows that are **not** PR-gated (scheduled or
push-only) need no label.

---

## 3. The catalog of workflows

Two families: **reusable workflows** (defined in `CTActions`, called by packages) and a
few **non-centralized / special** workflows (defined directly in a package).

### 3.1 Reusable workflows (in `CTActions`)

| Reusable (`CTActions`) | Caller name | Role | Typical trigger | Key inputs / secrets | PR label gate |
| --- | --- | --- | --- | --- | --- |
| `ci.yml` | `CI.yml` | Build + run the test suite over a Julia × OS × arch matrix | `push`, `tag`, PR | `versions`, `runs_on`, `archs`, `runner_type`, `use_ct_registry`; `SSH_KEY` | `run ci` (or `github-runner` / `occidata-runner` when split, see below) |
| `coverage.yml` | `Coverage.yml` | Run tests with coverage, upload to Codecov | `push`/`tag` to `main` | `use_ct_registry`; `codecov-secret`, `SSH_KEY` | — (push only) |
| `documentation.yml` | `Documentation.yml` | Build & deploy the Documenter site; optionally a `build-gpu` upgrade pass that redeploys with real GPU output once `build` has already published | `push`, `tag`, PR | `use_ct_registry`, `gpu_runner`, `gpu_timeout_minutes`; `SSH_KEY`, `DOCUMENTER_KEY` | `run documentation` |
| `breakage.yml` | `Breakage.yml` | Test that a change doesn't break downstream packages/apps (`latest`/`stable`); comment a result table on the PR | PR (labeled) | `pkgname`, `pkgpath`, `pkgversion`, `pkgbreak` (`test`/`doc`), `use_ct_registry`; `SSH_KEY` | `run breakage` |
| `formatter.yml` | `Formatter.yml` | Run JuliaFormatter (BlueStyle) and open an auto PR | scheduled (nightly), `workflow_dispatch` | — | — |
| `spell-check.yml` | `SpellCheck.yml` | Spell-check with `crate-ci/typos` | PR, `workflow_dispatch` | `locale`, `extend-identifiers`, `config-path` | — |
| `compat-helper.yml` | `CompatHelper.yml` | Open PRs bumping `[compat]` bounds | scheduled (daily), `workflow_dispatch` | `subdirs`; `GITHUB_TOKEN`, `DOCUMENTER_KEY` | — |
| `update-readme.yml` | `UpdateReadme.yml` | Regenerate `README.md` from a template + the org's central `ABOUT/INSTALL/CONTRIBUTING.md` + badges | scheduled (weekly), `workflow_dispatch` | `template_file`, `output_file`, `package_name`, `repo_name`, `doc_url`, `citation_badge`, `assignee` | — |
| `auto-assign.yml` | `AutoAssign.yml` | Auto-assign new issues/PRs to a maintainer | issue/PR opened | `assignees`, `numOfAssignee` | — |
| `add-to-project.yml` | `AddToProject.yml` | Add new issues/PRs to the org project board (set Status) | issue/PR opened | `project-url`, `status`; `project_token` | — |

**The `ci.yml` caller can be a single job, or split in two.** A package that needs GPU
tests calls `ci.yml` twice from its `CI.yml`: once as a GitHub-hosted job (`runs_on` an array
of GitHub-hosted labels, gated by `github-runner`), once as a `self-hosted` GPU job on
`occidata` (`runs_on: '[["occidata"]]'`, gated by `occidata-runner`). This is not an
OptimalControl-specific quirk — `CTParser.jl`, `CTDirect.jl`, `CTFlows.jl`, `CTSolvers` and
`CTLie` all use the same two-way split; every package with GPU-relevant code now does. A
package with no GPU-relevant code (`CTModels.jl`, `CTBase`) keeps the single `call` job
gated by plain `run ci`.

**`kkt` is fully retired — a three-way split (`github` + `kkt` + `occidata`) does not
currently exist anywhere.** Earlier drafts of this document described `kkt` as a live target
and CTFlows.jl as running a three-way split; the fleet moved past both. `kkt` is no longer
even a registered runner in the org (confirmed via
`gh api orgs/control-toolbox/actions/runners`, 2026-09-02) — only `occidata-runner` and
`pinwheel` are — and no `CI.yml` in the fleet still calls it.

**A third self-hosted GPU box, `pinwheel`, exists and is currently unused by any
workflow.** Discovered 2026-09-02 while probing `occidata` for
control-toolbox/OptimalControl.jl#885: `pinwheel` is **AMD**
(`labels: self-hosted, Linux, X64, gpu, amdgpu, pinwheel`), not CUDA like `occidata`. It is
not a candidate for any `:gpu` CI in this ecosystem today — the GPU stack everywhere
(`ExaModels` → `MadNLPGPU` → `CUDSS`) is CUDA-only. Worth its own maintenance workflow and
a row in §3.1/§3.2 once something actually targets it; recorded here so nobody discovers it
by accident and points a CUDA job at it.

> `CTParser.jl` belongs in the split group: its `test/Project.toml` depends on `CUDA`,
> `MadNLPGPU`, `KernelAbstractions` and `ExaModels`, `test/runtests.jl` loads them
> unconditionally, and `src/onepass.jl` carries the ExaModels backend with explicit GPU
> array conversions.

**`documentation.yml` can carry the same split, but shaped differently: publish then
upgrade, not attempt-then-fallback.** OptimalControl.jl is the first caller to opt in
(`gpu_runner: '["occidata"]'`, CTActions#71, for control-toolbox/OptimalControl.jl#885 part
2). The existing GitHub-hosted `build` job is untouched and always runs first, deploying
exactly as before; a second job, `build-gpu`, runs only once `build` has already published
(`needs: build`) and, with `continue-on-error: true`, can never fail the workflow — on
success it redeploys the same site with real GPU output, on failure or a long SLURM queue it
simply leaves the already-published site in place. This shape exists because, unlike
`ci.yml`, a documentation build's job both builds *and* deploys (`deploydocs` runs inside
`docs/make.jl`), so there is no way to "attempt GPU, fall back to CPU" within a single job —
and putting a self-hosted box on the critical path of *publishing* is a reliability
regression `ci.yml`'s split never risked. Any caller that wants GPU-backed docs numbers
should follow this pattern, not the `ci.yml` one.

### 3.2 Maintenance workflows that live *in* `CTActions` (not called)

These run on `CTActions` itself, on a schedule, to keep the **self-hosted runners**
healthy. They are not `workflow_call` reusables.

| Workflow (`CTActions`) | Role | Trigger |
| --- | --- | --- |
| `occidata-runner-maintenance.yml` | Purge Julia compile cache, update TeXLive, rotate logs on the `occidata` self-hosted runner | weekly cron, `workflow_dispatch` |
| `occidata-runner-watchdog.yml` | Over SSH, run `scripts/start_runners.sh` (control-toolbox/occidata), which restarts every Occidata runner instance whose SLURM job is neither pending nor running | daily cron, `workflow_dispatch` |

`occidata` started as the target of this maintenance workflow only; since CTFlows.jl's
`occidata-runner` job (§3.1, added 2026-08-24) it is also a live GPU CI target for every
package's test matrix that needs one, and (2026-09-02, control-toolbox/OptimalControl.jl#885)
a documentation-build target too — not just a runner kept healthy for its own sake. Two
quirks of the node worth knowing for either role: the node's `/tmp` is wiped every hour at
`HH:01` (`ci.yml`'s `TMPDIR` redirect on self-hosted jobs works around this, commit 2f00b67 —
any long-running job, docs builds included, needs the same), and this workflow's own Monday
02:30 UTC purge of the compiled-code cache means the *first* job after it runs cold. A job
landing right after either is slower or needs a retry — not a sign the runner is unhealthy.

**The `occidata` runner has no GPU of its own: it gets one on demand.** Since 2026-09-28 the
runner idles in a CPU SLURM allocation (`24CPUNodes`) instead of holding a GTX 1080 Ti for
7 days. A step that needs CUDA prefixes its command with `$OCCIDATA_GPU_RUN`, which the runner
exports (control-toolbox/occidata, `scripts/slurm_gpu_run.sh`). That script submits the command
to `GPUNodes` with `sbatch --wait` for the step's duration only. It keeps the step's
environment (including `RUNNER_NAME`), streams its output, propagates its exit status, and
cancels the SLURM job when the workflow is cancelled:

```yaml
- run: ${OCCIDATA_GPU_RUN:-} julia --project=... script.jl   # plain `julia ...` on any other runner
```

`ci.yml` (through `julia-runtest`'s `prefix`) and `documentation.yml`'s `build-gpu` already do
this (CTActions#79), so their callers need nothing. **A workflow with its own steps must add
the prefix itself** (like CTFlows.jl's `GPUProbe.yml`). Without it, the step runs on the CPU
node, and the test suites' "`RUNNER_NAME` contains `occidata` ⇒ `CUDA.functional()` is
required" contract fails. Resources can be tuned per step with `OCCIDATA_GPU_PARTITION`,
`OCCIDATA_GPU_GRES`, `OCCIDATA_GPU_CPUS`, `OCCIDATA_GPU_MEM` and `OCCIDATA_GPU_TIME` (a bare
number is read as minutes). The label `gpu` on the runner therefore means "can get a GPU", not
"runs on one". Keep an eye on precompilation: it happens inside the prefixed command, that
is, while the GPU is held.

Occidata also hosts a second runner instance, `occidata-cpu`, for the `ocourses`
organization. It runs in `cpu` mode: no `$OCCIDATA_GPU_RUN`, so no GPU ever. Instances,
their modes and how to add one are documented in control-toolbox/occidata,
`docs/gha-runner-config.md` § 9.

### 3.3 Non-centralized / per-repo special workflows

| Workflow | Where | Why it isn't centralized |
| --- | --- | --- |
| `TagBot.yml` | every package | Thin wrapper over `JuliaRegistries/TagBot@v1`; standard upstream action, no shared logic to factor. Triggered by `issue_comment` from `JuliaTagBot` (registration) or `workflow_dispatch`. |
| `setup-repo.yml` | **CTAppTemplate only** | One-shot bootstrap: renames the package, regenerates the UUID, sets authors/assignees, opens a setup PR. Meaningful only on a fresh clone of the template. |
| `JOSS.yml` | **OptimalControl only** | Compiles the JOSS paper under `joss/`. Specific to the package that has a paper. |
| `GPU.yml` | **CTDirect only** | Dedicated GPU test job on a self-hosted GPU runner, gated by `run GPU`. Predates the `ci.yml` runner split (§3.1); `CTDirect.jl` is not currently kept up to date with the rest of the fleet, so treat this entry as historical rather than the pattern to copy — copy the split-`ci.yml` pattern instead. |
| `CPUProbe.yml`, `GPUProbe.yml` | **CTFlows.jl only** (so far) | Run standalone capability-probe scripts (`probe/cpu/probe_cpu.jl`, `probe/gpu/probe_gpu.jl`) on demand, separately from CI. Diagnostic only — always succeeds, prints a capability matrix. Used to keep documentation claims accurate and to support proof-of-concept exploration, not to gate merges. Gated by the `run probe` label (or `workflow_dispatch`); not centralized because the probe scripts are package-specific experiments, not shared CI logic. |
| `benchmark-reusable.yml`, `benchmarks-orchestrator.yml` | **CTBenchmarks.jl only** | Benchmark orchestration specific to the benchmarking repo. |

---

## 4. Which repo has which workflow — and why

Not every package carries every workflow. The base set (CI, Coverage, Documentation,
Formatter, SpellCheck, CompatHelper, UpdateReadme, AutoAssign, TagBot) is **universal**.
Two workflows are **conditional**: `Breakage` and `AddToProject`.

| Repo | Base set | Breakage | AddToProject | Extra |
| --- | :---: | :---: | :---: | --- |
| CTAppTemplate.jl | ✅ | — | — | `setup-repo` |
| CTBase | ✅ | ✅ | ✅ | — |
| CTModels.jl | ✅ | ✅ | ✅ | — |
| CTParser.jl | ✅ | ✅ | ✅ | split CI (`github-runner`/`occidata-runner`) |
| CTFlows.jl | ✅ | ✅ | — | split CI (`github-runner`/`occidata-runner`), `CPUProbe`/`GPUProbe` (`run probe`) |
| CTDirect.jl | ✅ | ✅ | ✅ | split CI (`github-runner`/`occidata-runner`, replacing the older dedicated `GPU.yml`); `Formatter` disabled — **stale**, not currently kept up to date with the rest of the fleet |
| CTSolvers | ✅ | ✅ | ✅ | split CI (`github-runner`/`occidata-runner`) |
| OptimalControl | ✅ | ✅ | ✅ | `JOSS`, split CI (`github-runner`/`occidata-runner`); `Documentation` also carries an optional `build-gpu` upgrade pass on `occidata` (2026-09-02, control-toolbox/OptimalControl.jl#885) |
| OptimalControlProblems | ✅ | — | — | — |
| CTDiffFlow.jl | ✅ | — | — | — |
| CTBenchmarks.jl | ✅ | — | — | `benchmark-*` |
| CTLie | ✅ (no `AddToProject`) | ✅ (vs. `OptimalControl`) | — | split CI (`github-runner`/`occidata-runner`) |

**Why `Breakage` is present only in some repos.** Breakage answers: *"if I change this
package, do its downstream consumers still build/test?"* It only makes sense for a
package that **has downstream consumers inside the ecosystem**.

- A **foundation** package (`CTBase`) is depended on by everything, so its breakage
  matrix lists all the packages below it (`CTDirect`, `CTFlows`, `CTModels`, `CTParser`,
  `CTSolvers`, `OptimalControl`).
- An **umbrella** package (`OptimalControl`) sits on top, so its breakage matrix tests
  downstream **applications and tutorials** (hence the extra `run breakage
  applications` label and the `pkgbreak: doc` variant that builds their docs).
- A **peripheral / leaf** repo with no internal dependents (`CTDiffFlow`,
  `CTBenchmarks`, `OptimalControlProblems`, the template) has nothing to break, so it
  carries no `Breakage`.

**Why `AddToProject` is present only in some repos.** It wires issues/PRs into the
organization's project board. It is enabled on the actively-managed core packages and
omitted from peripheral repos and the template.

**Why `Formatter` is disabled in CTDirect** (`Formatter.yml.disabled`). The caller is
kept on disk but the `.disabled` suffix makes GitHub ignore it — a per-repo opt-out
without deleting the file. (Rename back to `Formatter.yml` to re-enable.)

**Why the template's CI has no label gate.** `CTAppTemplate.jl/CI.yml` calls `ci.yml`
with no `if:` and minimal inputs — the template favors a simple "runs on every PR"
default; real packages then tighten it with the `run ci` label and richer inputs.

---

## 5. Cross-cutting concepts

### The `ct-registry` and `SSH_KEY`

Several packages depend on **unregistered** ecosystem packages hosted in the private
[`control-toolbox/ct-registry`](https://github.com/control-toolbox/ct-registry). When a
workflow needs them, the caller passes `use_ct_registry: true` **and** the `SSH_KEY`
secret; the reusable workflow then runs `julia-actions/add-julia-registry` before
building. Set `use_ct_registry: false` for packages that only need the General registry
(e.g. `OptimalControl`'s CI sets it `false`; `CTBase`'s sets it `true`).

> Note: on Windows runners the registry step is skipped (SSH-key registry add is not
> wired there); keep that in mind when choosing `runs_on`.

### GitHub-hosted vs self-hosted runners

`ci.yml` accepts `runner_type: github | self-hosted` and a `runs_on` value (a single
label string or a JSON array of labels). GitHub-hosted runners use
`julia-actions/cache`; self-hosted runners use manual artifact/compiled-code caches.
`OptimalControl`, `CTParser.jl`, `CTDirect.jl`, `CTFlows.jl`, `CTSolvers` and `CTLie` all
demonstrate the split (any package with GPU-dependent code to test): a `github` job
(`github-runner`) and a `self-hosted` GPU job on the `occidata` runner
(`occidata-runner`) — the labels are named after the runner, see §2. The self-hosted
runner is the one maintained by the scheduled `CTActions` maintenance workflows (§3.2).

### Secrets used across the pipeline

| Secret | Used by | Purpose |
| --- | --- | --- |
| `SSH_KEY` | CI, Coverage, Documentation, Breakage | Add the private `ct-registry` |
| `DOCUMENTER_KEY` | Documentation, CompatHelper, TagBot | Deploy docs / sign tags (Documenter deploy key) |
| `CODECOV_TOKEN` → `codecov-secret` | Coverage | Upload coverage to Codecov |
| `PROJECT_TOKEN` → `project_token` | AddToProject | Write to the org project board |
| `GITHUB_TOKEN` | (built-in) most | Default repo-scoped token |

Use `secrets: inherit` (as `UpdateReadme` does) only when the reusable workflow needs
the caller's whole secret set; otherwise pass secrets explicitly, one by one.

---

## 6. Recipe — workflows for a **new** repository

1. **Start from the template.** Create the repo from `CTAppTemplate.jl` ("Use this
   template"). It already contains the base-set callers.
2. **Run `setup-repo`.** Trigger the `Setup Repository` workflow
   (`workflow_dispatch`); it renames the package, regenerates the UUID, sets authors
   and assignees, and opens a setup PR. Merge it, then delete `setup-repo.yml`.
3. **Adjust `AutoAssign.yml`** assignee if `setup-repo` didn't (default `ocots`).
4. **Decide on `Breakage`.** Add `Breakage.yml` only if other ecosystem packages
   depend on this one; fill the `pkgname` matrix with the downstream consumers. Skip it
   for a leaf/peripheral repo.
5. **Decide on `AddToProject`.** Add it (with the `PROJECT_TOKEN` secret) if the repo is
   tracked on the org project board.
6. **Set CI inputs.** Choose `versions`, `runs_on` (include `windows-latest` unless
   there's a specific reason not to — `CTBase` is the reference caller to copy), and
   `use_ct_registry` in `CI.yml`. Set `use_ct_registry: true` if the package needs
   `ct-registry`.
7. **Decide on a runner split.** If the package has GPU-dependent code to test, split
   `CI.yml` into a `github` job (`github-runner`) and a `self-hosted` GPU job on the
   `occidata` runner (`occidata-runner`) instead of a single `run ci` job — see §3.1
   and `CTParser.jl`/`CTDirect.jl`/`CTFlows.jl`/`CTSolvers`/`CTLie` for the current
   pattern, all identical. There is no third job and no `kkt` runner any more — `kkt`
   is retired (§2), and `CTDirect.jl`'s older, separate `GPU.yml` has been replaced by
   this same split, not kept alongside it. Use the label names verbatim; the former
   `run ci cpu` / `run ci gpu` spelling is deprecated (§2).
8. **Create the trigger labels** you reference (`run ci`, `run breakage`, `run
   documentation`, `github-runner`/`occidata-runner` when split, …) in the repo's
   label set.
9. **Configure secrets** in the repo (or org): `SSH_KEY`, `DOCUMENTER_KEY`,
   `CODECOV_TOKEN`, `PROJECT_TOKEN` as needed by the workflows you kept.
10. **Provide `UpdateReadme` inputs.** Add a `README.template.md` and fill
    `package_name`, `repo_name`, `doc_url` in `UpdateReadme.yml`, or the job self-skips.

## 7. Recipe — **updating** workflows org-wide

- **Logic change** (a step, an action version, caching, a new input): edit the
  **reusable** workflow in `CTActions`. Because callers pin `@main`, every repo picks it
  up on its next run. Keep inputs backward-compatible (add with a `default:`), or update
  the callers in lockstep.
- **Per-repo trigger/inputs change** (different OS matrix, *which* labels the repo
  defines, enabling `ct-registry`): edit that repo's **caller** only. Note this includes
  the `types:` list — it lives in the caller, not in `CTActions`, so a fix like dropping
  `opened` (§2) has to be applied **once per repo per label-gated caller**; it does not
  propagate via `@main`. What is *not* per-repo is how a label is **spelled**: label names
  come from the fleet-wide vocabulary in §2.
- **Rename a label fleet-wide** (as was done for `run ci cpu`/`run ci gpu` →
  `github-runner`/`kkt-runner`): the label name appears in two places per repo — the
  repository label itself and the caller's `if:` guard. Do both together, per repo
  (`gh label edit "run ci cpu" --name "github-runner"` keeps the label's existing
  assignments), since a renamed label with a stale guard silently stops triggering
  anything.
- **Roll out a brand-new workflow:** add the reusable in `CTActions`, add the caller to
  `CTAppTemplate.jl` (so new repos inherit it), then copy the caller into the existing
  repos that need it.
- **Disable a workflow in one repo without deleting it:** rename `X.yml` → `X.yml.disabled`
  (see CTDirect's Formatter).
- **Pinning:** prefer `@main` for in-ecosystem reuse (fast propagation); if you ever
  need a frozen pipeline for a release branch, pin a caller to a tag/SHA of `CTActions`
  instead.

---

## 8. Quick checklist for a new repo

- [ ] Created from `CTAppTemplate.jl`; `setup-repo` run and merged; `setup-repo.yml` removed.
- [ ] Base set present (CI, Coverage, Documentation, Formatter, SpellCheck, CompatHelper, UpdateReadme, AutoAssign, TagBot).
- [ ] `Breakage.yml` added **iff** the repo has internal downstream consumers; matrix filled.
- [ ] `AddToProject.yml` added **iff** tracked on the project board (`PROJECT_TOKEN` set).
- [ ] CI inputs set (`versions`, `runs_on` — include `windows-latest`, `use_ct_registry`).
- [ ] Runner split decided (`github-runner` + `occidata-runner` jobs) **iff** the package has GPU-dependent code to test.
- [ ] Trigger labels created for every label-gated caller (`run …`, plus `github-runner`/`occidata-runner` when split).
- [ ] Every label-gated caller uses `types: [labeled, synchronize, reopened]` — **no `opened`**
      (it duplicates the `labeled` run when a PR is created with its label; see §2).
- [ ] Secrets configured (`SSH_KEY`, `DOCUMENTER_KEY`, `CODECOV_TOKEN`, `PROJECT_TOKEN`).
- [ ] `README.template.md` present and `UpdateReadme.yml` inputs filled.
