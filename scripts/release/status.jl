# Where a release stands, computed from the facts — GitHub and the registries — and never
# from memory: a session that stopped, a remote run, or a human, all resume from the same
# answer. Read only. Stdlib only; needs the `gh` CLI.

using TOML

@isdefined(REGISTRY_URLS) || include(joinpath(@__DIR__, "versions.jl"))

# The command runner behind `gh`: a function of the argument vector returning the standard
# output, or `nothing` when the command fails (a 404, a missing release). Tests replace it.
@isdefined(GH) || global GH = Ref{Any}(function (args)
    out = IOBuffer()
    ok = success(pipeline(`gh $args`; stdout=out, stderr=devnull))
    return ok ? String(take!(out)) : nothing
end)

gh(args...) = GH[](collect(String, args))
gh_strip(args...) = (out = gh(args...); out === nothing ? nothing : strip(out))

"The registration bot's mention, built so that it appears in no file (REL6)."
const MENTION = "@" * "JuliaRegistrator"

"""
    facts(repo; version=nothing) -> NamedTuple

Everything that says where the release of `version` stands. Without `version`: the
release in progress (an open `[RELEASE] vX` issue, else an open `release/vX` PR), or the
version on `main`.
"""
function facts(repo::AbstractString; version=nothing)
    project = TOML.parse(something(gh("api", "repos/$repo/contents/Project.toml?ref=main",
                                      "-H", "Accept: application/vnd.github.raw"), ""))
    name = project["name"]
    main_version = VersionNumber(project["version"])
    main_sha = gh_strip("api", "repos/$repo/commits/main", "--jq", ".sha")
    if version === nothing
        t = gh_strip("issue", "list", "-R", repo, "--label", "release", "--state", "open", "--json", "title",
                     "--jq", ".[].title")
        m = t === nothing ? nothing : match(r"\[RELEASE\] v(\S+)", t)
        if m === nothing
            h = gh_strip("pr", "list", "-R", repo, "--state", "open", "--json", "headRefName",
                         "--jq", ".[].headRefName | select(startswith(\"release/v\"))")
            m = h === nothing || isempty(h) ? nothing : match(r"release/v(\S+)", h)
        end
        version = m === nothing ? main_version : VersionNumber(m[1])
    end
    v = VersionNumber(version)
    kind = isbeta(v) ? :beta : :stable

    issue = let out = gh_strip("issue", "list", "-R", repo, "--label", "release", "--state", "all",
                               "--search", "\"[RELEASE] v$v\" in:title", "--json", "number,state,title",
                               "--jq", ".[] | select(.title == \"[RELEASE] v$v\") | \"\\(.number) \\(.state)\"")
        out === nothing || isempty(out) ? nothing :
            (x = split(first(split(out, '\n'))); (; number=parse(Int, x[1]), state=x[2]))
    end
    mentions = issue === nothing ? 0 :
        parse(Int, something(gh_strip("issue", "view", string(issue.number), "-R", repo, "--json", "body,comments",
                                      "--jq", "[.body, .comments[].body] | map(select(test(\"$MENTION\"; \"i\"))) | length"), "0"))
    pr = let out = gh_strip("pr", "list", "-R", repo, "--head", "release/v$v", "--state", "all",
                            "--json", "number,state,mergeCommit,autoMergeRequest",
                            "--jq", ".[0] | select(. != null) | \"\\(.number) \\(.state) \\(.mergeCommit.oid // \"-\") \\(.autoMergeRequest != null)\"")
        out === nothing || isempty(out) ? nothing :
            (x = split(out); (; number=parse(Int, x[1]), state=x[2], merge=x[3] == "-" ? nothing : x[3], auto=x[4] == "true"))
    end
    tag = gh_strip("api", "repos/$repo/commits/v$v", "--jq", ".sha")
    tag_tree = tag === nothing ? nothing : gh_strip("api", "repos/$repo/commits/v$v", "--jq", ".commit.tree.sha")
    release = gh_strip("release", "view", "v$v", "-R", repo, "--json", "isPrerelease", "--jq", ".isPrerelease")
    registry = kind === :stable ? "General" : "ct-registry"
    registered = get(registry_versions(registry, name), v, nothing)
    general_pr = kind === :beta ? nothing :
        let out = gh_strip("pr", "list", "-R", "JuliaRegistries/General", "--state", "all",
                           "--search", "\"New version: $name v$v\" in:title", "--json", "number,state,title",
                           "--jq", ".[] | select(.title == \"New version: $name v$v\") | \"\\(.number) \\(.state)\"")
            out === nothing || isempty(out) ? nothing :
                (x = split(first(split(out, '\n'))); (; number=parse(Int, x[1]), state=x[2]))
        end
    return (; repo, name, version=v, kind, main_version, main_sha, issue, mentions, pr, tag, tag_tree,
            release=release === nothing ? nothing : release == "true", registry, registered, general_pr)
end

