# Whether a job of CI, Coverage, Breakage or Documentation must run on a push to `main`.
#
# Without the label `ci on main: changes only` on the pull request that was merged, the
# answer is always yes: everything runs, as it always did. With the label, a job runs only
# if the files changed since the last time that job ran and passed on `main` can affect it.
# See docs/workflows/ci-on-main.md for the principle and the rules. Stdlib only; needs `gh`
# and `git`.
#
# usage:
#   julia changes.jl --repo OWNER/REPO --sha SHA --scope tests|coverage|breakage|docs
#                    --workflow FILE --job ID [--event push] [--ref refs/heads/main]
#                    [--run-id N] [--dir DIR]
#
# Prints `run=true|false`, `base_run=ID` (the run the diff starts from, if any) and `reason=…`, and appends them to $GITHUB_OUTPUT when set.
# Anything unexpected (no pull request found, no previous green run, a base that is not an
# ancestor, a failing command) answers `run=true`: the safe side is to run.

# The command runner behind `gh`: a function of the argument vector returning the standard
# output, or `nothing` when the command fails. Tests replace it.
@isdefined(GH) || global GH = Ref{Any}(function (args)
    out = IOBuffer()
    ok = success(pipeline(`gh $args`; stdout=out, stderr=devnull))
    return ok ? String(take!(out)) : nothing
end)

# The same for `git` in a directory; `nothing` when the command fails.
@isdefined(GIT) || global GIT = Ref{Any}(function (dir, args)
    out = IOBuffer()
    ok = success(pipeline(`git -C $dir $args`; stdout=out, stderr=devnull))
    return ok ? String(take!(out)) : nothing
end)

gh(args...) = GH[](collect(String, args))
git(dir, args...) = GIT[](dir, collect(String, args))

"The label on a pull request that asks for the changes-only mode on its merge."
const LABEL = "ci on main: changes only"

"Who may set the label: `CT_CI_CHANGES_ONLY_ACTORS` (comma-separated logins) or this list."
const DEFAULT_ACTORS = ["ocots"]

"The headline of the commit the formatter workflow makes; a pull request made only of it is formatting only."
const FORMAT_COMMIT = "Format .jl files"

"The top-level directories and files whose changes can affect each kind of job."
const SCOPES = Dict(
    "tests" => ["src/", "ext/", "test/", "Project.toml"],
    "coverage" => ["src/", "ext/", "test/", "Project.toml"],
    "breakage" => ["src/", "ext/", "Project.toml"],
    "docs" => ["docs/", "src/", "ext/", "Project.toml"],
)

"The top-level directories that belong to a scope above: a change in one of them leaves the other scopes alone."
const KNOWN_DIRS = ["src/", "ext/", "test/", "docs/"]

"Root files that change nothing a job runs: documentation and configuration of the repository."
const IGNORED = r"^(?:[^/]+\.md|\.gitignore|LICENSE|CITATION\.cff|_typos\.toml|\.markdownlint\.json|\.JuliaFormatter\.toml|formatter\.lock)$"

allowed_actors() = filter(!isempty, strip.(split(get(ENV, "CT_CI_CHANGES_ONLY_ACTORS", join(DEFAULT_ACTORS, ",")), ",")))

"""
    relevant(scope, file) -> Bool

Whether a change to `file` (a path from the root) can affect the jobs of `scope`. A file in
one of the scope's directories does; a root file of documentation or configuration, or a
directory that belongs to another scope, does not; anything else (`.github/`, a new
top-level directory) does, because we cannot tell.
"""
function relevant(scope::AbstractString, file::AbstractString)
    for p in SCOPES[scope]
        (file == p || startswith(file, p)) && return true
    end
    occursin(IGNORED, file) && return false
    any(d -> startswith(file, d), KNOWN_DIRS) && return false
    return true
end

"The pull request merged as `sha`: `(number, head_ref, labels)`, or `nothing`."
function merged_pr(repo, sha)
    out = gh("api", "repos/$repo/commits/$sha/pulls", "--jq",
             "[.[] | select(.merged_at != null and .merge_commit_sha == \"$sha\")] | .[0] // empty | " *
             "\"\\(.number)\\t\\(.head.ref)\\t\\([.labels[].name] | join(\",\"))\"")
    (out === nothing || isempty(strip(out))) && return nothing
    number, head, labels = split(rstrip(out, '\n'), '\t'; limit=3)
    return (; number=parse(Int, number), head_ref=String(head), labels=String.(split(labels, ',')))
end

"The login that last put `LABEL` on the pull request, or `nothing`."
function labeler(repo, pr)
    out = gh("api", "repos/$repo/issues/$pr/events", "--paginate", "--jq",
             ".[] | select(.event == \"labeled\" and .label.name == \"$LABEL\") | .actor.login")
    out === nothing && return nothing
    logins = filter(!isempty, strip.(split(out, '\n')))
    return isempty(logins) ? nothing : last(logins)
end

"Whether the pull request holds only formatter commits and changes only `.jl` files."
function format_only(repo, pr)
    commits = gh("api", "repos/$repo/pulls/$pr/commits", "--paginate", "--jq",
                 ".[] | .commit.message | split(\"\\n\") | .[0]")
    files = gh("api", "repos/$repo/pulls/$pr/files", "--paginate", "--jq", ".[].filename")
    (commits === nothing || files === nothing) && return false
    heads = filter(!isempty, strip.(split(commits, '\n')))
    names = filter(!isempty, strip.(split(files, '\n')))
    return !isempty(heads) && all(==(FORMAT_COMMIT), heads) && !isempty(names) && all(endswith(".jl"), names)
end

