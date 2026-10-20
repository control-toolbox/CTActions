# The organization's GitHub App: `ct-prune-compat`

[← Workflows of control-toolbox](../README.md)

`ct-prune-compat` is a GitHub App owned by the control-toolbox organization. A
workflow that must act **beyond its own repository** (push a branch, open a PR, keep an
issue in another repository) does it as this App: its commits, PRs and comments are
signed `ct-prune-compat[bot]`. Today one workflow uses it, the
[`[compat]` prune](../workflows/compat-prune.md); the App is meant to serve others.

## Why an App

| | `GITHUB_TOKEN` | Personal access token | GitHub App |
| --- | --- | --- | --- |
| Reaches other repositories | no, its own only | yes, everything its owner can | yes, the repositories it is installed on |
| Its PRs and pushes trigger workflows | **no** | yes | yes |
| Tied to a person | no | **yes**: leaves with them, acts as them | no |
| Lifetime | the job | until revoked (often long) | **one hour**, minted per job |
| Permissions | per workflow (`permissions:`) | broad scopes | fine-grained, chosen per App, narrowed per token |

The second row matters as much as the first: a PR opened with `GITHUB_TOKEN` runs no CI,
whereas the prune's PRs (CTBase.jl#611, for instance) run the package's checks like any
other PR.

## Configuration

