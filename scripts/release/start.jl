# Phases 2 and 3 of a release, from its request (`.releases/vX.toml` on the branch
# `release/vX`, written and checked by `release.jl facts` and `request`): the tracking issue,
# then, once `main` is green, the release commit, the gate and the release PR with its
# labels. Every step is "ensure": done once, skipped when its fact is there, so a run that
# comes twice goes on from where the facts are. Stdlib only; needs `git` and `gh`.

@isdefined(release_facts) || include(joinpath(@__DIR__, "prepare.jl"))

"The login of the App ct-release, whose `release: …` label on a release PR is an opt-in (it puts it in phase 3 only)."
const RELEASE_BOT = "ct-release[bot]"

"""
    authorized(repo, login, managers) -> Union{Nothing,String}

`nothing` when `login` may start a release of `repo`: one of `managers`, with a role of
`OPTIN_ROLES` on the repository; else why not.
"""
function authorized(repo::AbstractString, login, managers::AbstractString)
    login === nothing && return "nobody to check"
    allowed = managers_list(managers)
    isempty(allowed) && return "no release manager is set (organization variable `CT_RELEASE_MANAGERS`)"
    lowercase(login) in allowed || return "@$login is not a release manager"
    role = gh_strip("api", "repos/$repo/collaborators/$login/permission", "--jq", ".role_name")
    role in OPTIN_ROLES || return "the role of @$login on $repo is `$(something(role, "unknown"))`, not admin or maintain"
    return nothing
end

"""
    main_state(repo, sha) -> (; state, failed)

Whether the CI of `main` at `sha` (the base of a request) is `:green`, `:waiting` (a run in
progress) or `:red` (`failed`: the workflows whose latest run did not pass). The runs of the
release workflow itself are left out.
"""
function main_state(repo::AbstractString, sha::AbstractString)
    out = something(gh("api", "repos/$repo/actions/runs?head_sha=$sha&per_page=100", "--jq",
                       ".workflow_runs[] | select(.path | contains(\"$RELEASE_WORKFLOW\") | not) | \"\\(.id)\\t\\(.path)\\t\\(.status)\\t\\(.conclusion)\""), "")
    latest = Dict{String,Tuple{Int,String,String}}()
    for l in split(out, '\n'; keepempty=false)
        id, path, status, conclusion = split(l, '\t')
        w = basename(first(split(path, '@')))
        (!haskey(latest, w) || first(latest[w]) < parse(Int, id)) && (latest[w] = (parse(Int, id), status, conclusion))
    end
    any(x -> x[2] != "completed", values(latest)) && return (; state=:waiting, failed=String[])
    failed = sort!([w for (w, x) in latest if !(x[3] in ("success", "skipped", "neutral"))])
    return (; state=isempty(failed) ? :green : :red, failed)
end

"The request of `version` in the clone `dir`, parsed, and its proposal."
function read_request(dir, version)
    toml, md = request_paths(version)
    return TOML.parsefile(joinpath(dir, toml)), read(joinpath(dir, md), String)
end

"The table of the verdicts of a request, in Markdown."
function review_table(r)
    rows = get(r, "review", [])
    isempty(rows) && return "No candidate to review."
    return "| Candidate | Verdict | Note |\n| --- | --- | --- |\n" *
        join(("| `$(x["id"])`: $(replace(get(x, "what", ""), "|" => "\\|")) | $(x["verdict"]) | $(replace(get(x, "note", ""), "|" => "\\|")) |" for x in rows), '\n')
end

