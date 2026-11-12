# `release-finish.yml`: phases 4 to 8 of a release, without an agent

[← Workflows of control-toolbox](../README.md)

Finishes a release once its PR is open: waits for the checks, merges, waits for the tag,
registers, closes. An agent or a human does phases 0 to 3 of the
[release recipe](https://github.com/control-toolbox/ct-agents/blob/main/recipes/release.md)
(proposal, tracking issue, release PR) and hands the rest over with a label. Caller:
`ReleaseFinish.yml`. Why: a local agent waiting through tens of minutes of CI is a session
burning context for nothing (CTModels.jl#512); the value of the agent is in phases 0 to 3.

> **Who does what** (the agent, the workflow, you), mode by mode, is in the
> [release guide](https://github.com/control-toolbox/ct-agents/blob/main/guides/release.md#who-does-what)
> of ct-agents. This page is about the workflow itself.

## How it works

Each run reads where the release stands, does the **one** next thing, and stops. Nothing
is remembered between two runs: `release.jl finish` computes everything from the facts
(`release.jl status`, `ready`, the comments of the tracking issue), and every action is
"ensure" — a run that comes twice, late, or after a human did a step by hand, does nothing
wrong.

| Phase | Done by | Comment on the tracking issue |
| --- | --- | --- |
| 4. Checks | the package's workflows; `release.jl ready` decides | ✅ the verdict of `ready`, or ❌ the checks that failed |
| 5. Merge | job `merge`: `release.jl merge` as the App (or a human merges) | ✅ merged as `<sha>` |
| 6. Tag, GitHub release | [`release-tag.yml`](release-tag.md), started by the merge | ✅ the tag |
| 7. Registration | job `register`: the registration comment of a stable (`release.jl register --post`), or LocalRegistry for a beta (`release.jl register-beta`) | ✅ the General PR merged, or the tree in ct-registry |
| 8. Close | job `step`: the final comment, the issue closed, the branch deleted, `release.jl audit` | the final comment; the audit, when it fails |

The phase comments follow
[`release-issue.md`](https://github.com/control-toolbox/ct-agents/blob/main/recipes/release-issue.md):
the progress list and the state marker, so that `release.jl audit` reads the same trail as
after an agent. A step done by hand is caught up: the comment of its phase is posted at
the next run.

### The jobs

- **`step`** holds no secret. With `GITHUB_TOKEN` it runs `release.jl finish`: the phase
  comments, a stop with its reason (posted once per reason), the final comment, the close.
  It returns the privileged action left, if any.
- **`merge`** and **`register`** are the only jobs with powers. They run in a GitHub
  Environment whose secrets hold the key of the App [`ct-release`](../conventions/github-app.md#ct-release-the-app-of-the-releases);
  the token is minted there and nowhere else. Each one computes the facts again before
  acting (`release.jl finish --act …`): an approval given hours later, or twice, does
  nothing wrong. Each ends by starting the workflow again (`workflow_dispatch`) for the
  next step.
- One approval at a time: when an approval of the same action is already asked in another
  run, it is not asked again; one asked for an action that is no longer the next one (a
  human merged by hand) is cancelled.

Why the App: a merge made with `GITHUB_TOKEN` starts no workflow, so `Release tag` would
not run.

### When it runs

| Event | Why |
| --- | --- |
| `pull_request: labeled` | the opt-in (only for a label `release: …`, never from a fork) |
| `workflow_run: completed` of CI, Documentation, Breakage, Release gate, Release tag | the end of a check, or the tag |
| `workflow_dispatch` | by hand, and by the privileged jobs when they end |
| `schedule`, hourly | a heartbeat: the only wake-up when General merges its PR (no event reaches the package then), and a fallback for an event missed. A run with no open `[RELEASE]` issue ends in seconds |

## The opt-in and the modes

The label on the release PR is both the opt-in and the mode:

| Label | Mode | The jobs `merge` and `register` run in |
| --- | --- | --- |
| `release: supervised` | the checkpoints of the recipe wait for a person: *Review deployments* on the run, one click | `release` (a required reviewer) |
| `release: autonomous` | no stop, except the stop conditions | `release-autonomous` (no reviewer) |

No label: the workflow does nothing, and the recipe goes on as before (an agent or a
human). Both labels: refused. In supervised mode, a human who prefers to merge the PR
themselves can: the workflow sees the merge at its next run and goes on.

**Who may opt in.** The workflow acts only when **all** of these hold, checked at every
run from the facts (the events of the PR, never its author nor the author of the issue,
whom anyone can be):

1. the person who added the label last is in the organization variable
   `CT_RELEASE_MANAGERS` (comma-separated logins), **and** has the `admin` or `maintain`
   role on the repository;
2. the PR is on a `release/vX.Y.Z` branch of the repository itself (no fork), with its
   tracking issue `[RELEASE] vX.Y.Z` open;
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

Any other stop condition (`status` *blocked*, a check that failed) is a ❌ comment with
the reason and the output of `status`. A person fixes the cause; the next event, the
hourly run or a run by hand goes on.

## Caller

```yaml
# .github/workflows/ReleaseFinish.yml
name: Release finish

# Phases 4 to 8 of a release, once a release manager adds `release: supervised` or
# `release: autonomous` to the release PR; see CTActions docs/workflows/release-finish.md.

on:
  pull_request:
    types: [labeled]
  workflow_run:
    workflows: [CI, Documentation, Breakage, Release gate, Release tag]
    types: [completed]
    branches: ['release/v*', main]
  schedule:
    - cron: '23 * * * *'
  workflow_dispatch:

jobs:
  call:
    permissions:
      contents: write
      issues: write
      pull-requests: read
      actions: write
      checks: read
    uses: control-toolbox/CTActions/.github/workflows/release-finish.yml@main
```

The names under `workflow_run` are the `name:` of the package's workflows. The file must be
named `ReleaseFinish.yml`: `release.jl ready` leaves its runs out of the checks of the PR
(it waits for them, it is not one of them).

## Inputs

| Input | Default | Meaning |
| --- | --- | --- |
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
{"reviewers": [{"type": "User", "id": $me}], "deployment_branch_policy": null}
EOF
gh api --method PUT "repos/$REPO/environments/release-autonomous" --input - <<< '{}'
# the App's secrets, in each environment (not in the repository: only these jobs see them)
for env in release release-autonomous; do
  gh secret set CT_RELEASE_CLIENT_ID   -R "$REPO" --env "$env" --body '<client id>'
  gh secret set CT_RELEASE_PRIVATE_KEY -R "$REPO" --env "$env" < ct-release.private-key.pem
done
# the labels
gh label create "release: supervised" -R "$REPO" --color 0E8A16 --description "Hand phases 4 to 8 of this release PR to Release finish, with approvals"
gh label create "release: autonomous" -R "$REPO" --color B60205 --description "Hand phases 4 to 8 of this release PR to Release finish, without approvals"
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

`scripts/release/test/runtests.jl` (see [release-gate.md](release-gate.md#tests)):
`finish_plan` on facts (every phase, both modes, both kinds; a comment posted once, a stop
once per reason, the markers in the order the audit checks, no mention of the bot), the
opt-in on a fake GitHub (fork, branch, labels, manager, role), a whole run on a fake
GitHub (the comments, the close, the audit, a second run that does nothing; nothing
without the opt-in), and `register-beta` with the commands faked.
