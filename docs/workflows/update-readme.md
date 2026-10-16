# `update-readme.yml`: generate the README

[← Workflows of control-toolbox](../README.md)

Regenerates `README.md` from a template in the repository and the organization's shared
texts (`ABOUT.md`, `INSTALL.md`, `CONTRIBUTING.md`, from
[control-toolbox/.github](https://github.com/control-toolbox/.github)), with a badge table,
and opens the PR `Update README (<date>)` from `bot/update-readme` when the README or
`CONTRIBUTING.md` changed. Caller: `UpdateReadme.yml`, in every package.

## Caller

The caller skips itself when the repository has no template:

```yaml
# .github/workflows/UpdateReadme.yml (OptimalControl.jl)
name: Update README with ABOUT.md and INSTALL.md

on:
  schedule:
    - cron: '0 6 * * 1'   # every Monday at 06:00 UTC
  workflow_dispatch:

jobs:
  check-template:
    runs-on: ubuntu-latest
    outputs:
      has_template: ${{ steps.check.outputs.has_template }}
    steps:
      - uses: actions/checkout@v4
      - id: check
        shell: bash
        run: |
          if [[ -f "README.template.md" ]]; then
            echo "has_template=true" >> "$GITHUB_OUTPUT"
          else
            echo "has_template=false" >> "$GITHUB_OUTPUT"
          fi

  call-shared:
    needs: check-template
    if: ${{ needs.check-template.outputs.has_template == 'true' }}
    uses: control-toolbox/CTActions/.github/workflows/update-readme.yml@main
    with:
      template_file: README.template.md
      output_file: README.md
      package_name: OptimalControl
      repo_name: control-toolbox/OptimalControl.jl
      doc_url: https://control-toolbox.org/OptimalControl.jl
      citation_badge: "[![DOI](https://zenodo.org/badge/541187171.svg)](https://zenodo.org/doi/10.5281/zenodo.13336563)"
      assignee: "ocots"
    secrets: inherit
```

## Inputs

| Input | Required | Meaning |
| --- | --- | --- |
| `template_file` | yes | The template (`README.template.md`) |
| `output_file` | yes | The generated file (`README.md`) |
| `package_name` | yes | Package name, for `INSTALL.md` and the badges |
| `repo_name` | yes | `owner/name`, for `CONTRIBUTING.md` links and the badges |
| `doc_url` | yes | Documentation URL, for the badges |
| `citation_badge` | no | Markdown of the `Citation` badge |
| `assignee` | no | User the PR is assigned to |

## The template

The template places the shared texts and the badges with HTML comments:

```markdown
<!-- INCLUDE_BADGES: Documentation, CI, Coverage, Release, License, CodeStyle -->
<!-- INCLUDE_ABOUT -->
<!-- INCLUDE_INSTALL -->
<!-- INCLUDE_CONTRIBUTING -->
```

Known badges: `Documentation`, `CI`, `Coverage`, `PackageEvaluation`, `Release`,
`Citation`, `License`, `CodeStyle`, `Downloads`. `{{PACKAGE}}` in `INSTALL.md` and
`{{REPO}}` in `CONTRIBUTING.md` are replaced; `CONTRIBUTING.md` is written to the
repository as well.
