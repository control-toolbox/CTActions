# What the report job of breakage-suite.yml reads from and writes to GitHub around the
# report itself.
#
# usage: julia pr.jl facts    --repo OWNER/REPO --pr N
#        julia pr.jl baseline --repo OWNER/REPO --workflow FILE --sha SHA --group G --dir DIR
#        julia pr.jl comment  --repo OWNER/REPO --pr N --group G --file SUMMARY
#
# `facts` prints `base_sha=…` and `fork=true|false` (for $GITHUB_OUTPUT). `baseline`
# downloads into DIR the artifact `breakage-G` of the run of WORKFLOW on the base commit
# SHA: the newest completed run that is not a pull request's (a push to `main` or a manual
# run), which is what a release PR is compared with (REL1); none is not an error, the
# report says so. `comment` puts SUMMARY in the pull request's comment that starts with the
# marker of the group, created the first time, updated after. Exit code 0, 1 (a GitHub call
# failed), 2 (usage). Stdlib only; needs `gh`, authenticated (GH_TOKEN).

@isdefined(gh_api) || include(joinpath(@__DIR__, "..", "shared", "github.jl"))
@isdefined(marker) || include(joinpath(@__DIR__, "report.jl"))   # the marker of a comment

"`(base_sha, fork)` of pull request `pr`."
function pr_facts(repo, pr)
    base, fork = split(gh_jq("repos/$repo/pulls/$pr", "\"\\(.base.sha) \\(.head.repo.fork // false)\""))
    return (String(base), fork == "true")
end

"""
    baseline_run(repo, workflow, sha) -> Union{String,Nothing}

The id of the newest completed run of `workflow` on commit `sha` that a pull request did
not start, or `nothing`.
"""
function baseline_run(repo, workflow, sha)
    id = gh_jq("repos/$repo/actions/workflows/$workflow/runs?head_sha=$sha&status=completed&per_page=50",
               "[.workflow_runs[] | select(.event != \"pull_request\")][0].id // empty")
    return isempty(id) ? nothing : id
end

"Download the baseline of `group` into `dir`; whether there was one."
function download_baseline(repo, workflow, sha, group, dir)
    run = baseline_run(repo, workflow, sha)
    if run !== nothing && gh("run", "download", run, "--repo", repo, "--name", "breakage-$group", "--dir", dir) !== nothing
        println("Baseline: run $run on $sha")
        return true
    end
    println("No baseline for $sha")
    return false
end

"""
    upsert_comment(repo, pr, group, body) -> Symbol

Put `body` in the comment of `group` on `pr`: `:updated` when one starts with the marker of
the group, `:created` otherwise.
"""
function upsert_comment(repo, pr, group, body)
    m = marker(group)
    ids = gh!("api", "--paginate", "repos/$repo/issues/$pr/comments",
              "--jq", ".[] | select(.body | startswith(\"$(escape_string(m))\")) | .id")
    mine = split(ids, '\n'; keepempty=false)
    if isempty(mine)
        gh_api("POST", "repos/$repo/issues/$pr/comments", "body" => body)
        return :created
    end
    gh_api("PATCH", "repos/$repo/issues/comments/$(first(mine))", "body" => body)
    return :updated
end

"Parse the arguments, act; return the exit code."
function pr_main(args)
    args = collect(String, args)
    usage() = (println(stderr, """usage: julia pr.jl facts    --repo OWNER/REPO --pr N
       julia pr.jl baseline --repo OWNER/REPO --workflow FILE --sha SHA --group G --dir DIR
       julia pr.jl comment  --repo OWNER/REPO --pr N --group G --file SUMMARY"""); 2)
    isempty(args) && return usage()
    command, rest = args[1], args[2:end]
    opts = Dict{String,String}()
    while length(rest) >= 2 && startswith(rest[1], "--")
        opts[rest[1][3:end]] = rest[2]
        rest = rest[3:end]
    end
    need = Dict("facts" => ("repo", "pr"), "baseline" => ("repo", "workflow", "sha", "group", "dir"),
                "comment" => ("repo", "pr", "group", "file"))
    (haskey(need, command) && isempty(rest) && all(k -> haskey(opts, k), need[command])) || return usage()
    try
        if command == "facts"
            base, fork = pr_facts(opts["repo"], opts["pr"])
            println("base_sha=$base")
            println("fork=$fork")
        elseif command == "baseline"
            download_baseline(opts["repo"], opts["workflow"], opts["sha"], opts["group"], opts["dir"])
        else
            println(upsert_comment(opts["repo"], opts["pr"], opts["group"], read(opts["file"], String)))
        end
    catch e
        e isa ErrorException || rethrow()
        println(stderr, e.msg)
        return 1
    end
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(pr_main(ARGS))
end
