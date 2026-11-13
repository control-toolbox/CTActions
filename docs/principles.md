# Principles

[← Workflows of control-toolbox](README.md)

The rules CTActions follows, as they are **practised**, not as wished: each one says what
it requires, where it shows, and the exceptions that exist today, accepted or to be
fixed. Read it before adding or changing a workflow or a script, and use the
[checklist](#checklist-for-a-change) at the end when reviewing one. The page of each
workflow says how it works; the pages under [`design/`](design/) say why a theme is built
the way it is.

| # | Principle | In short |
| --- | --- | --- |
| 1 | [Centralize, then call](#1-centralize-then-call) | the logic once, in CTActions; thin callers in the packages |
| 2 | [YAML wires, scripts decide](#2-yaml-wires-scripts-decide) | every decision is a script, tested |
| 3 | [Every tool is tested, every workflow linted](#3-every-tool-is-tested-every-workflow-linted) | `scripts/<tool>/test` and its `<tool>-tests.yml`; actionlint on all |
| 4 | [Facts, not memory; derive, do not list](#4-facts-not-memory-derive-do-not-list) | recompute the state; read lists from where they live |
| 5 | [Every action is "ensure"](#5-every-action-is-ensure) | interrupted anywhere, resumed anywhere, never duplicated |
| 6 | [Expensive is opt-in, `main` runs everything](#6-expensive-is-opt-in-main-runs-everything) | labels on a pull request; full runs on `main` and tags |
| 7 | [In doubt, the safe side](#7-in-doubt-the-safe-side) | skipped is not passed; doubt runs the job or stops the release |
| 8 | [Least privilege, one identity per power](#8-least-privilege-one-identity-per-power) | `GITHUB_TOKEN` by default, an App per power, keys behind approval |
| 9 | [A person decides what a tool cannot](#9-a-person-decides-what-a-tool-cannot) | no auto-merge; approvals; decisions never made automatic |
| 10 | [Stable interfaces](#10-stable-interfaces) | inputs added with defaults; callers do not break |
| 11 | [Simple, and only what is needed](#11-simple-and-only-what-is-needed) | a mechanism answers a failure that happened |
| 12 | [Document once, link elsewhere](#12-document-once-link-elsewhere) | one page per subject; how, then why |

How they map to the usual names:

| Usual name | Here |
| --- | --- |
| **DRY** | 1 (logic once), 4 (lists derived, not copied), 12 (one page per subject), [shared code](#2-yaml-wires-scripts-decide) |
| **KISS** | 1 (thin callers), 11 |
| **YAGNI** | 11 |
| **SOLID**, single responsibility | 2 (one reusable workflow per role, one script per step) |
| **SOLID**, open/closed | 4 (a new consumer or a new label needs no change in CTActions) |
| **SOLID**, interface segregation and dependency inversion | 10 (a caller depends on inputs and secrets only, never on the steps) |
| **Testability** | 2, 3 |
| **Idempotence, resumability** | 4, 5 |
| **Fail safe, least privilege** | 7, 8, 9 |

## 1. Centralize, then call

**Rule.** The logic of a workflow lives once, in a reusable workflow of CTActions
(`on: workflow_call`, `kebab-case.yml`). A package has a caller (`PascalCase.yml`) that
says **which** workflow, on **which** events, with **which** inputs and secrets, and
nothing else. A fix is made once and reaches every package at its next run.

**Shows in.** Every workflow of the [catalog](README.md#the-workflows); the
[philosophy](README.md#the-philosophy).

**Exceptions.**
- Accepted: the workflows that only make sense in one package (TagBot, probes, benchmarks,
  JOSS), see [per-repo](workflows/per-repo.md).
- To remove: callers still on `pull_request` carry a copy of the label guard and of the
  `types:` list. [`label-dispatch.yml`](workflows/label-dispatch.md) replaces them; the
  `Labels.yml` caller is the target model.

## 2. YAML wires, scripts decide

**Rule.** A workflow file declares the triggers, the permissions, the secrets, the
environments, the concurrency, and calls steps. **Anything that decides** (which jobs run,
whether a release may be merged, what version is expected, which packages are consumers,
what a report says) is a script under `scripts/<tool>/`, which can be run and tested
outside GitHub Actions: on a laptop, by an agent, by a test.

A `run:` block that decides something, or that goes beyond some thirty lines of shell,
moves to a script. One entry point per tool, with subcommands (`release.jl status`,
`gate`, `ready`, …), and one file per step behind it.

**Shared code** goes to a place both tools own, not into the other tool's files.

**Shows in.** `scripts/release` (a CLI shared by the agent, a person and the workflows),
`scripts/compat-prune`, `scripts/breakage`, `scripts/update-readme`, `scripts/ci-main`, `scripts/label-dispatch`.

**Exceptions, to fix.**
- Long inline shell:
  `breakage-suite.yml` (≈102), `release.yml` (≈98, mostly wiring around `release.jl`)
  (CTActions#161; `update-readme.yml` is done: `scripts/update-readme`, tested).
- `breakage/report.jl` includes `release/versions.jl`: right to share, wrong place. Four
  different GitHub wrappers (`gh_api`, `gh_raw`/`gh_jq`, `api`, `gh`/`gh_strip`). Target:
  a `scripts/shared/` for the GitHub calls and the version and registry helpers
  (CTActions#160).
- `release/finish.jl` (≈410 lines) plans every phase of a release; it is the most
  likely to need splitting.

## 3. Every tool is tested, every workflow linted

**Rule.** Every directory of `scripts/` has a `test/` and a workflow `<tool>-tests.yml`
that runs it on a pull request or a push touching the tool (and by hand), on the Julia
versions it supports. A bug found in production gets a test before its fix is merged. Every
workflow passes `lint-workflows.yml` (actionlint, with shellcheck on `run:` blocks and
the runner labels of `.github/actionlint.yaml`). A mechanism of a reusable workflow that
can be exercised alone gets its own test workflow (`guard-tests.yml`).

**Shows in.** `release-tests.yml`, `compat-prune-tests.yml` (with a real dry run),
`breakage-tests.yml`, `ci-main-tests.yml`, `label-dispatch-tests.yml`, `guard-tests.yml`;
the release tests also check invariants of `release.yml` and of the caller in its
documentation.

**Exceptions.** Only linted: `ci.yml`, `documentation.yml`, `coverage.yml`,
`select-gpu-runner.yml`, `pr-status.yml`, the runner workflows. They are
exercised by every package's runs, which find a regression after it is merged. Moving
their decisions into scripts (principle 2) is what makes them testable.

## 4. Facts, not memory; derive, do not list

**Rule.** The state is recomputed from GitHub and the registries at every run, never
carried over from a previous run, a session or a comment. A list that exists somewhere
(the consumers of a package, the labels a caller gates on) is **read** from there, not
copied: a new package or a new label then needs no change in CTActions. Read lists through
the *list* APIs, not GitHub's search, whose index lags.

**Shows in.** `release.jl status` and `finish`; the consumers of the breakage suite, derived
from the `Project.toml` files; the label → workflow map of `label-dispatch.yml` and the
guards read by `release.jl ready`, both from the callers.

**Exceptions.**
- To fix: [`repositories.md`](repositories.md) is a snapshot by hand, marked as such; the
  `packages` default of `compat-prune.yml` and the installations of the Apps are kept up
  to date by hand ([recipes](recipes.md#a-new-repository), step 13).
- Accepted: a consumer that declares no dependency (an application's docs environment) is
  declared in `targets`.

## 5. Every action is "ensure"

**Rule.** Before creating something, check that it is not there; an action already done is
skipped. A run can stop anywhere and be started again, twice, late, or after a person did a
step by hand, without duplicating anything. The one thing that must happen exactly once
(the registration comment) is guarded by a command that refuses unless the facts say it is
due, and checks afterwards.

**Shows in.** The release (issue, PR, tag, comments: [design](https://github.com/control-toolbox/ct-agents/blob/main/design/release.md));
`release.yml`'s runs, queued and never cancelled.

## 6. Expensive is opt-in, `main` runs everything

**Rule.** On a pull request, the costly workflows (CI on several OSes and GPU runners,
breakage, documentation) run when a **label** asks for them; the cheap ones (spell check,
release gate) always run. A push to `main` and a tag run everything: `main` must be green.
On a pull request, a new run supersedes the previous one of the same workflow; nothing is
cancelled on `main` or a tag.

**Shows in.** [Labels](conventions/labels.md), [label-dispatch](workflows/label-dispatch.md),
[superseded runs](workflows/superseded-runs.md).

**Exception, bounded.** The label `ci on main: changes only` lets a merge run only the jobs
its files can affect; it never skips a job whose inputs changed, and any doubt runs the job
([ci on main](workflows/ci-on-main.md)).

## 7. In doubt, the safe side

**Rule.** When a tool cannot be sure, it takes the side that cannot do harm: it runs the
job, it waits, or it stops and says why. A skipped job is not a passed job; a cancelled run
is not a verdict; a verdict needs a baseline. Fail **before** acting rather than halfway:
check every precondition (the token's repositories, the request against the facts) before
the first write.

**Shows in.** `release.jl ready` reads the jobs that actually ran, not the check names; the
breakage verdict of a release requires a run on the base; the prune mints its token for
its exact repositories, so a missing installation fails before anything is published
(CTActions#101); a pull request from a fork runs with an explicit, degraded behaviour
instead of an obscure 403 ([secrets](conventions/secrets.md#pull-requests-from-a-fork)).

## 8. Least privilege, one identity per power

**Rule.** A job writes with `GITHUB_TOKEN`, restricted by `permissions:`, unless it must
reach another repository or trigger a workflow. Then it uses a **GitHub App**, one per
kind of power, with a one-hour token minted in the job that writes and narrowed to its
repositories and permissions. Keys that grant a power over a release sit in an
**Environment**, readable only after its approval. Never a secret in a job that runs a
pull request's code (`pull_request_target` with a checkout of the head). No personal token,
except where no App is accepted.

**Shows in.** [`ct-prune-compat`, `ct-release`](conventions/github-app.md),
[`ct-runners`](workflows/select-gpu-runner.md#the-github-app-ct-runners);
[who acts in a release](design/release-identities.md).

**Exception, accepted.** The registration comment of a stable is posted with a release
manager's token: the registration bot of General accepts no App
([why](design/release-identities.md#6-the-registration-comment-the-plan-that-changed)).

## 9. A person decides what a tool cannot

**Rule.** A tool decides what a rule can decide (the version, the gate, whether the checks
passed). What needs judgment or carries a risk a rule cannot weigh is a person's: the
proposal of a release, the merge in supervised mode, `[merge approved]`, a registration on
another commit than the merge. Such a decision is never made automatic later because it
became routine. GitHub's auto-merge is not used: it trusts check names.

**Shows in.** The modes of [`release.yml`](workflows/release.md#the-modes) and its
[never automatic](workflows/release.md#never-automatic) list; a bot's pull request is reviewed
like any other.

**Limit.** `enforce_admins` is off on the packages: an administrator can go around the tools.
They protect the routine, not against a deliberate bypass.

## 10. Stable interfaces

**Rule.** The interface of a reusable workflow is its inputs, its secrets and its outputs.
A new input comes with a `default:` that keeps the former behaviour; a removal or a change
of meaning updates every caller in the same change. Callers pin `@main`, so that a fix
spreads at once; secrets are passed one by one (`secrets: inherit` only where an
environment requires it). Every reusable workflow that runs a script of CTActions takes
`ctactions_ref`, so that its tests run the version under review.

**Limit, documented ([how to freeze](README.md#centralize-then-call)).** Pinning a caller to a tag of CTActions does **not**
freeze everything: inside, the reusable workflows call `guard.yml`, `pr-status.yml`,
`select-gpu-runner.yml` and the action `add-ct-registry` at `@main` (a `uses:` takes no
expression), and `ctactions_ref` defaults to `main`. CTActions has no version yet (CTActions#163).

## 11. Simple, and only what is needed

**Rule.** A mechanism is added because a failure happened or a cost was measured, and its
page says which (a run, an issue, a release). The simplest thing that prevents it wins; a
general framework waits for a second use. What is replaced is removed once its callers have
moved, with the list of who has not.

**Shows in.** The release choices each answer an observed failure
([what each safeguard answers](https://github.com/control-toolbox/ct-agents/blob/main/design/release.md#what-each-safeguard-answers));
`label-dispatch.yml` answers a run with all jobs skipped hiding, on the pull request page,
the CI still running (one run per label added, about thirty skipped jobs each);
`select-gpu-runner.yml` answers `kkt` being offline.

**Exceptions, to clear.** `WORKFLOWS.md`, a redirect page; the
section *Future uses* of [GitHub Apps](conventions/github-app.md#future-uses-ai-agents-ct-agents),
written before `ct-release` settled the question. Around labels, five mechanisms (guard,
label-dispatch, commit statuses, changes-only, superseded runs) are each justified, but
together they needed a page that shows them as one: [design: pull-request
triggers](design/pull-request-triggers.md).

## 12. Document once, link elsewhere

**Rule.** One subject, one page; elsewhere, a link. A workflow's page says how to use it
and how it behaves; why a theme is built the way it is goes to `design/`, with the
alternatives set aside, the costs and the history. A change to a workflow changes its
page and the [catalog](README.md#the-workflows) in the same pull request. The documentation
is in English; examples are copied from a real caller.

**Exceptions, to fix.** The sections *Superseded runs* and *On a push to `main`* are
repeated in four pages.

## Checklist for a change

- [ ] The logic is in CTActions; the caller only wires (1).
- [ ] What decides is a script, with tests in `scripts/<tool>/test`, run by `<tool>-tests.yml` (2, 3).
- [ ] No list copied that could be read from where it lives (4).
- [ ] Running it twice, or after a manual step, does nothing wrong (5).
- [ ] A costly job on a pull request is behind a label; `main` and tags still run it (6).
- [ ] A skipped, cancelled or missing result is never read as a success; preconditions are checked before the first write (7).
- [ ] `permissions:` is the minimum; a token is minted in the job that writes and narrowed; no secret near a pull request's code (8).
- [ ] No decision that needs a person became automatic (9).
- [ ] New inputs have a default; the callers in the packages still work (10).
- [ ] The failure this answers is named; anything it replaces has a removal plan (11).
- [ ] The workflow's page, the catalog and, for a choice, a `design/` page are updated (12).
- [ ] `lint-workflows.yml` passes.
