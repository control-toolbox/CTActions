# `auto-assign.yml`: assign new issues and PRs

[← Workflows of control-toolbox](../README.md)

Assigns every new (or reopened) issue and PR to a maintainer, with
[`pozil/auto-assign-issue`](https://github.com/pozil/auto-assign-issue). Caller:
`AutoAssign.yml`, in every package.

## Caller

```yaml
# .github/workflows/AutoAssign.yml
name: Auto Assign

on:
  issues:
    types: [opened, reopened]
  pull_request:
    types: [opened, reopened]

jobs:
  call:
    uses: control-toolbox/CTActions/.github/workflows/auto-assign.yml@main
    with:
      assignees: ocots
      numOfAssignee: 1
```

## Inputs

| Input | Required | Meaning |
| --- | --- | --- |
| `assignees` | yes | Comma-separated users (or `team:<slug>`) to pick from |
| `numOfAssignee` | yes | How many of them to assign |

No secrets: it uses `GITHUB_TOKEN` (`issues: write`, `pull-requests: write`). This
workflow reacts to `opened` on purpose: assignment is an "on creation" action (see
[Labels](../conventions/labels.md)).
