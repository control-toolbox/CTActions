# Phases 0 and 1 of a release, as far as they are facts: what the agent reads before it
# judges, and the request it hands to the release workflow once a person validated it.
#
# The tool never judges. It computes the facts (the state of the last release and of
# `main`, the reference, the expected version, REL4, REL7, the labels) and lists the
# candidates the agent must look at: the merged PRs the changelog does not cite, the names
# no longer exported, the dependencies and bounds that changed. Every agent looks at the
# same list; each candidate gets a verdict in the request, and a candidate without one
# blocks it. Stdlib only; needs `git` and `gh`.

using Dates, TOML

@isdefined(gate) || include(joinpath(@__DIR__, "gate.jl"))
@isdefined(facts) || include(joinpath(@__DIR__, "status.jl"))

"The verdicts of a candidate in a request."
const VERDICTS = ("covered", "added", "not-user-facing")

"The modes of a request (the label the release workflow puts on the release PR)."
const MODES = ("supervised", "autonomous")


"""
    merged_prs(dir, from, to) -> Vector{NamedTuple}

The pull requests merged on the first-parent history `from..to` of the clone `dir`
(`Merge pull request #N` or a squash `… (#N)`), oldest first, each with its commit, its
title and the files it changed.
"""
function merged_prs(dir, from, to)
    log = something(git(dir, "log", "--first-parent", "--reverse", "--format=%H%x09%s", "$from..$to"), "")
    out = NamedTuple[]
    for line in split(log, '\n'; keepempty=false)
        sha, subject = split(line, '\t'; limit=2)
        m = something(match(r"^Merge pull request #(\d+)", subject), match(r"\(#(\d+)\)\s*$", subject), Some(nothing))
        m === nothing && continue
        title = startswith(subject, "Merge pull request") ?
            strip(something(git(dir, "log", "-1", "--format=%b", sha), "")) : subject
        files = split(something(git(dir, "diff", "--name-only", "$sha^1", sha), ""), '\n'; keepempty=false)
        push!(out, (; number=parse(Int, m[1]), sha=String(sha), title=String(first(split(title * "\n", '\n'))), files=String.(files)))
    end
    return out
end

"The names an `export` or `public` statement of `src/` declares at `rev`."
function exported_names(dir, rev)
    out = something(git(dir, "grep", "-h", "-E", "^[[:space:]]*(export|public)[[:space:]]", rev, "--", "src"), "")
    names = Set{String}()
    for line in split(out, '\n'; keepempty=false)
        body = replace(line, r"#.*$" => "", r"^\s*(export|public)\s+" => "")
        for n in split(body, r"[,\s]+"; keepempty=false)
            occursin(r"^[@\p{L}_][\p{L}\p{N}_!]*$", n) && push!(names, n)
        end
    end
    return names
end

"Where `name` is declared in a parsed `Project.toml`: `deps`, `weakdeps` or `nothing`."
dep_kind(project, name) = haskey(get(project, "deps", Dict()), name) ? "deps" :
                          haskey(get(project, "weakdeps", Dict()), name) ? "weakdeps" : nothing

