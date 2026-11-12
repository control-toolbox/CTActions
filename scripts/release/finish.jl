# Phases 4 to 8 of a release without an agent: the release workflow wakes on an
# event, and this file decides, from the facts, the one next thing to do — post the phase
# comments the tracking issue lacks, stop and say why, close, or hand one privileged action
# (merge, register) to a job of the workflow that holds the App token. Nothing is
# remembered between two wake-ups: every action is "ensure", so a wake-up that comes twice,
# late or after a human did a step by hand does nothing wrong. Stdlib only; needs `gh`.

using SHA

@isdefined(facts) || include(joinpath(@__DIR__, "status.jl"))
@isdefined(ready) || include(joinpath(@__DIR__, "ready.jl"))
@isdefined(register) || include(joinpath(@__DIR__, "register.jl"))
@isdefined(audit) || include(joinpath(@__DIR__, "audit.jl"))
@isdefined(register_beta) || include(joinpath(@__DIR__, "register_beta.jl"))
@isdefined(open_issue) || include(joinpath(@__DIR__, "start.jl"))

"The labels that hand phases 4 to 8 of a release PR to the workflow, and the mode each one sets."
const OPTIN_LABELS = ("release: supervised" => :supervised, "release: autonomous" => :autonomous)

"The roles on the repository that may opt in, on top of being a release manager."
const OPTIN_ROLES = ("admin", "maintain")

"A short digest of `text`: two stop comments with the same digest say the same thing."
digest(text::AbstractString) = bytes2hex(sha1(text))[1:8]

"The logins of `managers` (comma- or space-separated), lowercase."
managers_list(managers::AbstractString) = [lowercase(m) for m in split(managers, r"[,\s]+") if !isempty(m)]

"""
    optin(repo, pr, managers) -> (; mode, actor, reason)

Whether the release PR `pr` is handed to the workflow, and in which mode: the PR comes from
a `release/v…` branch of `repo` itself (no fork), carries exactly one label of
`OPTIN_LABELS`, and the person who added it last is one of `managers` and has a role of
`OPTIN_ROLES` on `repo` — or is the App (`RELEASE_BOT`), which adds it in phase 3 of a
release started by a manager. Read from the PR's events, never from the author of the PR
or of the issue, whom anyone can be. `mode === nothing` (with the reason) when it is not.
"""
function optin(repo::AbstractString, pr::Integer, managers::AbstractString)
    no(reason) = (; mode=nothing, actor=nothing, reason)
    out = gh("pr", "view", string(pr), "-R", repo, "--json", "isCrossRepository,headRefName,labels",
             "--jq", "\"\\(.isCrossRepository)\\t\\(.headRefName)\\t\\([.labels[].name] | join(\",\"))\"")
    out === nothing && return no("cannot read PR #$pr")
    cross, branch, labelstr = split(strip(out), '\t'; limit=3)
    cross == "false" || return no("#$pr comes from a fork")
    startswith(branch, "release/v") || return no("#$pr is not on a `release/v…` branch")
    present = [(l, m) for (l, m) in OPTIN_LABELS if l in split(labelstr, ',')]
    isempty(present) && return no("#$pr has no label `release: supervised` or `release: autonomous`: the release is the agent's or the human's")
    length(present) > 1 && return no("#$pr has both `release: supervised` and `release: autonomous`: remove one")
    label, mode = only(present)
    events = gh_strip("api", "repos/$repo/issues/$pr/events", "--paginate", "--jq",
                      ".[] | select(.event == \"labeled\" and .label.name == \"$label\") | .actor.login")
    actor = events === nothing || isempty(events) ? nothing : String(last(split(events, '\n')))
    actor === nothing && return no("cannot tell who added `$label` to #$pr")
    actor == RELEASE_BOT && return (; mode, actor, reason="")
    why = authorized(repo, actor, managers)
    why === nothing || return no("`$label` was added by @$actor: $why")
    return (; mode, actor, reason="")
end

"The comments of issue `n`, `(author, time, body)`, oldest first."
function issue_comments(repo::AbstractString, n::Integer)
    out = something(gh("api", "repos/$repo/issues/$n/comments", "--paginate", "--jq",
                       ".[] | [.user.login, .created_at, (.body | @base64)] | @tsv"), "")
    return [(; author=String(x[1]), time=String(x[2]), body=String(base64decode(x[3])))
            for x in (split(l, '\t') for l in split(out, '\n'; keepempty=false)) if length(x) == 3]