"""
    open_issue(repo, dir, version; actor, managers) -> (Bool, String)

Phase 2: the tracking issue `[RELEASE] vX` of the request checked out in `dir`, and its
first comment, the proposal as validated, with the verdicts and a marker naming who
started it (`by=`) and the base of the request (`base=`). Only when `actor`, who started
the run, is a release manager and the request passes `check_request`. Nothing when the issue
exists.
"""
function open_issue(repo::AbstractString, dir, version; actor, managers::AbstractString)
    v = VersionNumber(version)
    f = facts(repo; version=v)
    f.issue === nothing || return (true, "the tracking issue #$(f.issue.number) exists")
    why = authorized(repo, actor, managers)
    why === nothing || return (false, "not started: $why")
    path = request_paths(v)[1]
    problems = check_request(dir, path; repo)
    isempty(problems) || return (false, "the request is not ready:\n" * join(("- $p" for p in problems), '\n'))
    r, proposal = read_request(dir, v)
    rel = r["release"]
    mode = Symbol(rel["mode"])
    body = """
        Release of $(f.name) v$v ($(f.kind)), requested in [`$path`](https://github.com/$repo/blob/release/v$v/$path) and validated by `$(rel["requested_by"])`; run by the `Release` workflow of CTActions, following [ct-agents/recipes/release.md](https://github.com/control-toolbox/ct-agents/blob/main/recipes/release.md). Progress is in the comments below, one per phase; each one repeats the steps, marked as far as they went.

        ## Steps

        $(progress(f, mode, 0))
        """
    path_body, io = mktemp(); write(io, body); close(io)
    n = gh_strip("api", "repos/$repo/issues", "-f", "title=[RELEASE] v$v", "-F", "body=@$path_body",
                 "-f", "labels[]=release", "--jq", ".number")
    rm(path_body; force=true)
    n === nothing && return (false, "creating the tracking issue failed")
    f = facts(repo; version=v)
    comment = """
        **Phase 2 — Tracking issue.**
        Done: the tracking issue, from the request.
        Decisions: $(f.kind) `$v`, $mode, validated by `$(rel["requested_by"])`; started by `$actor`. Versions applied: ct-agents `$(r["versions"]["ct_agents"])`, ct-conventions `$(r["versions"]["ct_conventions"])`, CTActions `$(r["versions"]["ctactions"])`.
        Check: `release.jl request` → the request is complete (expected version, a verdict for every candidate).
        Next: the release PR, once the CI of `main` is green on `$(rel["base"])`$(mode === :supervised ? ", after an approval of the environment `release`" : "").

        <details><summary>The proposal</summary>

        $proposal
        </details>

        <details><summary>The review of the candidates</summary>

        $(review_table(r))
        </details>

        $(progress(f, mode, 2))
        $(replace(marker(f, mode, 2, "done"), " -->" => " by=$actor base=$(rel["base"]) -->"))
        """
    url = post_comment(repo, parse(Int, n), comment)
    url === nothing && return (false, "the issue #$n is open, but its first comment failed: run again")
    return (true, "opened #$n and posted the proposal ($url)")
end

"""
    apply_release!(dir, version, date) -> Vector{String}

The release commit's edits, mechanical: `version` in `Project.toml`; the `[Unreleased]` entries
of `CHANGELOG.md` under `## [version] - date`, an empty `[Unreleased]` on top; in `BREAKING.md`,
the `Unreleased` heading named after the version. The files changed; none when done already.
"""
function apply_release!(dir, version::VersionNumber, date::Date)
    changed = String[]
    function edit(file, f)
        p = joinpath(dir, file)
        isfile(p) || return
        old = read(p, String)
        new = f(old)
        new == old || (write(p, new); push!(changed, file))
    end
    edit("Project.toml", s -> replace(s, r"^version = \"[^\"]*\""m => "version = \"$version\""; count=1))
    edit("CHANGELOG.md", s -> occursin("## [$version]", s) ? s :
         replace(s, r"^## \[Unreleased\][^\n]*\n"m => "## [Unreleased]\n\n## [$version] - $date\n"; count=1))
    edit("BREAKING.md", s -> replace(replace(s, r"^## \[?Unreleased\]?[ \t]*$"m => "## [$version] - $date"; count=1),
                                     "Non-breaking note (Unreleased)" => "Non-breaking note ($version)"))
    return changed
end

