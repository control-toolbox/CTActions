# Who acts in a release: identities, tokens, and why

[← Workflows of control-toolbox](../README.md)

A technical record of **who signs what** during a release run by
[`release.yml`](../workflows/release.md), why each identity was chosen, what it costs, and
the plans that changed on the way. For the person who maintains the release machinery or
wonders why it needs an App *and* a personal token. The *how* (setting it up, the
caller, the jobs) is in [`release.yml`](../workflows/release.md) and
[GitHub Apps](../conventions/github-app.md); the choices of the procedure itself (the
gate, no auto-merge, the request, the modes) are in ct-agents
[`design/release.md`](https://github.com/control-toolbox/ct-agents/blob/main/design/release.md).

## In one table

| Identity | What it does in a release | Where its credential lives | Why this one |
| --- | --- | --- | --- |
| The **agent** (Claude Code, or a person), with the **developer's own** `gh` login | phases 0–1: the facts, the review, the proposal, the request `.releases/vX.toml`; `release.jl request` pushes `release/vX` and starts `Release.yml` | the developer's machine | it needs judgment, not powers: after the hand-over it holds **no** credential of the release |
| **`GITHUB_TOKEN`** of the run | job `step`: the tracking issue, the phase comments, the stops, the close; reading runs and checks | built in, one job | enough for the package's own issues; no secret needed |
| The App **`ct-release`** (`ct-release[bot]`) | jobs `start` (open the release PR, labels), `merge` (`release.jl merge`), `register-beta` (push to ct-registry) | **environment** secrets `CT_RELEASE_CLIENT_ID`, `CT_RELEASE_PRIVATE_KEY` of `release` / `release-autonomous`, in each package | its actions must **trigger workflows** (CI on the PR, `Release tag` on the merge) and reach ct-registry; tied to no person; one-hour tokens |
| A **release manager's** fine-grained PAT | job `register`: the registration comment of a **stable**, and nothing else | environment secret `CT_RELEASE_REGISTRATION_TOKEN`, same environments | the registration bot of General **refuses an App**: only a public member of the organization is accepted |
| A **person** | validates the proposal; approves the privileged jobs (supervised); `[merge approved]`; posts the registration comment when there is no PAT or the bot refused | — | the decisions no tool takes |

Two lists decide who may *start* a release, and neither is a credential: the
organization variable `CT_RELEASE_MANAGERS` (public logins) and the required reviewers of
the environment `release`.

## The choices

### 1. Not `GITHUB_TOKEN` for what must trigger something

What `GITHUB_TOKEN` pushes, opens or merges **starts no workflow** (GitHub's rule against
loops). A release PR opened with it would run no CI, so `release.jl ready` would wait
forever; a merge made with it would not start `Release tag`, so no tag, no GitHub release,
no documentation. It is also limited to its own repository, and a beta must be pushed to
ct-registry. So `GITHUB_TOKEN` keeps what triggers nothing (comments, labels, reading) and
an App does the rest. `Release tag` itself works around the same rule the other way: it
tags with `GITHUB_TOKEN`, then starts the documentation with `workflow_dispatch`, which
is allowed.

### 2. An App, not a personal token, for the powers

| | Personal token (PAT) | GitHub App |
| --- | --- | --- |
| Tied to a person | yes: leaves with them, acts as them, everything they can | no: a bot, `ct-release[bot]` |
| Lifetime | until it expires or is revoked (months) | **one hour**, minted per job |
| Scope | what was chosen at creation | narrowed **per job**: one repository, the permissions of the step (`permission-*` in `release.yml`) |
| History | the PR "by Olivier" | the PR by the bot: release and human work told apart |

The cost: an App to create and to **install on each package** (by hand, by an
organization owner), and a private key to keep and rotate.

### 3. A second App, not `ct-prune-compat`

`ct-prune-compat` already existed. A separate App because:
the release needs *Actions: read* and *Checks: read* (to read the runs before a merge)
that the prune does not; its key lives in the **packages'** environments, the prune's in
CTActions only; a leaked release key is revoked without stopping the prune, and the
reverse; commits and PRs say which automation did them. Same reasoning for `ct-runners`
(read-only, runners only). Rule of thumb: **one App per kind of power**.

### 4. The keys in an Environment, not in the repository or the organization

The App's key is an **environment secret** of `release` (supervised: a required reviewer)
and `release-autonomous` (no reviewer), in each package. Only a job that declares the
environment can read it, and only once the environment lets it run: in supervised mode,
after a person clicks *Review deployments*. Hence three jobs only (`start`, `merge`,
`register`) can mint a token, and `step`, which reads issue and PR text that anyone can
write (and which may carry injected instructions), holds no secret.

An organization secret was rejected: every workflow of every repository it is shared
with could read it, approval or not. The cost: secrets set **per package**, hence
[`scripts/release/setup.sh`](../../scripts/release/setup.sh), idempotent, run again for a
new package or a new token.

**Consequence: `secrets: inherit` in the caller.** An environment's secrets reach a job of
a reusable workflow only when the caller inherits. The first plan passed them one by one,
as every other caller does; the caller's job runs in no environment, so the values were
empty and the first real run (CTParser) failed at the token after its approval
(f707bb3). The caller is the documented exception to "secrets one by one".

### 5. An App does not know who started a run: the workflow checks it

The App only proves "this is the release automation". Who may use it is checked by the
workflow, from the facts, at every run: the actor who started the run (or added the
`release: …` label) is in `CT_RELEASE_MANAGERS` **and** has `admin` or `maintain` on the
repository; the branch is `release/vX.Y.Z` of the repository itself, never a fork. The
variable is public on purpose: who may release is not a secret, and changing it needs an
organization owner.

### 6. The registration comment: the plan that changed

**The plan.** The App would do everything, the registration comment of a stable included:
no personal token at all in the release.

**What happened.** On the first release run by the workflow (CTParser v0.9.6,
supervised), the registration bot of General **refused the App's comment**. The bot acts
only on a comment from a **public member of the organization**; `ct-release[bot]` is
not one, and an App cannot become one. There is no setting on
our side that changes this: the rule is the bot's.

**The options, and why this one.**

| Option | Verdict |
| --- | --- |
| Make the App acceptable to the bot | impossible from our side |
| Always hand the comment to a person | safe, but every stable release needs a human at the end, autonomous mode included |
| Use a release manager's PAT for this one comment | **chosen**, as the default |
| Register through another path (JuliaHub's web registrar, a self-hosted Registrator) | another service, another identity to trust, for one comment |

**What was built (43aec05, b0c5a2d).**

- The job `register` posts with `CT_RELEASE_REGISTRATION_TOKEN`, the fine-grained PAT of a
  release manager who is a **public** member of control-toolbox; the App's token is used
  for everything else in the job. The PAT is narrowed: resource owner control-toolbox, the
  released packages only, *Issues: read and write* and *Contents: read and write* (the
  comment on the merge commit when `main` moved), an expiry of at most a year.
- It is an **environment** secret, like the key: read only after the approval of the
  environment, so in supervised mode the person still controls the comment.
- **Without the PAT, or when the bot refuses**, the workflow posts the comment ready to
  copy, the bot's name broken by an apostrophe (`@'JuliaRegistrator`: the bot reacts to
  its mention even in a code block), and waits for a person to post it, without asking
  for an approval again.
- A mention the bot refused registered nothing: `status`, `register` and the audit count
  only the others, so `REL6` (one registration) still holds after a refusal.

**What it implies.** The release now depends on a person's token after all, for one
comment: it expires (renew it, run `setup.sh` again), it signs the comment with that
person's name, and it leaves with them (another release manager makes a new one). The
person must keep their membership of control-toolbox **public**. This is the one place
where the release is not "no personal token", and it is kept to its smallest scope.

### 7. The beta path keeps the App

A beta is registered in ct-registry with LocalRegistry, which pushes over HTTPS: the
App's token works there, no bot is involved. So the App must also be **installed on
ct-registry**. Tested on fakes only so far (CTActions#132).

## Which token is which

Three different "PATs" appear around the releases; they are unrelated.

| Token | Whose | For | Documented in |
| --- | --- | --- | --- |
| `CT_RELEASE_REGISTRATION_TOKEN` | a release manager, public member | the registration comment, in the workflow | [release.md](../workflows/release.md#the-registration-token) |
| The GitHub MCP server's PAT | the developer | the agent's `mcp__github__*` tools on their machine | ct-agents [`setup/github-pat.md`](https://github.com/control-toolbox/ct-agents/blob/main/setup/github-pat.md) |
| `gh` login | the developer | `release.jl` from a session (phases 0–1, the request, or a release done by hand) | ct-agents [`guides/release.md`](https://github.com/control-toolbox/ct-agents/blob/main/guides/release.md#before-you-start) |

## The cost of it all, once

- An organization owner: create `ct-release`, install it on each package and on
  ct-registry, set `CT_RELEASE_MANAGERS`.
- An administrator of each package: `setup.sh` (environments, secrets, labels), then the
  caller `Release.yml`.
- Each year at most: renew the registration PAT and run `setup.sh` again; rotate the App's
  key when needed (App settings → *Private keys*, then `setup.sh`).

## Timeline

| When | What changed | Why |
| --- | --- | --- |
| before the workflow | the agent ran phases 0–8 with the developer's `gh` login | first releases (CTBase v0.30.12, CTModels v0.20.0) |
| CTActions#154 | phases 2–8 moved to `release.yml`; the powers to the App `ct-release`, in environments | an agent waiting for the CI burns its context (CTModels.jl#512); the agent should hold no power |
| f707bb3 | `secrets: inherit` in the caller | the environment's secrets were empty when passed by name |
| 43aec05 (CTActions#155) | the registration comment by a release manager's PAT, else by hand | the bot refused the App's comment (CTParser v0.9.6) |
| b0c5a2d (CTActions#156) | `setup.sh`, the token documented | secrets per package, set the same way everywhere |
