# Whether a release PR may be merged, decided from what actually ran on its head commit —
# never from the names of checks — and its merge, only then. Stdlib only; needs `gh`.
#
# Why not the checks: a label-gated workflow runs once per label added, and a run whose jobs
# are all skipped (the label added was another one) reports success; the latest result of a
# check name is the one GitHub shows. So a check can look green while the real tests failed
# or are still running. Here, for each workflow, the latest run that executed jobs is the
# one that counts, and every job its labels call for must have run and passed.

@isdefined(facts) || include(joinpath(@__DIR__, "status.jl"))
@isdefined(GPU_LABELS) || include(joinpath(@__DIR__, "changes.jl"))

"""
    gated_jobs(workflow) -> Vector{Tuple{String,Vector{String}}}

The top-level jobs of a workflow file (its text), with the run labels named in each one
(`contains(… .labels.*.name, '<label>')`). Commented lines are ignored.
"""
function gated_jobs(workflow::AbstractString)
    jobs = Tuple{String,Vector{String}}[]
    injobs = false
    for line in eachline(IOBuffer(workflow))
        startswith(lstrip(line), "#") && continue
        if occursin(r"^jobs:\s*$", line)
            injobs = true
        elseif injobs && occursin(r"^\S", line)
            injobs = false                         # another top-level key
        elseif injobs
            m = match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
            if m !== nothing
                push!(jobs, (m[1], String[]))
            elseif !isempty(jobs)
                for l in eachmatch(r"labels\.\*\.name, '([^']+)'", line)
                    l[1] in last(jobs[end]) || push!(last(jobs[end]), l[1])
                end
            end
        end
    end
    return jobs
end

"Whether the job `name` reported by the API belongs to the workflow job `id` (`id`, `id (matrix…)`, `id / inner`)."
job_of(name::AbstractString, id::AbstractString) = name == id || startswith(name, id * " ")

"One line of the verdict: `:pass`, `:fail` or `:wait`, with the message."
verdict_line(status, message) = (; status, message)