| Item | Value |
| --- | --- |
| Public page | <https://github.com/apps/ct-prune-compat> |
| Settings (organization owners) | <https://github.com/organizations/control-toolbox/settings/apps/ct-prune-compat> |
| Installation | control-toolbox, **selected repositories** (9): CTBase.jl, CTParser.jl, CTModels.jl, CTLie.jl, CTFlows.jl, CTDirect.jl, CTSolvers.jl, OptimalControl.jl (the packages the prune writes to) **and CTActions** (its tracking issue) |
| Repository permissions | Contents: read and write · Pull requests: read and write · Issues: read and write · Metadata: read |
| Webhook | none |
| Bot user | `ct-prune-compat[bot]`, id `343432246` (commit e-mail `343432246+ct-prune-compat[bot]@users.noreply.github.com`) |
| Secrets | organization secrets `CT_PRUNE_COMPAT_CLIENT_ID` (the App's client ID) and `CT_PRUNE_COMPAT_PRIVATE_KEY` (a private key, PEM), visible to **CTActions only** |

No *Workflows* permission: nothing it does today edits `.github/workflows/`, and GitHub
refuses a push touching that directory without it.

## Using it in a workflow

Mint a token at the start of the job that writes, and use it for that job only:

```yaml
jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      contents: read          # GITHUB_TOKEN stays read-only: the App token does the writing
    steps:
      - uses: actions/create-github-app-token@v3.3.0
        id: app
        with:
          client-id: ${{ secrets.CT_PRUNE_COMPAT_CLIENT_ID }}
          private-key: ${{ secrets.CT_PRUNE_COMPAT_PRIVATE_KEY }}
          owner: control-toolbox
          # narrow the token to what this job needs (default: every installed repository)
          repositories: CTBase.jl,OptimalControl.jl
          # and, optionally, to fewer permissions than the App has
          permission-contents: write
          permission-pull-requests: write

      - name: Push and open the PR
        env:
          GH_TOKEN: ${{ steps.app.outputs.token }}
        run: |
          gh auth setup-git      # git over HTTPS with the token
          git -c user.name='ct-prune-compat[bot]' \
              -c user.email='343432246+ct-prune-compat[bot]@users.noreply.github.com' \
              commit -am "…"
          git push origin HEAD:my-branch
          gh api --method POST repos/control-toolbox/CTBase.jl/pulls \
            -f title="…" -f head=my-branch -f base=main -f body="…"
```

- **The secrets must be visible to the repository the workflow runs in.** They are
  visible to CTActions only; a workflow elsewhere needs them extended to its repository
  (below). A reusable workflow receives them from its caller (`secrets:`), as
  `compat-prune.yml` does from `compat-prune-monthly.yml`.
- **Prefer the REST API (`gh api`) to the `gh issue` / `gh pr` commands for writes.**
  `gh issue edit` is refused to an App token ("Resource not accessible by integration",
  first live prune run) where `PATCH repos/<repo>/issues/<n>` is accepted.
- The token is revoked at the end of the job by `create-github-app-token`.

## Extending it

All of this is done by an organization owner, in the App's settings or the
organization's.

**A new repository.** Organization settings → *GitHub Apps* → `ct-prune-compat` →
*Configure* → *Repository access* → add it. Nothing else changes: tokens minted without
`repositories:` now include it. Every repository a workflow writes to must be there,
**the repository of its issues included**: an App token can open an issue on any public
repository, but not edit it afterwards (HTTP 403). This is how CTActions, missing from the
first installation, made the prune fail after it had created its tracking issue. The
prune now passes its exact list to `repositories:`, so a missing repository fails the
token step before anything is published (CTActions#101).

**A new permission** (say *Workflows*, or *Actions*). App settings → *Permissions and
events* → change it → save. The installation keeps the old permissions until an
organization owner **accepts the request** (organization settings → *GitHub Apps* →
review the pending request). A permission added to the App is available to every
workflow that uses it: narrow each token (`permission-*` inputs) so that a job that does
not need it does not get it.

**Another repository running a workflow with the App.** Extend the secrets' visibility,
in the organization settings → *Secrets and variables* → *Actions*, or:

```bash
# the list replaces the previous one: name every repository
gh secret set CT_PRUNE_COMPAT_CLIENT_ID   --org control-toolbox --visibility selected --repos CTActions,ct-agents --body '<client id>'
gh secret set CT_PRUNE_COMPAT_PRIVATE_KEY --org control-toolbox --visibility selected --repos CTActions,ct-agents < key.pem
```

**Outside GitHub Actions** (a server, an agent harness). The private key signs a JWT
(RS256, issuer = client ID, at most 10 minutes), exchanged for a one-hour installation
token by `POST /app/installations/<installation id>/access_tokens`, which can also take
`repositories` and `permissions` to narrow it. Any GitHub App library does both steps
(Octokit, PyGithub, `jwt` + `curl`). The key then lives outside GitHub: keep it in that
system's secret store, never in a repository.

**Rotating the key.** App settings → *Private keys* → *Generate a private key*, update
`CT_PRUNE_COMPAT_PRIVATE_KEY`, then delete the old key there. A deleted key stops working at once;
a leaked key is handled the same way, and its tokens expire within the hour.

## Security rules

- **Never mint the token in a job that runs code from a fork's PR** (`pull_request_target`
  with a checkout of the PR head): that code would get write access to the organization.
  The prune runs on a schedule and by hand, on CTActions' own code.
- One token per job that writes, narrowed to its repositories and permissions; the other
  jobs keep a read-only `GITHUB_TOKEN`.
- Never print the token; `gh` and git read it from `GH_TOKEN` and the credential helper.
- A bot PR is reviewed by a human like any other. Branch protection still applies to it,
  and the App cannot approve its own PRs.

## Future uses: AI agents (`ct-agents`)

[`ct-agents`](https://github.com/control-toolbox/ct-agents) gathers the ecosystem's AI
agents. If agents run remotely and open PRs, the App is the right kind of identity for
them: no personal token, one-hour tokens, PRs that run CI, and a clear author. Two
options:

| | Same App (`ct-prune-compat`) | A dedicated App (e.g. `control-toolbox-agents`) |
| --- | --- | --- |
| Setup | extend the secrets to `ct-agents` (or to the agents' secret store) | create and install a second App, its own secrets |
| Permissions | shared: whatever agents need (e.g. *Workflows*) every user of the App can get | its own: the prune keeps exactly its four |
| Private key | one key, in more places | two keys; a leaked agent key does not touch the prune, and is revoked without stopping it |
| History | agents and maintenance jobs share one author | "agent" and "maintenance bot" are told apart in PRs and commits |

**Recommendation: a dedicated App for agents** as soon as they need more than the
current permissions, or their key is to live outside GitHub Actions; both are likely for
remote agents. Sharing `ct-prune-compat` remains reasonable for agents running in
GitHub Actions with exactly its permissions. Either way the same rules hold: narrowed
tokens, never on untrusted code, a human merges.
