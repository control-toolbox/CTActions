# `occidata-runner-watchdog.yml`: restart the `occidata` runners

[← Workflows of control-toolbox](../README.md)

Runs in CTActions on `ubuntu-latest`, every day at 03:15 UTC and by hand
(`workflow_dispatch`). No package calls it.

Occidata hosts one runner per GitHub organization (control-toolbox, ocourses), each in its
own 7-day SLURM job. Over SSH, the watchdog runs `scripts/start_runners.sh`
(control-toolbox/occidata), which starts every instance listed in `runners.conf` whose
SLURM job is neither pending nor running, and never starts a duplicate. The SLURM queue is
the source of truth, hence no GitHub-side status check (runners of the other organization
could not be listed with this organization's token anyway).

| Secret (CTActions) | |
| --- | --- |
| `OCCIDATA_SSH_KEY` | Private SSH key authorized for `ocots@occidata-cluster.irit.fr` |
| `OCCIDATA_KNOWN_HOSTS` | Pinned `known_hosts` entry for `occidata-cluster.irit.fr` |

Without the secrets the job skips the restart and passes. With them, an unreachable
cluster fails the job (`StrictHostKeyChecking=yes`, `BatchMode=yes`).
