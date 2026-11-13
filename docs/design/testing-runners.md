# Tests and runners: the choices

[← Workflows of control-toolbox](../README.md)

Why the tests of a package run where and how they do. For the person who maintains
`ci.yml`, `ci-gpu.yml`, `select-gpu-runner.yml` or the self-hosted runners. How to use
them: [the guide](../guides/testing.md); how each behaves: the pages it links to.

The failures and dates come from the commits and issues cited. Where an alternative was
not recorded at the time, the page says so.

## The constraints

- The ecosystem's GPU stack (`ExaModels` → `MadNLPGPU` → `CUDSS`) is **CUDA only**, and
  GitHub offers no CUDA runner to the organization: GPU tests need machines of our own.
- Those machines are **few and shared**: `kkt` (one machine), `occidata` (a node of a
  university SLURM cluster, whose GPU nodes are shared with other users).
- Users install the packages on Linux, macOS and Windows, on the lowest supported Julia and
  the newest.

## The choices

### 1. GitHub-hosted for the matrix, self-hosted for the GPU only

**Chosen**: the OS × Julia matrix on GitHub's runners (fresh, parallel, free for a public
repository); self-hosted runners only for what needs a GPU, each behind its own label on a
pull request.

**Why not the self-hosted runners for everything**: they are one or two machines; the
matrix would queue behind the GPU jobs, and a persistent machine carries state between jobs
(choice 3).

**Windows is in the matrix**, because users install there and it fails differently: path separators and the SSH
agent broke silently more than once (0184adf; CTBase's Windows smoke test of its test
selection after a forward-slash glob missed backslash paths).

**Native architecture** (234e313): the matrix used to force `x64`, overridden on Apple
Silicon runners; `setup-julia` now picks the native one.

### 2. A split CI: one job per runner