"Whether the job `name` reported by the API is the workflow job `id` (`id`, `id (matrix…)`, `caller / id (…)`)."
job_of(name::AbstractString, id::AbstractString) = occursin(Regex("(^| / )" * id * "( |\$)"), name)

"""
    last_green(repo, workflow, job, sha, run_id) -> Union{NamedTuple,Nothing}

`(; sha, run)`: the head commit, and the id, of the latest push run of `workflow` on `main` in which a job `job` ran and
every such job passed (none failed or was cancelled). A run whose jobs were all skipped does
not count: it reports success without having tested anything. The run `run_id` (the current
one) and the commit `sha` are left out.
"""
function last_green(repo, workflow, job, sha, run_id)
    runs = gh("api", "repos/$repo/actions/workflows/$workflow/runs?branch=main&event=push&status=completed&per_page=30",
              "--jq", ".workflow_runs[] | \"\\(.id)\\t\\(.head_sha)\"")
    runs === nothing && return nothing
    for line in split(strip(runs), '\n')
        isempty(line) && continue
        id, head = split(line, '\t')
        (head == sha || id == string(run_id)) && continue
        jobs = gh("api", "repos/$repo/actions/runs/$id/jobs?per_page=100", "--jq",
                  ".jobs[] | \"\\(.name)\\t\\(.conclusion)\"")
        jobs === nothing && continue
        concl = [String(c) for (n, c) in (split(l, '\t') for l in split(strip(jobs), '\n') if !isempty(l)) if job_of(n, job)]
        isempty(concl) && continue
        (any(==("failure"), concl) || any(==("cancelled"), concl)) && continue
        any(==("success"), concl) && return (; sha=String(head), run=parse(Int, id))
    end
    return nothing
end

"""
    decide(repo, sha; scope, workflow, job, event="push", ref="refs/heads/main", run_id=0, dir=".")
        -> (; run::Bool, reason::String, base_run::String)

Whether the job must run. See the file header for the rules, in order. `base_run` is the id
of the run the diff starts from (empty when there is none): a skipped Breakage run copies
its baseline from it.
"""
function decide(repo, sha; scope, workflow, job, event="push", ref="refs/heads/main", run_id=0, dir=".")
    answer(run, reason; base_run="") = (; run, reason, base_run)
    (event == "push" && ref == "refs/heads/main") || return answer(true, "not a push to main: everything runs")
    pr = merged_pr(repo, sha)
    pr === nothing && return answer(true, "no merged pull request found for $sha: everything runs")
    LABEL in pr.labels || return answer(true, "PR #$(pr.number) has no label `$LABEL`: everything runs")
    startswith(pr.head_ref, "release/") && return answer(true, "PR #$(pr.number) is a release PR ($(pr.head_ref)): everything runs")
    who = labeler(repo, pr.number)
    (who !== nothing && who in allowed_actors()) ||
        return answer(true, "the label was set by $(something(who, "nobody found")), who may not: everything runs")
    green = last_green(repo, workflow, job, sha, run_id)
    green === nothing && return answer(true, "no earlier green run of `$job` on main: everything runs")
    base, base_run = green.sha, string(green.run)
    format_only(repo, pr.number) &&
        return answer(false, "PR #$(pr.number) holds only `$FORMAT_COMMIT` commits on .jl files: nothing to run"; base_run)
    git(dir, "merge-base", "--is-ancestor", base, sha) === nothing &&
        return answer(true, "the last green base $(base[1:7]) is not an ancestor of $(sha[1:7]): everything runs")
    changed = git(dir, "diff", "--name-only", base, sha)
    changed === nothing && return answer(true, "cannot diff $(base[1:7])..$(sha[1:7]): everything runs")
    files = filter(!isempty, strip.(split(changed, '\n')))
    hit = filter(f -> relevant(scope, f), files)
    isempty(hit) && return answer(false, "since $(base[1:7]), no change can affect `$job` ($(length(files)) files, scope $scope)"; base_run)
    return answer(true, "since $(base[1:7]), $(length(hit)) of $(length(files)) files can affect `$job` (e.g. $(first(hit)))"; base_run)
end

function main(args)
    opt(name, default=nothing) = (i = findfirst(==("--$name"), args); i === nothing ? default : args[i+1])
    repo, sha, scope = opt("repo"), opt("sha"), opt("scope")
    workflow, job = opt("workflow"), opt("job")
    if any(isnothing, (repo, sha, scope, workflow, job)) || !haskey(SCOPES, scope)
        println(stderr, "usage: changes.jl --repo OWNER/REPO --sha SHA --scope $(join(sort(collect(keys(SCOPES))), '|')) --workflow FILE --job ID")
        return 2
    end
    d = decide(repo, sha; scope, workflow=basename(workflow), job, event=opt("event", "push"),
               ref=opt("ref", "refs/heads/main"), run_id=parse(Int, opt("run-id", "0")), dir=opt("dir", "."))
    println("run=$(d.run)"); println("base_run=$(d.base_run)"); println("reason=$(d.reason)")
    out = get(ENV, "GITHUB_OUTPUT", "")
    isempty(out) || open(out, "a") do io
        println(io, "run=$(d.run)"); println(io, "base_run=$(d.base_run)"); println(io, "reason=$(d.reason)")
    end
    summary = get(ENV, "GITHUB_STEP_SUMMARY", "")
    isempty(summary) || open(summary, "a") do io
        println(io, "**ci on main** — `$job`: ", d.run ? "runs" : "skipped", " — ", d.reason)
    end
    return 0
end

abspath(PROGRAM_FILE) == (@__FILE__) && exit(main(ARGS))
