# The audit of a finished release: whether it left the trail the recipe asks for, judged
# from the facts — GitHub and the registries — and never from what the agent says it did.
# `status` says where a release stands; `audit` says whether a release that stands at its
# end went the way the recipe requires. Read only. Stdlib only; needs the `gh` CLI.

using Base64

@isdefined(facts) || include(joinpath(@__DIR__, "status.jl"))

"The files a release PR may change (REL7: nothing else is a release)."
const RELEASE_FILES = ("Project.toml", "CHANGELOG.md", "BREAKING.md")

"One line of the audit: `:pass`, `:fail` or `:info`, the area it belongs to, and the message."
check(status, area, message) = (; status, area, message)

"""
    markers(comments) -> Vector{NamedTuple}

The state markers (`<!-- ct-release phase=N kind=… version=… mode=… state=… -->`) of the
comments `(author, time, body)`, in order, each with its comment.
"""
function markers(comments)
    out = NamedTuple[]
    for c in comments
        m = match(r"<!-- ct-release ([^>]*?)-->", c.body)
        m === nothing && continue
        kv = Dict(String(x[1]) => String(x[2]) for x in eachmatch(r"(\w+)=(\S+)", m[1]))
        phase = tryparse(Int, get(kv, "phase", ""))
        phase === nothing && continue
        push!(out, (; phase, kind=get(kv, "kind", ""), version=get(kv, "version", ""),
                    state=get(kv, "state", ""), time=c.time, body=c.body))
    end
    return out
end

"Whether `body` is the registration comment as `register` builds it (REL6), not one written by hand."
built_by_the_tool(body::AbstractString) =
    startswith(body, "$MENTION register\n\nRelease notes:\n\n")

