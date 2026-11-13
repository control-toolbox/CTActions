# One approval at a time (docs/workflows/release.md): before the step asks for the approval
# of its next action, the other runs of the release workflow that wait for one are looked
# at. One that waits for the same job keeps it, and this run asks for nothing; one that
# waits for another job is stale (the step was done by hand since): it is cancelled.
# Stdlib only; needs the `gh` CLI.

@isdefined(gh_strip) || include(joinpath(@__DIR__, "..", "shared", "github.jl"))

"The job of release.yml that carries `action` (`register-beta` is a step of `register`)."
job_of(action) = action == "merge" ? "merge" : action == "start" ? "start" : "register"

"""
    workflow_path(workflow_ref) -> String

The path of the workflow in its repository, from `github.workflow_ref`
(`owner/repo/.github/workflows/Release.yml@refs/heads/main` → `.github/workflows/Release.yml`).
"""
workflow_path(workflow_ref) = join(split(first(split(workflow_ref, '@')), '/')[3:end], '/')

"Whether one of the `waiting` job names is `job` (a called job shows as `caller / job`)."
waits_for(waiting, job) = any(n -> n == job || endswith(n, "/ $job"), waiting)

lines_of(out) = split(something(out, ""), '\n'; keepempty=false)

"""
    pending(repo, workflow_ref, next, run_id) -> (; action, lines)

The action this run asks an approval for: `next`, or `none` when another run already waits
for the approval of the same job. The other waiting runs of the workflow are cancelled.
`lines` say what was done, for the job summary.
"""
function pending(repo, workflow_ref, next, run_id)
    path = workflow_path(workflow_ref)
    job = job_of(next)
    action = next
    lines = String[]
    runs = lines_of(gh_strip("api", "repos/$repo/actions/runs?status=waiting&per_page=100",
                             "--jq", ".workflow_runs[] | select(.path == \"$path\") | .id"))
    for run in runs
        run == string(run_id) && continue
        waiting = lines_of(gh_strip("api", "repos/$repo/actions/runs/$run/jobs",
                                    "--jq", ".jobs[] | select(.status == \"waiting\") | .name"))
        if waits_for(waiting, job)
            action = "none"
            push!(lines, "An approval of `$job` is already asked in run $run: not asked again.")
        else
            gh("run", "cancel", run, "-R", repo)   # gone in the meantime: nothing to cancel
            push!(lines, "Run $run waited for an approval that is no longer the next action: cancelled.")
        end
    end
    return (; action, lines)
end