end

"""
    progress(f, mode, done; stopped=nothing, links=Dict()) -> String

The progress list of `release-issue.md` (ct-agents): ✅ on the steps of the phases up to
`done`, ❌ on the step of phase `stopped` (with the reason), nothing on the others. `links`
maps a phase to what follows its step (a PR, a commit, a URL).
"""
function progress(f, mode, done::Integer; stopped=nothing, links=Dict{Int,String}())
    steps = Tuple{Int,String}[(1, "Proposal validated: $(f.kind) `$(f.version)`, $mode")]
    f.kind === :stable && push!(steps, (1, "Resolves from General alone (`REL4`)"))
    append!(steps, [(3, "Release PR opened, the gate passed locally — `Project.toml`, `CHANGELOG.md`, `BREAKING.md`"),
                    (4, "Checks green (`release.jl ready`): CI, documentation, breakage, the gate"),
                    (5, "Release PR merged"),
                    (6, "Tag and GitHub release; documentation of the tag"),
                    (7, "Registered in $(f.registry)"),
                    (8, "Issue closed")])
    lines = map(steps) do (n, text)
        mark = stopped !== nothing && n == first(stopped) ? "❌ " : n <= done ? "✅ " : ""
        extra = stopped !== nothing && n == first(stopped) ? ": " * last(stopped) :
                haskey(links, n) && n <= done && !(n == 1 && occursin("REL4", text)) ? " — " * links[n] : ""
        "- $mark$text$extra"
    end
    return join(lines, '\n')
end

"The state marker of `release-issue.md`, with the digest `why` of a stop or a wait."
marker(f, mode, n, state; why="") =
    "<!-- ct-release phase=$n kind=$(f.kind) version=$(f.version) mode=$mode " *
    "pr=$(f.pr === nothing ? "-" : f.pr.number) merge=$(f.pr === nothing ? "-" : something(f.pr.merge, "-")) " *
    "state=$state$(isempty(why) ? "" : " why=$why") -->"

"The links of the progress list that the facts give."
function progress_links(f)
    links = Dict{Int,String}()
    f.pr === nothing || (links[3] = "#$(f.pr.number)")
    f.pr === nothing || f.pr.merge === nothing || (links[5] = f.pr.merge)
    f.tag === nothing || (links[6] = "https://github.com/$(f.repo)/releases/tag/v$(f.version)")
    if f.registered !== nothing
        links[7] = f.kind === :stable && f.general_pr !== nothing ?
            "JuliaRegistries/General#$(f.general_pr.number), merged" : "tree `$(f.registered)`"
    end
    return links
end

"A phase comment: what was done, the check, what comes next, the progress list, the marker."
function phase_comment(f, mode, n, title; done, check, next, decisions="none", details="")
    return """
        **Phase $n — $title.**
        Done: $done.
        Decisions: $decisions.
        Check: $check.
        Next: $next.
        $(isempty(details) ? "" : "\n" * details * "\n")
        $(progress(f, mode, n; links=progress_links(f)))
        $(marker(f, mode, n, "done"))
        """
end

"""
A comment that stops the release at phase `n` (`state` `stopped`), or waits for a person
(`waiting`): the reason, the output of `status`, who resumes, the progress list with ❌.
"""
function stop_comment(f, p, mode, n, reason; state="stopped", next=nothing)
    why = digest(reason)
    head = state == "stopped" ? "**Phase $n — stopped.**" : "**Phase $n — ⏸ waiting for you.**"
    nxt = something(next, "a human (or an agent) resumes: fix the cause, then the next event, the hourly wake-up or a run of `Release.yml` by hand goes on from the facts")
    body = """
        $head
        Reason: $reason.
        Next: $nxt.

        <details><summary><code>release.jl status</code></summary>

        $(status_report(f, p))
        </details>

        $(progress(f, mode, n - 1; stopped=(n, reason), links=progress_links(f)))
        $(marker(f, mode, n, state; why))
        """
    return (; phase=n, state, why, body)
end