"""
    audit_checks(f, t) -> Vector{NamedTuple}

The checks of a release whose `facts` are `f` and whose trail is `t` (see `trail`).
"""
function audit_checks(f, t)
    r = NamedTuple[]
    add(status, area, message) = push!(r, check(status, area, message))
    v = f.version
    stable = f.kind === :stable

    # --- the state: the release is complete -------------------------------------------
    p = phase(f)
    p.state === :done ? add(:pass, "state", "`status` says the release is complete (phase 8)") :
        add(:fail, "state", "the release is not complete: phase $(p.phase), $(p.state): $(p.next)" *
                            join((" — $b" for b in p.blockers)))

    # --- the tracking issue --------------------------------------------------------------
    if f.issue === nothing
        add(:fail, "issue", "no tracking issue `[RELEASE] v$v`")
    else
        f.issues == 1 || add(:fail, "issue", "$(f.issues) tracking issues `[RELEASE] v$v`: there must be one")
        f.issue.state == "CLOSED" ? add(:pass, "issue", "#$(f.issue.number) is closed") :
            add(:fail, "issue", "#$(f.issue.number) is still $(lowercase(f.issue.state))")
        isempty(strip(t.issue_body)) ? add(:fail, "issue", "the description of #$(f.issue.number) is empty") :
            contains(t.issue_body, Regex(MENTION, "i")) ?
                add(:fail, "issue", "the description mentions the registration bot (REL6)") :
                add(:pass, "issue", "the description is written and does not mention the bot")
    end

    # --- the comments: one per phase, in order -------------------------------------------
    ms = markers(t.comments)
    if isempty(ms)
        add(:fail, "trace", "no comment of the tracking issue carries a state marker: the phases left no trace")
    else
        missing_phases = [n for n in 3:8 if !any(m -> m.phase == n, ms)]
        any(m -> m.phase <= 2, ms) || push!(missing_phases, 2)
        sort!(missing_phases)
        isempty(missing_phases) ?
            add(:pass, "trace", "a comment for the proposal and for each phase 3 to 8") :
            add(:fail, "trace", "no comment for phase $(join(missing_phases, ", ")); one per phase, the issue is the trace")
        phases = [m.phase for m in ms]
        issorted(phases) ? add(:pass, "trace", "the comments follow the order of the phases") :
            add(:fail, "trace", "the comments are out of order (phases $(join(phases, ", ")))")
        wrong = [m for m in ms if m.version != string(v) || m.kind != string(f.kind)]
        isempty(wrong) ? add(:pass, "trace", "every marker names $(f.kind) `$v`") :
            add(:fail, "trace", "$(length(wrong)) marker(s) name another release than $(f.kind) `$v`")
        last_m = last(ms)
        last_m.phase == 8 && last_m.state == "done" ?
            add(:pass, "trace", "the last comment is the final one (phase 8, done)") :
            add(:fail, "trace", "the last marked comment is phase $(last_m.phase), state `$(last_m.state)`, not the final comment")
        final = last_m.body
        contains(final, "❌") ? add(:fail, "trace", "the final comment still shows a ❌ step") :
            contains(final, "✅") ? add(:pass, "trace", "the final comment lists the steps, all ✅") :
            add(:info, "trace", "the final comment has no progress list (✅ steps)")
    end

    # --- the registration (REL6) ---------------------------------------------------------
    mention_comments = [c for c in vcat(t.comments, t.commit_comments)
                        if contains(c.body, Regex(MENTION, "i")) && c.author != "JuliaRegistrator"]
    if stable
        f.mentions == 1 ? add(:pass, "registration", "the bot is mentioned once (REL6)") :
            add(:fail, "registration", "the bot is mentioned $(f.mentions) times (REL6: once)")
        if length(mention_comments) == 1
            built_by_the_tool(only(mention_comments).body) ?
                add(:pass, "registration", "the registration comment is the one `release.jl register` builds") :
                add(:fail, "registration", "the registration comment is not in the form `release.jl register` builds: posted by hand?")
        end
    else
        f.mentions == 0 && isempty(mention_comments) ?
            add(:pass, "registration", "a beta: the bot is not mentioned (REL6)") :
            add(:fail, "registration", "a beta never goes to the bot (REL6), yet it is mentioned")
    end
    t.release_body === nothing || !contains(t.release_body, Regex(MENTION, "i")) ||
        add(:fail, "registration", "the GitHub release mentions the bot (REL6)")
    t.pr === nothing || !contains(t.pr.body * "\n" * t.pr.title, Regex(MENTION, "i")) ||
        add(:fail, "registration", "the release PR mentions the bot (REL6)")

    # --- the release PR ------------------------------------------------------------------
    if t.pr === nothing || f.pr === nothing
        add(:fail, "pr", "no release PR `release/v$v`")
    else
        f.pr.state == "MERGED" ? add(:pass, "pr", "#$(f.pr.number) is merged") :
            add(:fail, "pr", "#$(f.pr.number) is $(lowercase(f.pr.state))")
        t.pr.auto_merge ? add(:fail, "pr", "auto-merge was enabled on #$(f.pr.number): the merge goes through `release.jl merge`, never GitHub's auto-merge") :
            add(:pass, "pr", "auto-merge was never enabled")
        extra = [x for x in t.pr.files if !(x in RELEASE_FILES)]
        isempty(extra) ? add(:pass, "pr", "only release files changed ($(join(t.pr.files, ", ")))") :
            add(:fail, "pr", "files beyond the release files: $(join(extra, ", ")) (REL7)")
        changed = t.pr.project_changes
        if isempty(changed)
            "Project.toml" in t.pr.files &&
                add(:fail, "pr", "cannot read the change to `Project.toml`")
        else
            only_version = all(l -> occursin(r"^[+-]version = ", l), changed)
            only_version ? add(:pass, "pr", "`Project.toml` changes only `version`") :
                add(:fail, "pr", "`Project.toml` changes more than `version`")
        end
        isempty(t.runs) && add(:fail, "pr", "no workflow ran on the head commit of #$(f.pr.number)")
        haskey(t.runs, "ReleaseGate.yml") ||
            isempty(t.runs) || add(:fail, "pr", "the release gate (`ReleaseGate.yml`) did not run on the head commit")
        bad = sort!([w for (w, c) in t.runs if c != "success"])
        isempty(bad) || add(:fail, "pr", "on the head commit, the latest run of $(join(("`$w`" for w in bad), ", ")) did not succeed")
        !isempty(t.runs) && isempty(bad) && haskey(t.runs, "ReleaseGate.yml") &&
            add(:pass, "pr", "on the head commit, the latest run of each of $(length(t.runs)) workflows succeeded, the gate among them")
    end

    # --- the tag and the release (REL5) --------------------------------------------------
    f.pr !== nothing && f.pr.merge !== nothing && f.tag !== nothing &&
        (f.tag == f.pr.merge ? add(:pass, "tag", "`v$v` is on the merge commit") :
            add(:fail, "tag", "`v$v` is on $(f.tag), not on the merge commit $(f.pr.merge)"))
    f.release === nothing ? add(:fail, "tag", "no GitHub release of `v$v`") :
        f.release == !stable ? add(:pass, "tag", "the GitHub release is $(stable ? "a release" : "a pre-release")") :
        add(:fail, "tag", "the GitHub release of `v$v` is $(f.release ? "" : "not ")a pre-release")
    t.release_body !== nothing && isempty(strip(t.release_body)) &&
        add(:fail, "tag", "the GitHub release has no notes")
    t.docs === nothing ? add(:info, "tag", "the documentation workflow did not run on the tag") :
        t.docs == "success" ? add(:pass, "tag", "the documentation of the tag was deployed") :
        add(:info, "tag", "the documentation of the tag ended `$(t.docs)`")

    # --- the registry --------------------------------------------------------------------
    if f.registered === nothing
        add(:fail, "registry", "`$v` is not in $(f.registry)")
    elseif f.registered == f.tag_tree
        add(:pass, "registry", "$(f.registry) holds `$v` at the tree of the tag")
    else
        add(:fail, "registry", "the tree in $(f.registry) ($(f.registered)) is not the tree of `v$v` ($(f.tag_tree))")
    end
    if stable
        f.general_pr === nothing ? add(:fail, "registry", "no General PR for `$v`") :
            f.general_pr.state == "MERGED" ? add(:pass, "registry", "General's PR #$(f.general_pr.number) is merged") :
            add(:fail, "registry", "General's PR #$(f.general_pr.number) is $(lowercase(f.general_pr.state))")
        f.jump === :none || add(:info, "registry", "the version jumps over " *
            (f.jump === :betas ? "betas (REL3): `[merge approved]` was needed on General's PR" :
                                 "versions no beta explains (REL3)"))
    end

    # --- the clean-up --------------------------------------------------------------------
    t.branch_exists ? add(:fail, "cleanup", "the branch `release/v$v` still exists (it is deleted at the close)") :
        add(:pass, "cleanup", "the branch `release/v$v` is deleted")
    return r
