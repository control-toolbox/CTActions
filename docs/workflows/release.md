# `release.yml`: a release, from its request to its close

[← Workflows of control-toolbox](../README.md)

Runs phases 2 to 8 of a release
([ct-agents `recipes/release.md`](https://github.com/control-toolbox/ct-agents/blob/main/recipes/release.md)):
the tracking issue, the release PR, the checks, the merge, the tag, the registration, the
close. Caller: `Release.yml`. An agent (or a person) does phases 0 and 1 — the facts, the
review, the proposal a person validates — writes the **request** `.releases/vX.toml`, and
hands over. Why: an agent waiting through tens of minutes of CI burns its context for
nothing (CTModels.jl#512), and what it would do then is mechanical; the value of the agent
is in its judgment.

> **Who does what** (the agent, the workflow, you), mode by mode, is in the
> [release guide](https://github.com/control-toolbox/ct-agents/blob/main/guides/release.md#who-does-what)
> of ct-agents. This page is about the tool and the workflow.

## The request

The agent works on a branch `release/vX` from `main`:

```bash
TOOL="julia --startup-file=no CTActions/scripts/release/release.jl"
$TOOL facts --repo control-toolbox/CTParser.jl --kind stable .     # the facts, and the skeleton of the request
# … the agent reviews every candidate, writes the proposal, a person validates it …
$TOOL request --repo control-toolbox/CTParser.jl .releases/v0.9.6.toml .
```

**`facts` never judges.** It computes what can be computed — the state of the last
release and of `main`, the reference (the last stable for a stable, the last release for a
beta, `REL2`), **the expected version** (the gate's rules, `REL1`–`REL3`), `REL4`, `REL7`,
the run labels with one GPU label — and **lists the candidates** to review, the same for
every agent:

| Candidate | What the agent decides |
| --- | --- |
| `pr-N`: a merged PR that touches `src/`, `ext/`, `docs/` or `Project.toml`, cited nowhere in the changelog since the reference (nor an issue it closes or names) | forgotten, or not visible to a user? |
| `export-NAME`: exported or `public` at the reference, not any more | breaking, or renamed? |
| `dep-NAME`: a dependency added, removed, moved between `[deps]` and `[weakdeps]` | breaking? said in *Dependencies*? |
| `compat-NAME`: a `[compat]` bound changed | breaking? |

The PRs that ship nothing (`REL7`: CI, tests, pins) are listed for information, without a
verdict. `facts` writes the skeleton `.releases/vX.toml`: the agent fills `mode`,
`requested_by` (who validated) and, for each candidate, a `verdict` (`covered`, `added`:
the agent added the entry to `[Unreleased]`, `not-user-facing`) and a `note`. The proposal
goes in `.releases/vX.md`.

**`request`** checks the request against the facts computed again (the version is the
expected one, `main` has not moved, every candidate has a verdict and a note, the mode and
the requester are set, nothing mentions the registration bot), commits it with the agent's
changes to the changelog on `release/vX`, pushes, and starts `Release.yml` with the
version. The session can stop there: **`main` need not be green yet**, the workflow waits
for it. Run again, it commits nothing new and the workflow does nothing already done.

The request and the proposal go into the release PR: they are merged and stay **at the
tag**, the record of what was decided and why (the gate accepts them as release files).

## How the workflow works

Each run reads where the release stands, does the **one** next thing, and stops. Nothing
is remembered between two runs: `release.jl finish` computes everything from the facts
(`status`, `ready`, the CI of `main`, the comments of the tracking issue and their
markers), and every step is "ensure" — done once, skipped when its fact is there. The runs
queue one at a time per repository and are never cancelled: a run started twice by
mistake, late, or after a person did a step by hand goes on from where the facts are.

| Phase | Done by | On the tracking issue |
| --- | --- | --- |
| 2. Tracking issue | job `step`, in the run started with the version: only if the person who started it is a release manager and the request holds | the description, then the proposal, the review and a marker naming who started it |
| 3. Release PR | job `start`, once the CI of `main` is green at the base of the request: the request checked again, the release commit (version, `[Unreleased]` → `[X] - date`, `BREAKING.md`), the gate, the PR, closed, labelled, reopened, then the label of the mode | ✅ the PR; ❌ the CI of `main` red, the gate refusing |
| 4. Checks | the package's workflows; `release.jl ready` decides | ✅ the verdict of `ready`, or ❌ the checks that failed |
| 5. Merge | job `merge`: `release.jl merge` as the App (or a person merges) | ✅ merged as `<sha>` |
| 6. Tag, GitHub release | [`release-tag.yml`](release-tag.md), started by the merge | ✅ the tag |
| 7. Registration | job `register`: the registration comment of a stable (`release.jl register --post`), or LocalRegistry for a beta (`release.jl register-beta`) | ✅ General's PR merged, or the tree in ct-registry |
| 8. Close | job `step`: the final comment, the issue closed, the branch deleted, `release.jl audit` | the final comment; the audit, when it fails |

The comments follow
[`release-issue.md`](https://github.com/control-toolbox/ct-agents/blob/main/recipes/release-issue.md):
the progress list and the state marker, so that `release.jl audit` reads the same trail as
after an agent. A step done by hand is caught up: the comment of its phase is posted at the
next run. A stop is posted once per reason.

### The jobs

- **`step`** holds no secret. With `GITHUB_TOKEN` it runs `release.jl finish`: the issue,
  the wait for `main`, the phase comments, the stops, the final comment, the close. It
  returns the privileged action left, if any.
- **`start`**, **`merge`** and **`register`** are the only jobs with powers. They run in a
  GitHub Environment whose secrets hold the key of the App
  [`ct-release`](../conventions/github-app.md#ct-release-the-app-of-the-releases); the
  token is minted there and nowhere else. Each one computes the facts again before acting
  (`release.jl finish --act …`): an approval given hours later, or twice, does nothing
  wrong. Each ends by starting the workflow again for the next step.
- One approval at a time: an approval of the same action already asked in another run is
  not asked again; one asked for an action that is no longer the next one (a person merged
  by hand) is cancelled.

Why the App: a PR opened, or a merge made, with `GITHUB_TOKEN` starts no workflow: the PR
would run no CI, and `Release tag` would not run.

### When it runs

| Event | Why |
| --- | --- |
| `workflow_dispatch` with `version` | the start, by `release.jl request` (phase 2) |
| `workflow_dispatch` without | by hand, and by the privileged jobs when they end |
| `workflow_run: completed` of CI, Documentation, Breakage, Release gate, Release tag, on `main` or a `release/v*` branch | the CI of `main` (phase 3), the checks of the PR (phase 4), the tag |
| `pull_request: labeled` | the label of the mode (only `release: …`, never from a fork) |
| `schedule`, hourly | a heartbeat: the only wake-up when General merges its PR (no event reaches the package then), and a fallback for an event missed. A run with no open `[RELEASE]` issue ends in seconds |

## The modes

| Mode (in the request) | The jobs `start`, `merge`, `register` run in |
| --- | --- |
| `supervised` | `release` (a required reviewer): three approvals, *Review deployments* on the run — the PR, the merge, the registration |
| `autonomous` | `release-autonomous` (no reviewer) |

In phase 3 the workflow puts the label `release: supervised` or `release: autonomous` on
the PR; from then on, the label is what the workflow reads. A release PR opened by an agent
or a person (the recipe without a request) can be handed over the same way: a release
manager adds the label.

**Who may start a release.** The workflow acts only when **all** of these hold, checked
from the facts at every run:

1. the person who started it (`release.jl request`: the run's triggering actor), or who
   added the label of the mode, is in the organization variable `CT_RELEASE_MANAGERS`
   (comma-separated logins) **and** has the `admin` or `maintain` role on the repository;
   the label put by the App counts, since only the `start` job adds it, for a release a
   manager started;
2. the PR is on a `release/vX.Y.Z` branch of the repository itself (no fork);
3. in supervised mode, a required reviewer of the environment `release` approves each
   privileged job;
4. the merge is `release.jl merge`'s, which checks what actually ran on the head commit
   ([The merge](release-gate.md#the-merge)): never GitHub's auto-merge.

## Never automatic

As in the recipe, the workflow comments, waits for a person (`⏸ waiting for you` on the
issue, the reason, what to do), and goes on once the facts change:

- `main` moved past the merge commit before the registration: the registration comment
  must go on the merge commit (`release.jl register --on-commit`), after a person's go;
- a version that jumps over betas (`REL3`): `[merge approved]` on General's PR, by a
  person;
- the bot answers with an error: never posted again (`status` says *blocked*).

Any other stop condition (`status` *blocked*, the CI of `main` red, the gate refusing, a
check that failed) is a ❌ comment with the reason and the output of `status`. A person
fixes the cause; the next event, the hourly run or a run by hand goes on. `main` moved
after the request: run `facts` and `request` again.

## Caller

```yaml
# .github/workflows/Release.yml
name: Release

# A release from its request (`release.jl request`) to its close; see CTActions
# docs/workflows/release.md.

on:
  workflow_dispatch:
    inputs:
      version:
        description: 'The version whose request starts the release (empty: a wake-up)'
        required: false
        type: string
  pull_request:
    types: [labeled]
  workflow_run:
    workflows: [CI, Documentation, Breakage, Release gate, Release tag]
    types: [completed]
    branches: ['release/v*', main]
  schedule:
    - cron: '23 * * * *'

jobs:
  call:
    permissions:
      contents: write
      issues: write
      pull-requests: read
      actions: write
      checks: read
    uses: control-toolbox/CTActions/.github/workflows/release.yml@main
    with:
      version: ${{ inputs.version }}
    secrets: inherit
```

**`secrets: inherit` is required**, an exception to [passing secrets one by
one](../conventions/secrets.md): the App's key is a secret of the environments, and an
environment's secrets reach a job of a reusable workflow only when the caller inherits. A
secret passed by name would be read by the caller's job, which runs in no environment: it
would be empty, and the privileged jobs would fail at the token (the first real run did).
Only `start`, `merge` and `register` read them, after the environment's approval.

The names under `workflow_run` are the `name:` of the package's workflows. The file must be
named `Release.yml`: `release.jl ready` leaves its runs out of the checks of the PR, and
`main_state` out of the CI of `main` (it waits for them, it is not one of them).

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `version` | `''` | The version whose request starts the release; empty for a wake-up |
| `environment` | `'release'` | The environment of the privileged jobs in supervised mode |
| `autonomous_environment` | `'release-autonomous'` | The environment in autonomous mode |
| `ctactions_ref` | `'main'` | Ref of CTActions the script is checked out from |

## Setting it up

Once, by an organization owner:

1. **The App** `ct-release`: see [GitHub App](../conventions/github-app.md#ct-release-the-app-of-the-releases).
2. **The release managers**: `gh variable set CT_RELEASE_MANAGERS --org control-toolbox --visibility all --body 'ocots'`.

In each package, by an administrator of the repository:

```bash
REPO=control-toolbox/CTParser.jl
# the environments: `release` with a required reviewer, `release-autonomous` without
me=$(gh api users/ocots --jq .id)
gh api --method PUT "repos/$REPO/environments/release" --input - <<EOF
{"reviewers": [{"type": "User", "id": $me}]}
EOF
gh api --method PUT "repos/$REPO/environments/release-autonomous" --input - <<< '{}'
# the App's secrets, in each environment (not in the repository: only these jobs see them)
for env in release release-autonomous; do
  gh secret set CT_RELEASE_CLIENT_ID   -R "$REPO" --env "$env" --body '<client id>'
  gh secret set CT_RELEASE_PRIVATE_KEY -R "$REPO" --env "$env" < ct-release.private-key.pem
done
# the labels
gh label create "release: supervised" -R "$REPO" --color 0E8A16 --description "Hand phases 4 to 8 of this release PR to Release, with approvals"
gh label create "release: autonomous" -R "$REPO" --color B60205 --description "Hand phases 4 to 8 of this release PR to Release, without approvals"
```

Then add the caller. To start with supervised mode only, do not create
`release-autonomous`: GitHub then creates it empty when a job names it, without the App's
secrets, and a run in autonomous mode fails at the token, before anything is done.

**Optional: `CT_RELEASE_REGISTRATION_TOKEN`.** The registration comment of a stable is
posted as the App. Whether the registration bot takes a comment of an App is not verified
yet; if it does not, set this environment secret to a fine-grained token of a release
manager (the package, *Issues: read and write*): the comment is then posted as that
person, and the rest stays the App's.

## Not verified yet

- A comment of the App taken into account by the registration bot (see above).
- `workflow_run` started by the end of a run that was itself dispatched with
  `GITHUB_TOKEN` (the CI dispatched by [label-dispatch](label-dispatch.md)): if it is not,
  the hourly run takes over, a little later.
- The beta path end to end (control-toolbox/CTActions#132): `register-beta` is tested on
  fakes only. LocalRegistry pushes to ct-registry over HTTPS with the App's token, so the
  App must be installed on ct-registry.

## Tests

`scripts/release/test/runtests.jl` (see [release-gate.md](release-gate.md#tests)): the
candidates on a throwaway history (cited by number or by a closed issue, a squash, a PR
that ships nothing, a name no longer exported, a dependency and bounds; the same list twice),
the facts, the skeleton and `check_request` (each refusal), the release commit (and that
it is done once), the state of the CI of `main`, `finish_plan` on facts (every phase, both
modes, both kinds; phase 3 waiting for `main`, red, a requester who may not; a comment
posted once, a stop once per reason, the markers in the order the audit checks, no mention
of the bot), the opt-in (fork, branch, labels, manager, role, the App), a whole run on a
fake GitHub (the comments, the close, the audit, a second run that does nothing; nothing
without the opt-in), and `register-beta` with the commands faked.