"""
    finish_plan(f, p, ms, r; mode, main=nothing, requester=nothing) -> (; comments, action, summary)

What a wake-up does, from the `facts` `f`, their `phase` `p`, the state markers `ms` of
the tracking issue (`markers`, oldest first) and the verdict `r` of `ready` (`nothing` once
the PR is merged): the comments to post, in order — the phase comments the issue lacks
(phases 4 to 7, then the final one), or one stop — and the one action left: `:none`,
`:start`, `:merge`, `:register`, `:register_beta` (the privileged jobs) or `:close`. Pure.

Phase 3 is the workflow's only for a release it started (a comment of phase 2 with its
marker): `requester` is `nothing` when the person who started it may, else why not; `main`
is the state of the CI of `main` at the base of the request (`main_state`): the release PR
is opened once it is green.
"""
function finish_plan(f, p, ms, r; mode::Symbol, main=nothing, requester=nothing)
    comments = NamedTuple[]
    has(n) = any(m -> m.phase == n && m.state == "done", ms)
    last_m = isempty(ms) ? nothing : last(ms)
    said(n, why) = last_m !== nothing && last_m.phase == n && last_m.why == why
    function stop!(n, reason; kw...)
        c = stop_comment(f, p, mode, n, reason; kw...)
        said(n, c.why) || push!(comments, c)
        return (; comments, action=:none, summary="$(c.state == "stopped" ? "Stopped" : "Waiting for a person") at phase $n: $reason")
    end
    links = progress_links(f)
    pr = f.pr === nothing ? "" : "#$(f.pr.number)"
    merged = f.pr !== nothing && f.pr.state == "MERGED"
    who = mode === :supervised ? "the merge job waits for an approval of the environment `release` (*Review deployments* on the run of `Release.yml`), then merges with `release.jl merge`" :
                                 "the merge, by `release.jl merge`, which checks again what ran on the head commit"
    reg = f.kind === :stable ?
        (mode === :supervised ? "the registration comment, once, after an approval of the environment `release`" : "the registration comment, once, by `release.jl register --post`") :
        (mode === :supervised ? "the registration in ct-registry, after an approval of the environment `release`" : "the registration in ct-registry, by `release.jl register-beta`")

    # the phase comments the issue lacks, in order: the trail, whoever did the step
    reached = Dict(4 => merged || (r !== nothing && r.ready),
                   5 => merged,
                   6 => p.phase >= 7 && !(p.phase == 8 && p.state === :blocked),
                   # registered is not enough: the GitHub release of the tag may still lack (phase 6)
                   7 => f.registered !== nothing && p.phase == 8 && p.state !== :blocked)
    for n in 4:7
        reached[n] && !has(n) || continue
        body = n == 4 ? phase_comment(f, mode, 4, "Checks of $pr";
                            done = merged ? "$pr was merged before the workflow saw its checks; `release.jl audit` checks the runs of its head commit at the close" :
                                            "every check the release needs ran and passed on the head commit `$(r.head)`",
                            check = merged ? "—" : "`release.jl ready` → ready",
                            details = merged ? "" : "<details><summary><code>release.jl ready</code></summary>\n\n" *
                                                    join(("- ✅ " * l.message for l in r.lines), '\n') * "\n</details>",
                            next = merged ? "the tag" : who) :
               n == 5 ? phase_comment(f, mode, 5, "Release PR merged";
                            done = "$pr merged as $(f.pr.merge)", check = "`release.jl status`: merged",
                            next = "the `Release tag` workflow tags $(f.pr.merge) and creates the GitHub release") :
               n == 6 ? phase_comment(f, mode, 6, "Tag and GitHub release";
                            done = "`v$(f.version)` is on $(f.tag), with its GitHub release$(f.kind === :beta ? " (pre-release)" : "")",
                            check = "`release.jl status`: the tag is on the merge commit, the release $(f.kind === :beta ? "is" : "is not") a pre-release",
                            next = reg) :
                        phase_comment(f, mode, 7, "Registered in $(f.registry)";
                            done = "$(f.registry) holds `$(f.version)` — $(links[7])",
                            check = "`release.jl status`: the registered tree is the tree of the tag",
                            next = "the final comment, then the issue is closed")
        push!(comments, (; phase=n, state="done", why="", body))
    end

    p.state === :blocked && return stop!(p.phase, join(p.blockers, "; "))
    if p.phase == 3 && f.pr === nothing && has(2)
        requester === nothing || return stop!(3, "the release was started by someone who may not: $requester")
        main === nothing && return (; comments, action=:none, summary="phase 3: cannot read the CI of `main`")
        main.state === :waiting && return (; comments, action=:none, summary="phase 3: waiting for the CI of `main`")
        main.state === :red &&
            return stop!(3, "the CI of `main` is not green at the base of the request: $(join(("`$w`" for w in main.failed), ", ")) did not pass")
        return (; comments, action=:start, summary="open the release PR")
    end
    p.phase <= 3 && return (; comments, action=:none, summary="phase $(p.phase): the agent's or the human's")
    if p.phase == 4
        r === nothing && return (; comments, action=:none, summary="phase 4: cannot read the checks")
        r.ready && return (; comments, action=:merge, summary="ready: merge $pr")
        any(l -> l.status === :wait, r.lines) &&
            return (; comments, action=:none, summary="phase 4: waiting for the checks")
        fails = [l.message for l in r.lines if l.status === :fail]
        return stop!(4, "the checks of $pr are not green on `$(r.head)`: " * join(fails, "; "))
    end
    if p.phase == 6
        p.state === :waiting && return (; comments, action=:none, summary="phase 6: $(p.next)")
        return stop!(6, p.next)
    end
    if p.phase == 7
        if p.state === :todo
            f.kind === :beta && return (; comments, action=:register_beta, summary="register `$(f.version)` in ct-registry")
            get(p, :on_commit, false) &&
                return stop!(7, "`main` moved past the merge commit $(f.pr.merge) before the registration: the comment must go on that commit, which is never automatic";
                             state="waiting", next="give the go by running `release.jl register --repo $(f.repo) --version $(f.version) --on-commit --post` (after its dry run); the workflow then follows General's PR")
            return (; comments, action=:register, summary="post the registration comment of `$(f.version)`, once")
        end
        f.general_pr !== nothing && f.general_pr.state == "OPEN" && get(f, :jump, :none) === :betas &&
            return stop!(7, "the version jumps over betas (`REL3`): General's PR JuliaRegistries/General#$(f.general_pr.number) needs `[merge approved]`";
                         state="waiting", next="comment `[merge approved]` on JuliaRegistries/General#$(f.general_pr.number); the workflow follows the merge")
        f.general_pr !== nothing && f.general_pr.state == "OPEN" && get(f, :jump, :none) === :unexplained &&
            return stop!(7, "the version jumps over versions no beta explains (`REL3`): a human decides on JuliaRegistries/General#$(f.general_pr.number)"; state="waiting",
                         next="decide on General's PR; the workflow follows its merge")
        return (; comments, action=:none, summary="phase 7: $(p.next)")
    end
    # phase 8
    p.state === :done && return (; comments, action=:none, summary="v$(f.version) is released")
    if !has(8)
        body = """
            **Phase 8 — $(f.name) v$(f.version) is released.**

            $(progress(f, mode, 8; links))

            Left as is: nothing.
            Follow-ups: the downstream `[compat]` bumps, which CompatHelper opens.
            $(marker(f, mode, 8, "done"))
            """
        push!(comments, (; phase=8, state="done", why="", body))
    end
    return (; comments, action=:close, summary="close #$(f.issue.number) and delete `release/v$(f.version)`")