"""
    start(repo, dir; version) -> (Bool, String)

Phase 3, in the job of the environment (the App's token, for a PR that runs the CI): in the
clone `dir` of `release/vX`, the request checked again, the release commit pushed, the gate,
the PR opened, closed, labelled and reopened (one run per workflow, as in the recipe), the
comment of phase 3, the label of the mode. Each step is skipped when its fact is there. A
failure is a stop comment on the issue.
"""
function start(repo::AbstractString, dir; version)
    v = VersionNumber(version)
    io = IOBuffer()
    f = facts(repo; version=v)
    f.issue === nothing && return (false, "no tracking issue `[RELEASE] v$v`: the release was not started")
    r, _ = read_request(dir, v)
    mode = Symbol(r["release"]["mode"])
    ms = markers(issue_comments(repo, f.issue.number))
    function stop(reason)
        c = stop_comment(f, phase(f), mode, 3, reason)
        isempty(ms) || last(ms).why != c.why ? post_comment(repo, f.issue.number, c.body) : nothing
        println(io, "❌ ", reason)
        return (false, String(take!(io)))
    end
    if f.pr === nothing
        problems = check_request(dir, request_paths(v)[1]; repo)
        isempty(problems) || return stop("the request does not hold any more: " * join(problems, "; "))
        files = apply_release!(dir, v, Dates.today())
        if !isempty(files)
            git(dir, "add", "--", files...) === nothing && return stop("`git add` failed")
            git(dir, "commit", "-q", "-m", "chore: prepare $(f.name) v$v release") === nothing && return stop("`git commit` failed")
            println(io, "- release commit: ", join(files, ", "))
        end
        git(dir, "push", "-q", "origin", "HEAD:release/v$v") === nothing && return stop("`git push` of `release/v$v` failed")
        labels = String.(get(get(r, "facts", Dict()), "labels", String[]))
        results = gate(dir, "origin/main"; labels)
        bad = [x.message for x in results if x.status === :fail]
        isempty(bad) || return stop("the release gate refuses: " * join(bad, "; "))
        println(io, "- the gate passed")
        title = "chore: prepare $(f.name) v$v release"
        body = "Release of $(f.name) v$v ($(f.kind)), requested in `$(request_paths(v)[1])`. Refs #$(f.issue.number).\n\nOpened by the `Release` workflow of CTActions; the tracking issue follows each phase.\n"
        bp, bio = mktemp(); write(bio, body); close(bio)
        n = gh_strip("api", "repos/$repo/pulls", "-f", "title=$title", "-f", "head=release/v$v", "-f", "base=main",
                     "-F", "body=@$bp", "--jq", ".number")
        rm(bp; force=true)
        n === nothing && return stop("opening the release PR failed")
        # closed, labelled, reopened: one `reopened` event reads every label, one run per workflow
        gh("api", "--method", "PATCH", "repos/$repo/pulls/$n", "-f", "state=closed")
        isempty(labels) || gh("api", "repos/$repo/issues/$n/labels", (x for l in labels for x in ("-f", "labels[]=$l"))...)
        gh("api", "--method", "PATCH", "repos/$repo/pulls/$n", "-f", "state=open") === nothing &&
            return stop("the PR #$n could not be reopened: reopen it by hand")
        println(io, "- opened #$n, labels $(join(labels, ", "))")
        f = facts(repo; version=v)
    end
    if !any(m -> m.phase == 3 && m.state == "done", ms)
        c = phase_comment(f, mode, 3, "Release PR";
                          done = "#$(f.pr.number): `Project.toml`, `CHANGELOG.md`, `BREAKING.md` and the request, with its run labels",
                          check = "`release.jl gate` → ready", next = "the checks of #$(f.pr.number)")
        post_comment(repo, f.issue.number, c) === nothing && return stop("the comment of phase 3 failed")
        println(io, "- posted the comment of phase 3")
    end
    label = "release: $mode"
    present = something(gh_strip("pr", "view", string(f.pr.number), "-R", repo, "--json", "labels", "--jq", "[.labels[].name] | join(\",\")"), "")
    if !(label in split(present, ','))
        gh("api", "repos/$repo/issues/$(f.pr.number)/labels", "-f", "labels[]=$label") === nothing &&
            return stop("adding `$label` to #$(f.pr.number) failed")
        println(io, "- added `$label`: the workflow finishes the release")
    end
    return (true, String(take!(io)))
end