"""
    candidates(dir, reference, base, changelog; closing) -> (; review, unshipped)

What the agent must look at before a release, from the tag `reference` to the commit
`base`: `review` lists each candidate (`id`, `what`), `unshipped` the merged PRs that touch
nothing a user gets (REL7), for information. `changelog` is the text the release will
ship; `closing(n)` gives the issues PR `n` closes (from GitHub).

- `pr-N`: a merged PR that touches `src/`, `ext/`, `docs/` or `Project.toml`, cited
  nowhere in the changelog since `reference`, nor through an issue it closes or names in
  its title;
- `export-NAME`: a name exported or declared `public` at `reference` and no longer;
- `dep-NAME`: a dependency added, removed, or moved between `[deps]` and `[weakdeps]`;
- `compat-NAME`: a `[compat]` bound of a dependency (or of `julia`) that changed.
"""
function candidates(dir, reference::AbstractString, base::AbstractString, changelog::AbstractString;
                    closing=n -> Int[])
    ref_v = tryparse(VersionNumber, lstrip(reference, 'v'))
    since = join((last(s) for s in sections(changelog)
                  if (v = label_version(first(s)); v === nothing || ref_v === nothing || v > ref_v)), "\n")
    cited(n) = occursin(Regex("(#|/pull/|/issues/)$n(?![0-9])"), since)
    review = NamedTuple[]
    unshipped = NamedTuple[]
    old = TOML.parse(something(show_file(dir, reference, "Project.toml"), ""))
    for pr in merged_prs(dir, reference, base)
        project = "Project.toml" in pr.files &&
            user_facing(TOML.parse(something(show_file(dir, "$(pr.sha)^1", "Project.toml"), ""))) !=
            user_facing(TOML.parse(something(show_file(dir, pr.sha, "Project.toml"), "")))
        touched = [f for f in pr.files if any(r -> occursin(r, f), SHIPPED)]
        project && push!(touched, "Project.toml")
        if isempty(touched)
            push!(unshipped, (; id="pr-$(pr.number)", what="#$(pr.number) $(pr.title)"))
            continue
        end
        issues = vcat(closing(pr.number), [parse(Int, m[1]) for m in eachmatch(r"#(\d+)", pr.title)])
        (cited(pr.number) || any(cited, issues)) && continue
        dirs = sort!(unique!([first(split(f, '/')) for f in touched]))
        push!(review, (; id="pr-$(pr.number)",
                         what="#$(pr.number) $(pr.title) — touches $(join(dirs, ", ")); not cited in the changelog since `$reference`"))
    end
    for n in sort!(collect(setdiff(exported_names(dir, reference), exported_names(dir, base))))
        push!(review, (; id="export-$n", what="`$n` is exported or public at `$reference`, not any more: breaking, or renamed?"))
    end
    new = TOML.parse(something(show_file(dir, base, "Project.toml"), ""))
    names = union(keys(get(old, "deps", Dict())), keys(get(old, "weakdeps", Dict())),
                  keys(get(new, "deps", Dict())), keys(get(new, "weakdeps", Dict())))
    for n in sort!(collect(names))
        a, b = dep_kind(old, n), dep_kind(new, n)
        a == b || push!(review, (; id="dep-$n", what="`$n`: $(something(a, "absent")) → $(something(b, "absent"))"))
    end
    oc, nc = user_facing(old)["compat"], user_facing(new)["compat"]
    for n in sort!(collect(union(keys(oc), keys(nc))))
        get(oc, n, nothing) == get(nc, n, nothing) && continue
        push!(review, (; id="compat-$n", what="`[compat]` of `$n`: `$(something(get(oc, n, nothing), "none"))` → `$(something(get(nc, n, nothing), "none"))`"))
    end
    return (; review, unshipped)
end

"The issues PR `n` of `repo` closes, from GitHub."
closing_issues(repo, n) = [parse(Int, x) for x in split(something(gh_strip("pr", "view", string(n), "-R", repo, "--json",
    "closingIssuesReferences", "--jq", ".closingIssuesReferences[].number"), "")) if !isempty(x)]

"""
    gpu_choice(labels, online) -> Vector{String}

`labels` with one GPU label only, as the recipe asks: `run ci kkt-runner` when its runner is
`online` (a function of the runner's name), else `run ci occidata-runner` when it is, else
the first one (the runners cannot be read, or none is online: `release.jl ready` then says
which job did not run).
"""
function gpu_choice(labels, online)
    gpus = [l for l in GPU_LABELS if l in labels]
    length(gpus) <= 1 && return collect(labels)
    runner(l) = replace(l, "run ci " => "", "-runner" => "")
    keep = something(findfirst(l -> online(runner(l)), gpus), 1)
    return [l for l in labels if !(l in gpus) || l == gpus[keep]]
end

"Whether the self-hosted runner `name` of the organization is online; `false` when the runners cannot be read."
runner_online(name) = something(gh_strip("api", "orgs/control-toolbox/actions/runners", "--jq",
    "[.runners[] | select(.name == \"$name\" or (.labels | map(.name) | index(\"$name\"))) | select(.status == \"online\")] | length"), "0") != "0"

"The tag `vX` of the last release of `kind`'s reference (the last stable for a stable, the last release for a beta), among `released`."
function reference_of(kind::Symbol, released)
    pool = kind === :stable ? filter(isstable, released) : released
    return isempty(pool) ? nothing : maximum(pool)
end

