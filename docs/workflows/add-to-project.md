# `add-to-project.yml`: the organization's project board

[← Workflows of control-toolbox](../README.md)

Adds every new issue and PR to the organization's project board
([project 4](https://github.com/orgs/control-toolbox/projects/4) by default) and sets its
`Status` field. Caller: `AddToProject.yml`, in the repositories tracked on the board (see
[Repositories](../repositories.md)).

## Caller

```yaml
# .github/workflows/AddToProject.yml
name: Add to Project

on:
  issues:
    types: [opened]
  pull_request:
    types: [opened]

jobs:
  call:
    uses: control-toolbox/CTActions/.github/workflows/add-to-project.yml@main
    secrets:
      project_token: ${{ secrets.PROJECT_TOKEN }}
```

## Inputs and secrets

| Input | Default | Meaning |
| --- | --- | --- |
| `project-url` | `'https://github.com/orgs/control-toolbox/projects/4'` | The board |
| `status` | `'Todo'` | Value of its `Status` field for the new item |

| Secret | |
| --- | --- |
| `project_token` | required: a token allowed to write to the board (`PROJECT_TOKEN`); `GITHUB_TOKEN` cannot write to an organization's project |
