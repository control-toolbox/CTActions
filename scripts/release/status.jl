# Where a release stands, computed from the facts — GitHub and the registries — and never
# from memory: a session that stopped, a remote run, or a human, all resume from the same
# answer. Read only. Stdlib only; needs the `gh` CLI.

using TOML

@isdefined(REGISTRY_URLS) || include(joinpath(@__DIR__, "..", "shared", "versions.jl"))
# `gh`, `gh_strip`: `nothing` when the command fails (a 404, a missing release)
@isdefined(gh_strip) || include(joinpath(@__DIR__, "..", "shared", "github.jl"))

"The caller of release.yml in a package (docs/workflows/release.md)."
const RELEASE_WORKFLOW = "Release.yml"

"""
    pr_runs(repo, head, branch, fields) -> Union{String,Nothing}

The runs on the head commit `head` of a pull request whose branch is `branch`, one line per
run, `fields` (jq expressions) separated by tabs: the runs of its own events
(`pull_request`) and the ones label-dispatch.yml dispatched on its branch
(`workflow_dispatch`; docs/workflows/label-dispatch.md). The list of runs does not say which
pull request a dispatched run belongs to (`pull_requests` is empty): the branch does. The
runs of `RELEASE_WORKFLOW` are left out: it is not a check of the PR, it is what waits for
them, and its own run would always be in progress when it reads the others.
"""
function pr_runs(repo, head, branch, fields)
    sel = ".workflow_runs[] | select(.event == \"pull_request\" or (.event == \"workflow_dispatch\" and .head_branch == \"$branch\"))"
    out = gh("api", "repos/$repo/actions/runs?head_sha=$head&per_page=100",
             "--jq", "$sel | \"" * join(("\\(" * f * ")" for f in (".path", fields...)), "\t") * "\"")
    out === nothing && return nothing
    # here rather than in the jq filter, so that the tests see it
    keep = [last(split(l, '\t'; limit=2)) for l in split(out, '\n'; keepempty=false)
            if !is_release_workflow(first(split(l, '\t'; limit=2)))]
    return isempty(keep) ? "" : join(keep, '\n') * "\n"
end

"Whether the workflow `path` of a run is the release workflow, which waits for the checks and is not one."
is_release_workflow(path) = basename(first(split(path, '@'))) == RELEASE_WORKFLOW