"""
    phase(f) -> (; phase, state, next, blockers)

The phase of the release recipe (ct-agents `recipes/release.md`) that `f` (the `facts`)
puts the release in, whether it is `:todo`, `:waiting` (on someone else: checks, a bot,
a human) or `:blocked`, the next action, and what blocks it.
"""
function phase(f)
    blocked(n, why) = (; phase=n, state=:blocked, next="stop and report", blockers=[why])
    v = f.version
    # done, or registered and only the closing left
    if f.registered !== nothing
        # REL5: registered, tagged on the same tree, released on GitHub
        f.tag === nothing &&
            return blocked(6, "v$v is in $(f.registry) but has no tag `v$v` (REL5): tag the commit whose tree is $(f.registered)")
        f.registered != f.tag_tree &&
            return blocked(8, "the tree registered in $(f.registry) ($(f.registered)) is not the tree of `v$v` ($(f.tag_tree))")
        f.release === nothing &&
            return (; phase=6, state=:todo, next="create the GitHub release of the existing tag `v$v` (REL5)", blockers=String[])
        f.issue !== nothing && f.issue.state == "OPEN" &&
            return (; phase=8, state=:todo, next="post the final comment and close #$(f.issue.number)", blockers=String[])
        return (; phase=8, state=:done, next="nothing: v$v is released", blockers=String[])
    end
    f.issue === nothing && f.pr === nothing && f.tag === nothing &&
        return (; phase=0, state=:todo, next="preflight, then the proposal: nothing of v$v exists yet", blockers=String[])
    f.issue === nothing && return blocked(2, "v$v has a PR or a tag but no tracking issue")
    f.issue.state != "OPEN" && return blocked(2, "the tracking issue #$(f.issue.number) is closed but v$v is not registered")
    f.pr === nothing && return (; phase=3, state=:todo, next="open the release PR `release/v$v`", blockers=String[])
    f.pr.state == "CLOSED" && return blocked(3, "the release PR #$(f.pr.number) was closed without merge")
    if f.pr.state == "OPEN"
        return (; phase=4, state=:waiting,
                next=f.pr.auto ? "wait for the checks; GitHub merges #$(f.pr.number) when they pass" :
                     "wait for the checks of #$(f.pr.number), then merge it (or enable auto-merge)",
                blockers=String[])
    end
    # merged
    f.tag === nothing && return (; phase=6, state=:waiting,
                                 next="wait for the release-tag workflow to tag $(f.pr.merge) (or run it by hand)",
                                 blockers=String[])
    f.tag != f.pr.merge && return blocked(6, "the tag `v$v` points to $(f.tag), not to the merge commit $(f.pr.merge)")
    f.release === nothing && return (; phase=6, state=:waiting, next="wait for the GitHub release of `v$v`", blockers=String[])
    f.release != (f.kind === :beta) &&
        return blocked(6, "the GitHub release of `v$v` is $(f.release ? "" : "not ")a pre-release")
    if f.kind === :beta
        return (; phase=7, state=:todo, next="register v$v in ct-registry (LocalRegistry), from $(f.pr.merge)", blockers=String[])
    end
    # stable: the single registration comment (REL6)
    if f.general_pr !== nothing
        f.general_pr.state == "OPEN" &&
            return (; phase=7, state=:waiting, next="wait for General's PR #$(f.general_pr.number) to be merged (check the jump: `[merge approved]`)", blockers=String[])
        f.general_pr.state == "CLOSED" &&
            return blocked(7, "General's PR #$(f.general_pr.number) was closed without merge")
        return (; phase=7, state=:waiting, next="General merged #$(f.general_pr.number); wait for the registry to show v$v", blockers=String[])
    end
    f.mentions > 0 &&
        return blocked(7, "the registration comment is posted ($(f.mentions)) but General has no PR: read the bot's answer; never post it again")
    f.main_sha != f.pr.merge &&
        return blocked(7, "`main` ($(f.main_sha)) moved past the merge commit $(f.pr.merge): the bot would register another commit")
    return (; phase=7, state=:todo, next="post the registration comment, once, on #$(f.issue.number)", blockers=String[])
end

"The Markdown report of `facts` and `phase`."
function status_report(f, p)
    io = IOBuffer()
    mark = p.state === :done ? "✅" : p.state === :blocked ? "❌" : p.state === :waiting ? "⏳" : "▶️"
    println(io, "## Release status — $(f.name) v$(f.version) ($(f.kind))\n")
    println(io, "$mark **Phase $(p.phase), $(p.state)**: $(p.next).")
    for b in p.blockers
        println(io, "- ❌ $b")
    end
    println(io, "\n| Fact | Value |\n| --- | --- |")
    row(k, v) = println(io, "| $k | $(something(v, "—")) |")
    row("`main`", "$(f.main_sha) (version $(f.main_version))")
    row("tracking issue", f.issue === nothing ? nothing : "#$(f.issue.number) $(f.issue.state)")
    row("registration mentions on it", f.mentions)
    row("release PR", f.pr === nothing ? nothing : "#$(f.pr.number) $(f.pr.state)$(f.pr.auto ? ", auto-merge" : "")$(f.pr.merge === nothing ? "" : ", merged as $(f.pr.merge)")")
    row("tag `v$(f.version)`", f.tag)
    row("GitHub release", f.release === nothing ? nothing : f.release ? "pre-release" : "release")
    f.kind === :stable && row("General PR", f.general_pr === nothing ? nothing : "#$(f.general_pr.number) $(f.general_pr.state)")
    row("in $(f.registry)", f.registered === nothing ? nothing : "tree $(f.registered)")
    return String(take!(io))
end