end

"""
    trail(repo, f) -> NamedTuple

What a release left on GitHub, beyond what `facts` reads: the comments of the issue and of
the merge commit, the release PR (description, files, changes to `Project.toml`, whether
auto-merge was enabled), the latest real run of each workflow on its head commit, the notes
of the GitHub release, the documentation run of the tag, the release branch.
"""
function trail(repo::AbstractString, f)
    v = f.version
    decode(s) = String(base64decode(s))
    comments(args...) = begin
        out = something(gh(args...), "")
        [(; author=x[1], time=x[2], body=decode(x[3]))
         for x in (split(l, '\t') for l in split(out, '\n'; keepempty=false)) if length(x) == 3]
    end
    issue_body = ""
    issue_comments = NamedTuple[]
    if f.issue !== nothing
        n = string(f.issue.number)
        issue_body = decode(strip(something(gh("issue", "view", n, "-R", repo, "--json", "body", "--jq", ".body | @base64"), "")))
        issue_comments = comments("issue", "view", n, "-R", repo, "--json", "comments", "--jq",
                                  ".comments[] | [.author.login, .createdAt, (.body | @base64)] | @tsv")
    end
    commit_comments = f.pr === nothing || f.pr.merge === nothing ? NamedTuple[] :
        comments("api", "repos/$repo/commits/$(f.pr.merge)/comments", "--jq",
                 ".[] | [.user.login, .created_at, (.body | @base64)] | @tsv")
    pr = nothing
    runs = Dict{String,String}()
    if f.pr !== nothing
        n = string(f.pr.number)
        head = gh_strip("pr", "view", n, "-R", repo, "--json", "headRefOid", "--jq", ".headRefOid")
        info = something(gh("pr", "view", n, "-R", repo, "--json", "title,body", "--jq",
                            "[(.title | @base64), (.body | @base64)] | @tsv"), "")
        title, body = length(split(strip(info), '\t')) == 2 ? decode.(split(strip(info), '\t')) : ("", "")
        files = split(something(gh_strip("pr", "view", n, "-R", repo, "--json", "files", "--jq",
                                         ".files[].path"), ""), '\n'; keepempty=false)
        patch = something(gh("api", "repos/$repo/pulls/$n/files", "--jq",
                             ".[] | select(.filename == \"Project.toml\") | .patch"), "")
        changed = [l for l in split(patch, '\n') if occursin(r"^[+-]", l)]
        events = something(gh_strip("api", "repos/$repo/issues/$n/events", "--paginate", "--jq", ".[].event"), "")
        pr = (; title, body=String(body), files=String.(files), project_changes=String.(changed),
              auto_merge="auto_merge_enabled" in split(events, '\n'))
        if head !== nothing
            out = something(gh("api", "repos/$repo/actions/runs?head_sha=$head&event=pull_request&per_page=100",
                               "--jq", ".workflow_runs[] | \"\\(.id)\\t\\(.path)\\t\\(.conclusion)\""), "")
            rs = Dict{String,Vector{Tuple{Int,String}}}()
            for l in split(out, '\n'; keepempty=false)
                id, path, conclusion = split(l, '\t')
                push!(get!(rs, basename(first(split(path, '@'))), Tuple{Int,String}[]), (parse(Int, id), conclusion))
            end
            for (w, xs) in rs
                real = [x for x in sort!(xs) if x[2] != "skipped"]
                isempty(real) || (runs[w] = last(real)[2])
            end
        end
    end
    release_body = gh("release", "view", "v$v", "-R", repo, "--json", "body", "--jq", ".body")
    docs_out = something(gh_strip("api", "repos/$repo/actions/runs?branch=v$v&per_page=100", "--jq",
                                  "[.workflow_runs[] | select(.path | startswith(\".github/workflows/Documentation.yml\"))] | sort_by(.id) | last | .conclusion // empty"), "")
    docs = isempty(docs_out) ? nothing : docs_out
    branch_exists = gh("api", "repos/$repo/git/ref/heads/release/v$v", "--jq", ".ref") !== nothing
    return (; issue_body, comments=issue_comments, commit_comments, pr, runs, release_body, docs, branch_exists)
end

"The Markdown report of `audit_checks`."
function audit_report(f, results)
    io = IOBuffer()
    failed = count(r -> r.status === :fail, results)
    println(io, "## Release audit — $(f.name) v$(f.version) ($(f.kind)): ",
            failed == 0 ? "✅ the trail is complete" : "❌ $failed check(s) failed", "\n")
    println(io, "| | Area | Check |\n| --- | --- | --- |")
    for r in results
        println(io, "| ", r.status === :pass ? "✅" : r.status === :fail ? "❌" : "ℹ️", " | ", r.area, " | ", r.message, " |")
    end
    return String(take!(io))
end

"Audit the release `version` of `repo`: `(facts, results)`."
function audit(repo::AbstractString, version)
    f = facts(repo; version)
    return f, audit_checks(f, trail(repo, f))
end