"""
    facts(repo; version=nothing) -> NamedTuple

Everything that says where the release of `version` stands. Without `version`: the
release in progress (an open `[RELEASE] vX` issue, else an open `release/vX` PR), or the
latest release: the version on `main`, or a higher one of the registries when `main` kept
an older number (a PR that carries code may not change the version: the gate would take
it for a release PR).
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
        version = m === nothing ?
            maximum(vcat(main_version, collect(keys(registry_versions("General", name))),
                         collect(keys(registry_versions("ct-registry", name))))) :
            VersionNumber(m[1])
    end
    v = VersionNumber(version)
    kind = isbeta(v) ? :beta : :stable

    # the list, not the search: the search index lags behind a new issue by seconds or minutes
    issues = let out = gh_strip("issue", "list", "-R", repo, "--label", "release", "--state", "all", "--limit", "500",
                                "--json", "number,state,title",
                                "--jq", ".[] | select(.title == \"[RELEASE] v$v\") | \"\\(.number) \\(.state)\"")
        out === nothing || isempty(out) ? [] :
            [(x = split(l); (; number=parse(Int, x[1]), state=x[2])) for l in split(out, '\n')]
    end
    issue = isempty(issues) ? nothing : issues[1]
    mentions = issue === nothing ? 0 :
        parse(Int, something(gh_strip("issue", "view", string(issue.number), "-R", repo, "--json", "body,comments",
                                      "--jq", "[.body, .comments[].body] | map(select(test(\"$MENTION\"; \"i\"))) | length"), "0"))
    # the bot's answers on the issue: the General PR it opened, or its error
    answers = issue === nothing ? "" :
        something(gh("issue", "view", string(issue.number), "-R", repo, "--json", "comments",
                     "--jq", ".comments[] | select(.author.login == \"JuliaRegistrator\") | .body"), "")
    pr = let out = gh_strip("pr", "list", "-R", repo, "--head", "release/v$v", "--state", "all",
                            "--json", "number,state,mergeCommit,autoMergeRequest",
                            "--jq", ".[0] | select(. != null) | \"\\(.number) \\(.state) \\(.mergeCommit.oid // \"-\") \\(.autoMergeRequest != null)\"")
        out === nothing || isempty(out) ? nothing :
            (x = split(out); (; number=parse(Int, x[1]), state=x[2], merge=x[3] == "-" ? nothing : x[3], auto=x[4] == "true"))
    end
    # the comments on the merge commit: the registration may be posted there when `main` moved
    if pr !== nothing && pr.merge !== nothing
        mentions += parse(Int, something(gh_strip("api", "repos/$repo/commits/$(pr.merge)/comments", "--jq",
                                                  "[.[].body | select(test(\"$MENTION\"; \"i\"))] | length"), "0"))
        answers *= something(gh("api", "repos/$repo/commits/$(pr.merge)/comments", "--jq",
                                ".[] | select(.user.login == \"JuliaRegistrator\") | .body"), "")
    end
    # the bot's refusals (an answer without a General PR): such a mention registered nothing,
    # so REL6 does not count it; a person posts the comment again, once (CTParser 0.9.6: the
    # bot takes only a public member of the organization, never an App)
    refused = issue === nothing ? 0 :
        count(==("false"), split(something(gh_strip("issue", "view", string(issue.number), "-R", repo, "--json", "comments", "--jq",
            ".comments[] | select(.author.login == \"JuliaRegistrator\") | .body | test(\"$GENERAL_PR\")"), ""), '\n'; keepempty=false))
    if pr !== nothing && pr.merge !== nothing
        refused += count(==("false"), split(something(gh_strip("api", "repos/$repo/commits/$(pr.merge)/comments", "--jq",
            ".[] | select(.user.login == \"JuliaRegistrator\") | .body | test(\"$GENERAL_PR\")"), ""), '\n'; keepempty=false))
    end
    bot_pr = match(r"JuliaRegistries/General/(?:pull/)?(\d+)", answers)
    bot_error = !isempty(strip(answers)) && bot_pr === nothing ? first(split(strip(answers), '\n')) : nothing
    tag = gh_strip("api", "repos/$repo/commits/v$v", "--jq", ".sha")
    tag_tree = tag === nothing ? nothing : gh_strip("api", "repos/$repo/commits/v$v", "--jq", ".commit.tree.sha")
    release = gh_strip("release", "view", "v$v", "-R", repo, "--json", "isPrerelease", "--jq", ".isPrerelease")
    registry = kind === :stable ? "General" : "ct-registry"
    general, ct = registry_versions("General", name), registry_versions("ct-registry", name)
    registered = get(registry === "General" ? general : ct, v, nothing)
    # REL3: whether this stable jumps over versions that only betas explain
    below = [x for x in keys(general) if x < v]
    jump_kind = kind === :beta ? :none : jump(isempty(below) ? nothing : maximum(below), v, collect(keys(ct)))
    general_pr = kind === :beta ? nothing :
        bot_pr !== nothing ?
        let n = bot_pr[1], st = gh_strip("pr", "view", n, "-R", "JuliaRegistries/General", "--json", "state", "--jq", ".state")
            (; number=parse(Int, n), state=something(st, "OPEN"))
        end :
        let out = gh_strip("pr", "list", "-R", "JuliaRegistries/General", "--state", "all",
                           "--search", "\"New version: $name v$v\" in:title", "--json", "number,state,title",
                           "--jq", ".[] | select(.title == \"New version: $name v$v\") | \"\\(.number) \\(.state)\"")
            out === nothing || isempty(out) ? nothing :
                (x = split(first(split(out, '\n'))); (; number=parse(Int, x[1]), state=x[2]))
        end
    return (; repo, name, version=v, kind, main_version, main_sha, issue, issues=length(issues), mentions, refused, bot_error, pr, tag, tag_tree,
            release=release === nothing ? nothing : release == "true", registry, registered, general_pr, jump=jump_kind)
end

"What to do on General's PR about a jump of version (REL3): nothing when there is none."
function jump_note(f)
    j = get(f, :jump, :none)
    j === :betas ? "; the version jumps over betas (REL3): `[merge approved]` is needed on it" :
    j === :unexplained ? "; the version jumps over versions no beta explains (REL3): a human decides" : ""
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
    get(f, :issues, 1) > 1 && return blocked(2, "$(f.issues) tracking issues `[RELEASE] v$v`: keep one, close the others")
    f.issue === nothing && f.pr === nothing && f.tag === nothing &&
        return (; phase=0, state=:todo, next="preflight, then the proposal: nothing of v$v exists yet", blockers=String[])
    f.issue === nothing && return blocked(2, "v$v has a PR or a tag but no tracking issue")
    f.issue.state != "OPEN" && return blocked(2, "the tracking issue #$(f.issue.number) is closed but v$v is not registered")
    f.pr === nothing && return (; phase=3, state=:todo, next="open the release PR `release/v$v`", blockers=String[])
    f.pr.state == "CLOSED" && return blocked(3, "the release PR #$(f.pr.number) was closed without merge")
    if f.pr.state == "OPEN"
        return (; phase=4, state=:waiting,
                next="wait for the checks of #$(f.pr.number); then `release.jl ready`, and merge with `release.jl merge` (or a human merges)",
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
            return (; phase=7, state=:waiting, next="wait for General's PR #$(f.general_pr.number) to be merged" * jump_note(f), blockers=String[])
        f.general_pr.state == "CLOSED" &&
            return blocked(7, "General's PR #$(f.general_pr.number) was closed without merge")
        return (; phase=7, state=:waiting, next="General merged #$(f.general_pr.number); wait for the registry to show v$v", blockers=String[])
    end
    live = live_mentions(f)
    live > 1 &&
        return blocked(7, "the bot is mentioned $live times on #$(f.issue.number) (REL6): a human checks what was registered")
    live == 1 &&
        return (; phase=7, state=:waiting, next="the registration comment is posted: wait for the bot's answer (a minute), then rerun; never post it again",
                blockers=String[])
    get(f, :bot_error, nothing) !== nothing &&
        return blocked(7, "the bot refused the registration comment: \"$(f.bot_error)\"; never posted again by the workflow: a person posts it, once")
    # the bot registers the head of `main` when asked on the issue, the commit itself when
    # asked on the commit: once `main` moved, only the commit is right (a human decides)
    f.main_sha != f.pr.merge &&
        return (; phase=7, state=:todo, on_commit=true,
                next="`main` ($(f.main_sha)) moved past the merge commit $(f.pr.merge): with the human's go, post the registration comment on the merge commit (`register --on-commit`), once",
                blockers=String[])
    return (; phase=7, state=:todo, on_commit=false, next="post the registration comment, once, on #$(f.issue.number)", blockers=String[])
end

"The mentions of the registration bot that count (REL6): those it did not refuse."
live_mentions(f) = f.mentions - get(f, :refused, 0)

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
    row("registration mentions (issue and merge commit)", f.mentions)
    row("release PR", f.pr === nothing ? nothing : "#$(f.pr.number) $(f.pr.state)$(f.pr.auto ? ", auto-merge" : "")$(f.pr.merge === nothing ? "" : ", merged as $(f.pr.merge)")")
    row("tag `v$(f.version)`", f.tag)
    row("GitHub release", f.release === nothing ? nothing : f.release ? "pre-release" : "release")
    f.kind === :stable && row("General PR", f.general_pr === nothing ? nothing : "#$(f.general_pr.number) $(f.general_pr.state)")
    row("in $(f.registry)", f.registered === nothing ? nothing : "tree $(f.registered)")
    return String(take!(io))
end