**Chosen**: a package with GPU-relevant code calls `ci.yml` once per runner, each gated by
its own label (`run ci github-runner`, `run ci occidata-runner`, `run ci kkt-runner`), so
that a developer asks for exactly the machine they need and a GPU run never waits for the
OS matrix, or the reverse. The label names the **runner**, not the workload
([the vocabulary](../conventions/labels.md#the-vocabulary)): a new runner gets a label
without a new adjective.

**Replaced**: CTDirect.jl's `GPU.yml` (label `run GPU`), a separate workflow outside
`ci.yml`.

### 3. A persistent depot, distrusted

A self-hosted runner keeps its Julia depot: that is what makes a GPU run affordable
(precompiling the CUDA stack takes long), and also what breaks it: a `compiled/` cache left
by another branch can fail precompilation for an unrelated package.

**Chosen** (c61998d): cache `artifacts/` and `compiled/` at the depot **Julia reports**
(the steps used to hardcode `~/.julia` and missed the real depot of `occidata`), and, on a
test failure, **purge `compiled/` and retry once**. A runner recovers by itself, without a
maintenance job per runner; a real failure fails twice.

**Cost**: a real failure takes twice as long to report; an artifact uploaded after a retry
holds the files of the last attempt.

**Around it**: `TMPDIR` under `$RUNNER_TEMP`, because `occidata` wipes `/tmp` every hour
(2f00b67); a weekly [maintenance](../workflows/occidata-runner-maintenance.md) (caches,
git config, logs); a daily [watchdog](../workflows/occidata-runner-watchdog.md) that
restarts the runner jobs over SSH.

### 4. `occidata`: a GPU per step, not per runner

**Before** (until 2026-09-28): the runner held a GPU node (a GTX 1080 Ti) for seven days,
idle most of the time, on a cluster shared with others.

**Chosen**: the runner idles on a CPU node; a step that needs CUDA prefixes its command
with `$OCCIDATA_GPU_RUN`, which submits it to the GPU partition (`sbatch --wait`) for the
step's duration, streams its output, propagates its status and cancels the SLURM job when
the workflow is cancelled (CTActions#79 for `ci.yml` and `documentation.yml`).

**Cost**: the wait for a GPU node adds to the run; precompilation happens while the GPU is
held; **a workflow with its own steps must add the prefix itself**, or it runs on the CPU
node and the test suites' contract (`RUNNER_NAME` contains `occidata` ⇒
`CUDA.functional()`) fails. The runner's `gpu` label means "can get a GPU".

### 5. On `main`, one GPU job, `kkt` unless offline

**Chosen** (45cf317): on a push to `main` or a tag, the GPU tests run **once**, on `kkt`
unless it is offline, else `occidata` ([`ci-gpu.yml`](../workflows/ci-gpu.md),
[`select-gpu-runner.yml`](../workflows/select-gpu-runner.md)). On a pull request both
remain available by label.

- **Once, not on both**: `main` would only wait for the slower runner, for the same answer.
- **Only *offline* counts, not busy**: `kkt`'s queue is shorter than a cold `occidata` run.
- **Unknown is offline**: without the secrets, or when the API call fails, the fallback is
  chosen with a warning. Slower, never stuck ([principle 7](../principles.md#7-in-doubt-the-safe-side)).

**Cost**: the state is read once; a runner that goes offline afterwards leaves the job
queued until the caller's timeout.

### 6. Reading the runners: from a token to an App

`GITHUB_TOKEN` cannot list the organization's runners.

**First** (45cf317): a personal token, `RUNNERS_STATUS_TOKEN`, with a weekly workflow
checking its expiry (85de322).

**Chosen** (db65817): the App **`ct-runners`**, whose only permission is *Self-hosted
runners: read*, minting a one-hour token in the `select` job. No token to renew, so the
expiry check went; a leaked key reveals the state of the runners and nothing else. A
separate App rather than `ct-prune-compat`: one App per kind of power
([who acts in a release § 3](release-identities.md#3-a-second-app-not-ct-prune-compat)
gives the same reasoning). Its secrets are organization secrets visible to every
repository, so a new package needs nothing.

### 7. ct-registry, and what a release must not need

Some packages depend on betas registered in `ct-registry`. The CI adds it when the caller
asks, with `SSH_KEY`, or from its public HTTPS URL for a pull request from a fork, which has
no secret (2a9c091: a fork's pull request runs the CI instead of failing). On a pull request
that sets a **stable** version, it is **not** added (`release.jl stable-release`), so that
the CI sees what users will get from General (`REL4`); breakage keeps it
(`skip_on_stable: 'false'`), since the dependents may need betas of their own.

### 8. Newest versions on CompatHelper pull requests, except on Julia 1.10

`force_latest_compatible_version: auto` tests a CompatHelper or Dependabot pull request
with the newest versions it allows, which is the point of such a pull request. On Julia
1.10, Pkg forces the latest registered version without checking its Julia compatibility
(JET 0.12 needs 1.11), and resolution fails: the option is off there (CTActions#93).

## Known limits

- `ci.yml`, `ci-gpu.yml` and `select-gpu-runner.yml` have **no tests of their own**: they are
  linted, and exercised by every package's runs, which find a regression after it is merged
  ([principle 3](../principles.md#3-every-tool-is-tested-every-workflow-linted)).
- `pinwheel` (AMD) is registered and unused: the stack is CUDA only.
- The runners' maintenance lives in CTActions; the runners' own configuration (SLURM
  scripts, instances) in control-toolbox/occidata.

## Timeline

| Date | Change | Answer to |
| --- | --- | --- |
| 2026-07-30 | Windows: Pkg's CLI git, Git's OpenSSH (0184adf, c4941b8) | ct-registry unreachable from Windows |
| 2026-08-24 | depot path from Julia, purge and retry (c61998d) | stale `compiled/` breaking precompilation on `occidata` |
| 2026-08-29 | `TMPDIR` off `/tmp` (2f00b67) | `occidata` wipes `/tmp` hourly |
| 2026-09-28 | `occidata` idles on CPU, GPU per step (CTActions#79) | a GPU held for a week, idle |
| 2026-10-15 | newest versions on CompatHelper, not on 1.10 (CTActions#93) | resolution failures on 1.10 |
| 2026-10-19 | native architecture (234e313) | `x64` forced on Apple Silicon |
| 2026-10-20 | `kkt` unless offline (45cf317); `ct-runners` App (db65817); forks run the CI (2a9c091) | two GPU runs on `main`; a token to renew; forks failing on secrets |
| 2026-11-05 | optional test artifacts, `fail_fast` input | reports per platform |
| 2026-11-10 | the CI dispatched by label | see [pull-request triggers](pull-request-triggers.md) |