"The versions of ct-agents and ct-conventions the package pins (`AGENTS.md`), and the commit of this tool."
function applied_versions(dir)
    agents = isfile(joinpath(dir, "AGENTS.md")) ? read(joinpath(dir, "AGENTS.md"), String) : ""
    pin(name) = (m = match(Regex("Pinned version: $name (v[0-9][0-9.]*[0-9])"), agents); m === nothing ? "" : String(m[1]))
    tool = something(git(@__DIR__, "rev-parse", "--short", "HEAD"), "")
    return (; ct_agents=pin("ct-agents"), ct_conventions=pin("ct-conventions"), ctactions=strip(tool))
end

"""
    release_facts(dir, repo; kind, base="origin/main", resolution=true) -> NamedTuple

The facts of a release of `kind` (`:stable` or `:beta`) of `repo`, whose clone is `dir`, from
the commit `base`: the version, the reference and the expected version (the rules of the
gate, REL1-REL3), REL4 (a stable resolves from General alone; `resolution=false` skips it),
REL7, the run labels, and the `candidates` to review. The changelog read is the one of the
working tree: the agent's additions count.
"""
function release_facts(dir, repo; kind::Symbol, base="origin/main", resolution::Bool=true)
    base_sha = strip(something(git(dir, "rev-parse", base), ""))
    isempty(base_sha) && throw(ArgumentError("no commit `$base` in $dir"))
    project = TOML.parse(something(show_file(dir, base_sha, "Project.toml"), ""))
    name = project["name"]
    general, ct = registry_versions("General", name), registry_versions("ct-registry", name)
    tags = tagged_versions(dir)
    released = unique!(vcat(collect(keys(general)), collect(keys(ct)), tags))
    reference = reference_of(kind, released)
    changelog = read(joinpath(dir, "CHANGELOG.md"), String)
    changed = changes_since(changelog, reference)
    expected = expected_version(kind, released; breaking=changed.breaking, feature=changed.feature)
    ref_tag = reference === nothing ? nothing : "v$reference"
    rel7 = ref_tag === nothing || !(reference in tags) ? String[] :
        shipped(split(something(git(dir, "diff", "--name-only", ref_tag, base_sha), "")),
                TOML.parse(something(show_file(dir, ref_tag, "Project.toml"), "")), project)
    rel4 = nothing
    if kind === :stable && resolution
        g = registry(Pkg.Registry.reachable_registries(), GENERAL)
        rel4 = g !== nothing && all(first(resolve(deps, compat_for(project, deps), [g])) for (_, deps) in environments(project))
    end
    workflows = mktempdir()
    for f in split(something(git(dir, "ls-tree", "--name-only", "$base_sha:.github/workflows"), ""), '\n'; keepempty=false)
        write(joinpath(workflows, f), something(show_file(dir, base_sha, ".github/workflows/$f"), ""))
    end
    labels = gpu_choice(sort!([l for l in run_labels(workflows) if !(l in OPTIONAL_LABELS)]), runner_online)
    isfile(joinpath(workflows, "Documentation.yml")) && push!(labels, PREVIEW_LABEL)
    c = ref_tag === nothing ? (; review=NamedTuple[], unshipped=NamedTuple[]) :
        candidates(dir, ref_tag, base_sha, changelog; closing=n -> closing_issues(repo, n))
    last_general = isempty(general) ? nothing : maximum(keys(general))
    j = kind === :beta || expected === nothing ? :none : jump(last_general, expected, collect(keys(ct)))
    return (; repo, name, kind, base=String(base_sha), reference, expected, breaking=changed.breaking,
            feature=changed.feature, rel4, rel7, labels, jump=j, candidates=c.review, unshipped=c.unshipped,
            versions=applied_versions(dir))
end

"A TOML basic string."
tq(s) = "\"" * replace(string(s), "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n", "\t" => "\\t", "\r" => "\\r") * "\""