"""
    ready(repo, pr) -> (; ready, head, branch, lines)

Whether the PR `pr` of `repo` may be merged now: open, not a draft, up to date with
`main`, without conflict; and on its head commit, for every workflow, the latest run that
executed jobs is complete and green, every job gated by a label the release needs ran and
passed (one GPU runner is enough), the release gate passed. `:wait` lines (a run in
progress, mergeability not computed yet) and `:fail` lines both make it not ready.
"""
function ready(repo::AbstractString, pr::Integer)
    lines = NamedTuple[]
    out = gh("pr", "view", string(pr), "-R", repo, "--json", "state,isDraft,headRefOid,headRefName,mergeable,labels",
             "--jq", "\"\\(.state)\\t\\(.isDraft)\\t\\(.headRefOid)\\t\\(.headRefName)\\t\\(.mergeable)\\t\\([.labels[].name] | join(\",\"))\"")
    out === nothing && return (; ready=false, head=nothing, branch=nothing, lines=[verdict_line(:fail, "cannot read PR #$pr")])
    state, draft, head, branch, mergeable, labelstr = split(strip(out), '\t'; limit=6)
    labels = filter(!isempty, split(labelstr, ','))
    state == "OPEN" || push!(lines, verdict_line(:fail, "the PR is $(lowercase(state))"))
    draft == "true" && push!(lines, verdict_line(:fail, "the PR is a draft"))
    mergeable == "CONFLICTING" && push!(lines, verdict_line(:fail, "the PR has conflicts with `main`"))
    mergeable == "UNKNOWN" && push!(lines, verdict_line(:wait, "GitHub is still computing whether the PR can be merged"))
    behind = gh_strip("api", "repos/$repo/compare/main...$head", "--jq", ".behind_by")
    behind === nothing ? push!(lines, verdict_line(:fail, "cannot compare the PR with `main`")) :
    behind == "0" ? push!(lines, verdict_line(:pass, "up to date with `main`")) :
        push!(lines, verdict_line(:fail, "$behind commit(s) of `main` are missing: update the branch, the checks run again"))

    # what the workflows call for, at the head commit
    files = split(something(gh_strip("api", "repos/$repo/contents/.github/workflows?ref=$head", "--jq", ".[].name"), ""))
    files = filter(f -> endswith(f, ".yml") || endswith(f, ".yaml"), files)
    jobs = Dict(f => gated_jobs(something(gh("api", "repos/$repo/contents/.github/workflows/$f?ref=$head",
                                             "-H", "Accept: application/vnd.github.raw"), "")) for f in files)
    gpu_present = [l for l in GPU_LABELS if l in labels]
    needed(l) = !(l in OPTIONAL_LABELS) && (!(l in GPU_LABELS) || l in gpu_present)
    gpu_jobs = any(j -> any(in(GPU_LABELS), last(j)), reduce(vcat, values(jobs); init=Tuple{String,Vector{String}}[]))
    gpu_jobs && isempty(gpu_present) &&
        push!(lines, verdict_line(:fail, "the package has GPU jobs and the PR has no GPU label (`run ci kkt-runner`, else `run ci occidata-runner`)"))

    # the runs of the head commit, per workflow, oldest first
    runs_out = something(gh("api", "repos/$repo/actions/runs?head_sha=$head&event=pull_request&per_page=100",
                            "--jq", ".workflow_runs[] | \"\\(.id)\\t\\(.path)\\t\\(.status)\\t\\(.conclusion)\""), "")
    runs = Dict{String,Vector{NamedTuple}}()
    for l in split(runs_out, '\n'; keepempty=false)
        id, path, status, conclusion = split(l, '\t')
        push!(get!(runs, basename(first(split(path, '@'))), NamedTuple[]),
              (; id=parse(Int, id), status, conclusion))
    end
    foreach(v -> sort!(v; by=r -> r.id), values(runs))

    for f in sort!(unique(vcat(files, collect(keys(runs)))))
        required = [(id, ls) for (id, ls) in get(jobs, f, []) if any(needed, ls)]
        mandatory = !isempty(required) || f == "ReleaseGate.yml"
        rs = get(runs, f, NamedTuple[])
        if any(r -> r.status != "completed", rs)
            push!(lines, verdict_line(:wait, "`$f`: a run is in progress"))
            continue
        end
        real = findlast(r -> r.conclusion != "skipped", rs)
        if real === nothing
            mandatory && push!(lines, verdict_line(:fail, "`$f`: no run executed its jobs on $(head[1:min(end, 8)]) (a missing label?)"))
            continue
        end
        run = rs[real]
        jobs_out = something(gh("api", "repos/$repo/actions/runs/$(run.id)/jobs?per_page=100",
                                "--jq", ".jobs[] | \"\\(.name)\\t\\(.conclusion)\""), "")
        ran = [(n, c) for (n, c) in (split(l, '\t'; limit=2) for l in split(jobs_out, '\n'; keepempty=false))]
        bad = [n for (n, c) in ran if !(c in ("success", "skipped", "neutral"))]
        isempty(bad) || push!(lines, verdict_line(:fail, "`$f`, run $(run.id): $(join(("`$n`" for n in bad), ", ")) did not pass"))
        missing_jobs = [id for (id, _) in required if !any(((n, c),) -> job_of(n, id) && c == "success", ran)]
        isempty(missing_jobs) ||
            push!(lines, verdict_line(:fail, "`$f`, run $(run.id): $(join(("`$j`" for j in missing_jobs), ", ")) did not run (skipped): add its label, the workflow runs again"))
        isempty(bad) && isempty(missing_jobs) &&
            push!(lines, verdict_line(:pass, "`$f`, run $(run.id): $(count(((n, c),) -> c == "success", ran)) job(s) passed"))
    end
    ok = !isempty(lines) && all(l -> l.status === :pass, lines)
    return (; ready=ok, head, branch, lines)
end

"The Markdown report of `ready`."
function ready_report(repo, pr, r)
    io = IOBuffer()
    failed = any(l -> l.status === :fail, r.lines)
    println(io, "## Merge check — $repo#$pr: ", r.ready ? "✅ ready" : failed ? "❌ not ready" : "⏳ wait", "\n")
    r.head === nothing || println(io, "Head commit `$(r.head)`, branch `$(r.branch)`.\n")
    for l in r.lines
        println(io, "- ", l.status === :pass ? "✅" : l.status === :wait ? "⏳" : "❌", " ", l.message)
    end
    return String(take!(io))
end

"""
    merge_release(repo, pr; confirm=false) -> (Bool, String)

Merge the release PR `pr` (a `release/v…` branch) when `ready` says so, with
`--match-head-commit`: GitHub refuses if the head changed since the check. Without
`confirm`, a dry run.
"""
function merge_release(repo::AbstractString, pr::Integer; confirm::Bool=false)
    r = ready(repo, pr)
    report = ready_report(repo, pr, r)
    r.branch !== nothing && startswith(r.branch, "release/v") ||
        return (false, report * "\nNot a release PR (`release/v…` branch): this command merges release PRs only.")
    r.ready || return (false, report)
    confirm || return (true, report * "\nDry run: `--confirm` merges $(r.head).")
    out = gh("pr", "merge", string(pr), "-R", repo, "--merge", "--match-head-commit", r.head)
    out === nothing && return (false, report * "\nThe merge was refused (the head changed, or a protection): run `ready` again.")
    return (true, report * "\nMerged $(r.head).")
end
