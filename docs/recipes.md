# Recipes

[← Workflows of control-toolbox](README.md)

## A new repository

1. **Start from the template.** Create the repository from `CTAppTemplate.jl` (*Use this
   template*). It contains the base-set callers.
2. **Run `setup-repo`.** Trigger *Setup Repository* (`workflow_dispatch`): it renames the
   package, regenerates the UUID, sets authors and assignees, and opens a setup PR. Merge
   it, then delete `setup-repo.yml`.
3. **Add the missing callers** of the base set: `AutoAssign.yml` (default assignee
   `ocots`) and `DocPreviewCleanup.yml` if the package has a documentation site (copy them
   from CTBase.jl).
4. **Decide on `Breakage`.** Keep `Breakage.yml` only if other ecosystem packages depend on
   this one, and fill its matrix with them; delete it for a leaf repository.
5. **Decide on `AddToProject`.** Add it (secret `PROJECT_TOKEN`) if the repository is
   tracked on the board.
6. **Set the CI inputs** of `CI.yml`: `versions`, `runs_on` (include `windows-latest`
   unless there is a reason not to; CTBase.jl is the reference caller), `use_ct_registry`.
7. **Decide on a runner split.** With GPU-dependent code to test, split `CI.yml` into a
   GitHub-hosted job and a job per self-hosted runner (`occidata`, optionally `kkt`), see
   [Runners](conventions/runners.md#split-ci). Use the labels verbatim.
8. **Gate the expensive callers** (`CI`, `Documentation`, `Breakage`) with the
   [label guard](conventions/labels.md#the-guard) and
   `types: [labeled, synchronize, reopened]`.
9. **Create the labels** the callers reference, see [Labels](conventions/labels.md#creating-the-labels).
10. **Secrets.** `SSH_KEY`, `DOCUMENTER_KEY`, `CODECOV_TOKEN`, `PROJECT_TOKEN` are
    organization secrets visible to every repository: nothing to do unless one is
    restricted.
11. **`docs/make.jl`** reads `DOCUMENTER_PUSH_PREVIEW` (`push_preview` is never
    hardcoded), see [documentation.yml](workflows/documentation.md#pr-previews).
12. **`UpdateReadme`.** Add a `README.template.md` and fill `package_name`, `repo_name`,
    `doc_url` in `UpdateReadme.yml`, or the job skips itself.
13. **The prune.** If the package joins the CT\* packages audited by the
    [`[compat]` prune](workflows/compat-prune.md), add it to the `packages` default of
    `compat-prune.yml` and to the [GitHub App](conventions/github-app.md#extending-it)'s
    installation.

### Checklist

- [ ] Created from `CTAppTemplate.jl`; `setup-repo` run and merged; `setup-repo.yml` removed.
- [ ] Base set present (CI, Coverage, Documentation, Formatter, SpellCheck, Registrable, CompatHelper, UpdateReadme, TagBot), plus AutoAssign and DocPreviewCleanup.
- [ ] `docs/make.jl` reads `DOCUMENTER_PUSH_PREVIEW`; the labels `run documentation` and `documentation push preview` exist.
- [ ] `Breakage.yml` kept **iff** the repository has downstream consumers; matrix filled.
- [ ] `AddToProject.yml` added **iff** tracked on the board.
- [ ] CI inputs set (`versions`, `runs_on` with `windows-latest`, `use_ct_registry`).
- [ ] Runner split decided **iff** the package has GPU-dependent code to test.
- [ ] Every label-gated caller uses `types: [labeled, synchronize, reopened]`, **no `opened`**.
- [ ] Trigger labels created, spelled as in [Labels](conventions/labels.md#the-vocabulary).
- [ ] `README.template.md` present and `UpdateReadme.yml` inputs filled.

## A change across the organization

- **Logic** (a step, an action version, caching, a new input): edit the **reusable**
  workflow in CTActions. Callers pin `@main`, so every repository picks it up on its next
  run. Keep inputs backward-compatible (add them with a `default:`), or update the callers
  in lockstep.
- **Triggers or inputs of one repository** (OS matrix, which labels it defines,
  `ct-registry`): edit that repository's **caller** only. The `types:` list lives in the
  caller too, so a fix such as dropping `opened` is applied once per repository and
  label-gated caller; it does not propagate through `@main`. How a label is **spelled** is
  not per repository: see [the vocabulary](conventions/labels.md#the-vocabulary).
- **A brand-new workflow:** add the reusable workflow in CTActions, add its caller to
  `CTAppTemplate.jl` (so that new repositories inherit it), then copy the caller into the
  existing repositories that need it, and add a page under `docs/workflows/` and a row
  to the [catalog](README.md#the-workflows).
- **A workflow acting on the whole organization** (writing to several repositories): put
  it in CTActions, triggered on a schedule or by hand, and write with the
  [GitHub App](conventions/github-app.md#using-it-in-a-workflow), not a personal token.
- **Disable a workflow in one repository without deleting it:** rename `X.yml` to
  `X.yml.disabled` (CTDirect.jl's Formatter).
- **Pinning:** `@main` for in-ecosystem reuse (fast propagation); pin a caller to a tag or
  a commit of CTActions for a frozen pipeline (a release branch).

### Rename a label across the organization

A label name appears twice per repository: the repository label itself and the caller's
`if:` guard. Change both together, repository by repository, since a renamed label with a
stale guard (or the reverse) silently stops triggering anything:

```bash
gh label edit "run ci cpu" --name "run ci github-runner" --repo control-toolbox/<repo>   # keeps the label on its PRs
# then the guard in .github/workflows/CI.yml of the same repository
```