"""
    request_skeleton(f) -> String

The request of the release `f` (`release_facts`), to complete by the agent: the mode and
the person who validated it, a verdict and a note for every candidate. The proposal goes
in the Markdown file next to it.
"""
function request_skeleton(f)
    io = IOBuffer()
    _, md = request_paths(f.expected)
    println(io, "# The request of the release of $(f.name) v$(f.expected), for the release workflow of CTActions.")
    println(io, "# Written by `release.jl facts`, completed by the agent after the human's validation, checked")
    println(io, "# by `release.jl request` and again by the workflow. The proposal is in $md.\n")
    println(io, "[release]\npackage = $(tq(f.name))\nversion = $(tq(f.expected))\nkind = $(tq(f.kind))")
    println(io, "mode = \"\"            # supervised or autonomous: the human's choice")
    println(io, "requested_by = \"\"    # the GitHub login of the person who validated the proposal")
    println(io, "reference = $(tq(something(f.reference, "")))\nbase = $(tq(f.base))\n")
    println(io, "[versions]\nct_agents = $(tq(f.versions.ct_agents))\nct_conventions = $(tq(f.versions.ct_conventions))\nctactions = $(tq(f.versions.ctactions))\n")
    println(io, "[facts]\nexpected_version = $(tq(f.expected))\nbreaking = $(f.breaking)\nfeature = $(f.feature)")
    f.rel4 === nothing || println(io, "rel4 = $(f.rel4)")
    println(io, "rel7 = $(length(f.rel7))\njump = $(tq(f.jump))\nlabels = [$(join(tq.(f.labels), ", "))]")
    for c in f.candidates
        println(io, "\n[[review]]\nid = $(tq(c.id))\nwhat = $(tq(c.what))\nverdict = \"\"   # $(join(VERDICTS, ", "))\nnote = \"\"")
    end
    return String(take!(io))
end