end

"Post `body` on issue `n`; the URL of the comment, or `nothing`."
function post_comment(repo::AbstractString, n::Integer, body::AbstractString)
    path, io = mktemp()
    write(io, body); close(io)
    out = gh("api", "repos/$repo/issues/$n/comments", "-F", "body=@$path", "--jq", ".html_url")
    rm(path; force=true)
    return out === nothing ? nothing : strip(out)
end

"""
    finish(repo; managers, act=:step, version=nothing, actor=nothing, dir=nothing) -> (; ok, action, mode, report)

One wake-up of the release workflow on `repo`, for the release in progress.

- With `version` (the workflow was started by `release.jl request`, by `actor`): phase 2
  first, the tracking issue from the request in the clone `dir` of `release/vX`
  (`open_issue`), if it does not exist yet.

- `act = :step` (the job without powers, `GITHUB_TOKEN`): post the comments of
  `finish_plan`; for `:close`, close the issue, delete the release branch and post the
  audit when it fails. `action` is the privileged action the plan leaves, for the jobs
  of the environment (`:none` if none), and `mode` the mode of the opt-in.
- `act = :start`, `:merge`, `:register` or `:register_beta` (a job of the environment, the App's
  token): do it if, computed again now, it is still the next action — an approval given
  late, or a second run, does nothing. `action` is then `:none`.

`ok` is false when something failed: a comment not posted, the issue not closed, the
audit, the privileged action. `report` is Markdown.
"""
function finish(repo::AbstractString; managers::AbstractString, act::Symbol=:step, version=nothing, actor=nothing, dir=nothing)
    nothing_to_do(why; ok=true) = (; ok, action=:none, mode=nothing, report="## Release — nothing to do\n\n$why.\n")
    opened = ""
    if version !== nothing && act === :step
        dir === nothing && throw(ArgumentError("a version needs the clone of its branch (--dir)"))
        ok, msg = open_issue(repo, dir, version; actor, managers)
        ok || return nothing_to_do("v$version, started by `$actor`: $msg"; ok=false)
        opened = "Phase 2: $msg.\n\n"
    end
    f = version === nothing ? facts(repo) : facts(repo; version=VersionNumber(version))
    (f.issue === nothing && !isempty(opened)) &&
        return (; ok=true, action=:none, mode=nothing, version=nothing, report=opened * "GitHub does not list the issue yet: the next run goes on.\n")
    (f.issue === nothing || f.issue.state != "OPEN") && return nothing_to_do("no release in progress (no open `[RELEASE]` issue)")
    p = phase(f)
    ms = markers(issue_comments(repo, f.issue.number))
    started = findlast(m -> m.phase == 2 && m.state == "done" && !isempty(m.by), ms)
    if f.pr === nothing
        started === nothing && return nothing_to_do("v$(f.version): no release PR yet, and the release was not started by the workflow; phases 0 to 3 are the agent's or the human's")
        o = (; mode=Symbol(ms[started].mode), actor=ms[started].by, reason="")
        requester = authorized(repo, o.actor, managers)
        main = main_state(repo, ms[started].base)
        r = nothing
    else
        o = optin(repo, f.pr.number, managers)
        o.mode === nothing && return nothing_to_do("v$(f.version): $(o.reason)")
        requester = main = nothing
        r = f.pr.state == "OPEN" ? ready(repo, f.pr.number) : nothing
    end
    plan = finish_plan(f, p, ms, r; mode=o.mode, main, requester)
    io = IOBuffer()
    done(ok, action) = (; ok, action, mode=o.mode, version=f.version, report=String(take!(io)))
    print(io, opened)
    println(io, "## Release — $(f.name) v$(f.version) ($(f.kind), $(o.mode), by @$(o.actor))\n")
    println(io, status_report(f, p))
    r === nothing || println(io, ready_report(repo, f.pr.number, r))
    println(io, "**Plan.** ", plan.summary, ".")
    ok = true
    if act === :step
        for c in plan.comments
            url = post_comment(repo, f.issue.number, c.body)
            url === nothing && (println(io, "- ❌ posting the comment of phase $(c.phase) failed: stop"); return done(false, :none))
            println(io, "- posted phase $(c.phase) ($(c.state)): $url")
        end
        if plan.action === :close
            b = "release/v$(f.version)"
            gh("api", "--method", "DELETE", "repos/$repo/git/refs/heads/$b") === nothing ?
                println(io, "- the branch `$b` was not deleted (already gone, or refused)") : println(io, "- deleted `$b`")
            closed = gh("api", "--method", "PATCH", "repos/$repo/issues/$(f.issue.number)", "-f", "state=closed", "--jq", ".state")
            closed === nothing && (println(io, "- ❌ closing #$(f.issue.number) failed"); return done(false, :none))
            println(io, "- closed #$(f.issue.number)")
            af, results = audit(repo, f.version)
            report = audit_report(af, results)
            println(io, "\n", report)
            if any(x -> x.status === :fail, results)
                post_comment(repo, f.issue.number, "The audit of the release found what to look at; the trail is not edited.\n\n" * report)
                ok = false
            end
        end
        return done(ok, plan.action === :close ? :none : plan.action)
    end
    plan.action === act ||
        (println(io, "\nNothing to do here: the next action is now `$(plan.action)`, not `$act`."); return done(true, :none))
    if act === :start
        dir === nothing && throw(ArgumentError("--act start needs the clone of the branch (--dir)"))
        ok, message = start(repo, dir; version=f.version)
    elseif act === :merge
        ok, message = merge_release(repo, f.pr.number; confirm=true)
    elseif act === :register
        ok, message = register(repo, f.version; post=true)
    elseif act === :register_beta
        ok, message = register_beta(repo, f.version; confirm=true)
    else
        throw(ArgumentError("unknown action `$act`"))
    end
    println(io, "\n", message)
    return done(ok, :none)
end