"The Markdown report of `release_facts`, for the agent and the proposal."
function facts_report(f; status=nothing)
    io = IOBuffer()
    println(io, "## Release facts — $(f.name), $(f.kind)\n")
    status === nothing || println(io, status)
    println(io, "| Fact | Value |\n| --- | --- |")
    println(io, "| base | `$(f.base)` |")
    println(io, "| reference (REL2: the last $(f.kind === :stable ? "stable" : "release")) | `$(something(f.reference, "none"))` |")
    println(io, "| changelog since the reference | $(f.breaking ? "💥 breaking" : "not breaking")$(f.feature ? ", ✨ features" : "") |")
    println(io, "| **expected version** | **`$(something(f.expected, "none: decide by hand"))`** |")
    f.kind === :stable && println(io, "| jump in General (REL3) | `$(f.jump)`$(f.jump === :betas ? ": `[merge approved]` on General's PR" : "") |")
    f.rel4 === nothing || println(io, "| resolves from General alone (REL4) | $(f.rel4 ? "✅" : "❌") |")
    println(io, "| something to release (REL7) | $(isempty(f.rel7) ? "❌ nothing" : "✅ $(length(f.rel7)) change(s)") |")
    println(io, "| run labels | $(join(("`$l`" for l in f.labels), ", ")) |")
    println(io, "| versions applied | ct-agents `$(f.versions.ct_agents)`, ct-conventions `$(f.versions.ct_conventions)`, CTActions `$(f.versions.ctactions)` |")
    println(io, "\n### To review ($(length(f.candidates)))\n")
    println(io, "Give each one a verdict in the request (`covered`, `added`: you added the entry, `not-user-facing`) and a note.\n")
    isempty(f.candidates) && println(io, "Nothing.")
    for c in f.candidates
        println(io, "- `$(c.id)`: $(c.what)")
    end
    if !isempty(f.unshipped)
        println(io, "\n### Merged, nothing shipped (REL7), for information\n")
        for c in f.unshipped
            println(io, "- $(c.what)")
        end
    end
    return String(take!(io))
end

"""
    check_request(dir, path; repo, base="origin/main", resolution=false) -> Vector{String}

The problems of the request `path` (relative to the clone `dir`), against the facts
computed again: the version is the expected one, the base is still `base`, the mode and
the requester are set, the proposal is written, every candidate has a verdict and a note,
and nothing mentions the registration bot (REL6). Empty: the request may go.
"""
function check_request(dir, path; repo, base="origin/main", resolution::Bool=false)
    problems = String[]
    file = joinpath(dir, path)
    isfile(file) || return ["no request `$path`"]
    r = try
        TOML.parsefile(file)
    catch e
        return ["`$path` is not valid TOML: $(sprint(showerror, e))"]
    end
    rel = get(r, "release", Dict())
    v = tryparse(VersionNumber, get(rel, "version", ""))
    v === nothing && return ["`[release] version` is missing"]
    kind = get(rel, "kind", "")
    kind in ("stable", "beta") || return ["`[release] kind` is `$kind`, not stable or beta"]
    request_paths(v)[1] == path || push!(problems, "the request of `$v` is `$(request_paths(v)[1])`, not `$path`")
    md = joinpath(dir, request_paths(v)[2])
    proposal = isfile(md) ? read(md, String) : ""
    isempty(strip(proposal)) && push!(problems, "the proposal `$(request_paths(v)[2])` is missing or empty")
    get(rel, "mode", "") in MODES || push!(problems, "`[release] mode` is `$(get(rel, "mode", ""))`, not $(join(MODES, " or "))")
    isempty(get(rel, "requested_by", "")) && push!(problems, "`[release] requested_by` is empty: the login of the person who validated")
    for (p, text) in ((path, read(file, String)), (request_paths(v)[2], proposal))
        occursin(Regex(MENTION, "i"), text) && push!(problems, "`$p` mentions the registration bot (REL6)")
    end
    f = release_facts(dir, repo; kind=Symbol(kind), base, resolution)
    f.base == get(rel, "base", "") ||
        push!(problems, "`main` moved: the request was made on `$(get(rel, "base", ""))`, `$base` is now `$(f.base)`; run `release.jl facts` again")
    f.expected == v || push!(problems, "the expected version is `$(something(f.expected, "none"))`, not `$v` (REL1, REL2)")
    reviews = Dict(get(x, "id", "") => x for x in get(r, "review", []))
    for c in f.candidates
        x = get(reviews, c.id, nothing)
        if x === nothing
            push!(problems, "no verdict for `$(c.id)`: $(c.what)")
        elseif !(get(x, "verdict", "") in VERDICTS)
            push!(problems, "`$(c.id)`: the verdict is `$(get(x, "verdict", ""))`, not $(join(VERDICTS, ", "))")
        elseif isempty(strip(get(x, "note", "")))
            push!(problems, "`$(c.id)`: the verdict has no note")
        end
    end
    return problems
end

"""
    request_release(dir, path; repo, dispatch=true) -> (Bool, String)

Hand the release over: check the request (`check_request`), commit it with the proposal
and the agent's changes to the changelog and `BREAKING.md` on the branch `release/vX`
checked out in `dir`, push the branch, and start the release workflow with the version.
Without `dispatch`, everything but the start. Run again, it commits nothing new and starts
the workflow again, which does nothing already done.
"""
function request_release(dir, path; repo, dispatch::Bool=true)
    problems = check_request(dir, path; repo)
    isempty(problems) || return (false, "The request is not ready:\n" * join(("- $p" for p in problems), '\n'))
    r = TOML.parsefile(joinpath(dir, path))
    v = VersionNumber(r["release"]["version"])
    branch = strip(something(git(dir, "rev-parse", "--abbrev-ref", "HEAD"), ""))
    branch == "release/v$v" || return (false, "the clone is on `$branch`: the request goes on `release/v$v`")
    files = [request_paths(v)..., "CHANGELOG.md", "BREAKING.md"]
    git(dir, "add", "--", filter(f -> isfile(joinpath(dir, f)), files)...) === nothing && return (false, "`git add` failed")
    staged = strip(something(git(dir, "diff", "--cached", "--name-only"), ""))
    if !isempty(staged)
        git(dir, "commit", "-q", "-m", "chore: request the release of $(r["release"]["package"]) v$v") === nothing &&
            return (false, "`git commit` failed")
    end
    git(dir, "push", "-q", "-u", "origin", "release/v$v") === nothing && return (false, "`git push` failed")
    dispatch || return (true, "Pushed `release/v$v`; the release workflow was not started (`--no-dispatch`).")
    out = gh("workflow", "run", RELEASE_WORKFLOW, "-R", repo, "--ref", "main", "-f", "version=$v")
    out === nothing && return (false, "pushed, but starting `$RELEASE_WORKFLOW` failed: run it by hand with the version `$v`")
    return (true, "Pushed `release/v$v` and started `$RELEASE_WORKFLOW` with the version `$v`. The session can stop: the workflow opens the tracking issue, then the release PR once `main` is green, and finishes; follow the issue.")
end
