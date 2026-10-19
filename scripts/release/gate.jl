# The gate of a release pull request: every rule of REL1-REL7 that can be decided from the
# repository, the registries and the PR, in one report. A PR that does not change the
# version is not a release and passes at once. Stdlib only; needs `git` and the clone's
# history and tags.

using Pkg, TOML

for f in ("versions.jl", "changelog.jl", "changes.jl", "registrable.jl")
    include(joinpath(@__DIR__, f))
end

"One result of the gate: `:pass`, `:fail` or `:info`, with the rule and the message."
const Result = NamedTuple{(:status, :rule, :message),Tuple{Symbol,String,String}}

pass(rule, msg) = Result((:pass, rule, msg))
fail(rule, msg) = Result((:fail, rule, msg))
info(rule, msg) = Result((:info, rule, msg))

"Run `git` in `dir` and return its standard output, or `nothing` when it fails."
function git(dir, args...)
    out = IOBuffer()
    ok = success(pipeline(`git -C $dir $args`; stdout=out, stderr=devnull))
    return ok ? String(take!(out)) : nothing
end

"The file `path` at `rev` in the clone `dir`, or `nothing`."
show_file(dir, rev, path) = git(dir, "show", "$rev:$path")

"The versions tagged `vX.Y.Z[-beta]` in the clone `dir`."
function tagged_versions(dir)
    tags = something(git(dir, "tag", "--list", "v*"), "")
    return VersionNumber[v for v in (tryparse(VersionNumber, t[2:end]) for t in split(tags)) if v !== nothing]
end

"""
    gate(dir, base; labels, text="", resolution=true, labels_info=false) -> Vector{Result}

Check the release PR whose head is checked out in `dir` against its base commit `base`.
`labels` are the labels of the PR, `text` its title and description. `resolution=false`
skips REL4 (the unit tests do). `labels_info=true` reports missing run labels without
failing (the workflow: it runs once per label added, so the first runs see some labels
only; `release.jl ready` then requires every gated job to have run). REL6 is checked on every PR, a release or not: the bot's
mention in the PR's text or in a commit message.
"""
function gate(dir::AbstractString, base::AbstractString; labels, text::AbstractString="", resolution::Bool=true,
              labels_info::Bool=false)
    head = TOML.parsefile(joinpath(dir, "Project.toml"))
    base_toml = show_file(dir, base, "Project.toml")
    base_toml === nothing && return [fail("—", "no `Project.toml` at the base `$base`")]
    old = TOML.parse(base_toml)

    # REL6, on every PR: the bot reacts to its mention in a PR too
    mention = Regex(MENTION, "i")
    where_ = String[]
    occursin(mention, text) && push!(where_, "the PR's title or description")
    occursin(mention, something(git(dir, "log", "--format=%B", "$base..HEAD"), "")) && push!(where_, "a commit message")
    rel6 = isempty(where_) ? Result[] :
        [fail("REL6", "the registration bot is mentioned in $(join(where_, " and ")): only the registration comment may mention it")]

    get(head, "version", nothing) == get(old, "version", nothing) &&
        return vcat([info("—", "the version does not change: not a release PR")], rel6)

    results = copy(rel6)
    v = VersionNumber(head["version"])
    name = head["name"]
    kind = isbeta(v) ? :beta : :stable

    # identity
    head["name"] == old["name"] && head["uuid"] == old["uuid"] ?
        push!(results, pass("—", "name and uuid unchanged")) :
        push!(results, fail("—", "the name or the uuid changed"))

    # REL2: suffix, fresh triple, untagged
    general = registry_versions("General", name)
    ct = registry_versions("ct-registry", name)
    tags = tagged_versions(dir)
    released = unique!(vcat(collect(keys(general)), collect(keys(ct)), tags))
    allowed_suffix(v) ? push!(results, pass("REL2", "suffix of `$v`")) :
        push!(results, fail("REL2", "`$v`: the only suffix allowed is `-beta`"))
    "v$v" in ("v" .* string.(tags)) && push!(results, fail("REL5", "the tag `v$v` already exists"))
    top = isempty(released) ? nothing : maximum(triple, released)
    top === nothing || triple(v) > top ?
        push!(results, pass("REL2", "`$(triple(v))` is above every version released ($(something(top, "none")))")) :
        push!(results, fail("REL2", "`$(triple(v))` is not above every version released: the highest is `$top`"))

    # REL1: the changelog says breaking or not; the number must agree, and be the expected one
    changelog = read(joinpath(dir, "CHANGELOG.md"), String)
    for p in check_changelog(changelog, v)
        push!(results, fail("CHG2", p))
    end
    stables = filter(isstable, released)
    reference = kind === :stable ? (isempty(stables) ? nothing : maximum(stables)) :
                (isempty(released) ? nothing : maximum(released))
    changed = changes_since(changelog, reference)
    if reference !== nothing
        is_breaking(reference, v) == changed.breaking ?
            push!(results, pass("REL1", "`$reference` → `$v` is $(changed.breaking ? "" : "not ")breaking, as the changelog says ($(join(changed.versions, ", ")))")) :
            push!(results, fail("REL1", "`$reference` → `$v` is $(is_breaking(reference, v) ? "" : "not ")breaking, but the changelog since `$reference` $(changed.breaking ? "has" : "has no") `💥 Breaking Changes`"))
    end
    expected = expected_version(kind, released; breaking=changed.breaking, feature=changed.feature)
    expected === nothing ?
        push!(results, fail("REL2", "no version fits: a non-breaking stable after breaking betas; decide by hand")) :
    expected == v ? push!(results, pass("REL1", "`$v` is the expected version")) :
        push!(results, fail("REL1", "the expected version is `$expected`, not `$v` (breaking: $(changed.breaking), new features: $(changed.feature))"))

    # REL3: a jump in General is explained by betas
    if kind === :stable
        last_general = isempty(general) ? nothing : maximum(keys(general))
        j = jump(last_general, v, collect(keys(ct)))
        j === :none ? push!(results, pass("REL3", "`$(something(last_general, "none"))` → `$v`: no jump")) :
        j === :betas ? push!(results, info("REL3", "`$last_general` → `$v`: a jump explained by betas; `[merge approved]` is needed on the General PR")) :
            push!(results, fail("REL3", "`$last_general` → `$v`: a jump that no beta explains"))
    end

    # CHG3, CHG4: BREAKING.md names the version
    bpath = joinpath(dir, "BREAKING.md")
    isfile(bpath) && names_version(read(bpath, String), v) ?
        push!(results, pass("CHG3", "`BREAKING.md` has an entry for `$v`")) :
        push!(results, fail("CHG3", "`BREAKING.md` has no `##` entry for `$v` (CHG3 or CHG4)"))

    # the diff of the PR: the release files only, and in Project.toml the version only
    files = split(something(git(dir, "diff", "--name-only", "$base...HEAD"), ""))
    extra = setdiff(files, RELEASE_FILES)
    isempty(extra) ? push!(results, pass("—", "the PR changes $(join(("`$f`" for f in files), ", ")) only")) :
        push!(results, fail("—", "a release PR changes $(join(("`$f`" for f in RELEASE_FILES), ", ")) only; it also changes $(join(("`$f`" for f in extra), ", "))"))
    without_version(head) == without_version(old) ? push!(results, pass("—", "`Project.toml`: the version only")) :
        push!(results, fail("—", "`Project.toml` changes more than the version"))

    # REL7: something to release since the previous release of the same kind
    if reference === nothing
        push!(results, info("REL7", "first release: nothing to compare with"))
    elseif !("v$reference" in ("v" .* string.(tags)))
        push!(results, fail("REL7", "no tag `v$reference`: cannot tell what changed since `$reference`"))
    else
        since = split(something(git(dir, "diff", "--name-only", "v$reference", base), ""))
        ref_toml = show_file(dir, "v$reference", "Project.toml")
        what = shipped(since, TOML.parse(something(ref_toml, "")), old)
        isempty(what) ?
            push!(results, fail("REL7", "nothing reaches a user since `v$reference` (changes in tests, CI or the changelog only)")) :
            push!(results, pass("REL7", "$(length(what)) change(s) reach a user since `v$reference`, e.g. `$(first(what))`"))
    end

    # labels: every run label of the workflows, one GPU label
    lack = missing_labels(run_labels(joinpath(dir, ".github", "workflows")), labels)
    if isempty(lack)
        push!(results, pass("—", "the PR has the run labels of the workflows"))
    elseif labels_info
        push!(results, info("—", "labels not on the PR at this event: $(join(lack, ", ")); `release.jl ready` requires every job they gate to have run and passed"))
    else
        push!(results, fail("—", "missing labels: $(join(lack, ", ")) (a label-gated job without its label is skipped, and a skipped job passes)"))
    end

    # REL4: a stable resolves from General alone
    if kind === :stable && resolution
        regs = Pkg.Registry.reachable_registries()
        g = registry(regs, GENERAL)
        if g === nothing
            push!(results, fail("REL4", "the General registry is not installed"))
        else
            envs = [label => resolve(deps, compat_for(head, deps), [g]) for (label, deps) in environments(head)]
            bad = [label for (label, (ok, _)) in envs if !ok]
            if isempty(bad)
                push!(results, pass("REL4", "resolves from General alone ($(length(envs)) environments)"))
            else
                found = diagnose(head, g, filter(r -> r.name != GENERAL, regs))
                why = join(("`$(f.name) = \"$(f.spec)\"`" for f in found), ", ")
                push!(results, fail("REL4", "does not resolve from General alone: $(join(bad, ", "))$(isempty(why) ? "" : "; no General version satisfies $why")"))
            end
        end
    end
    return results
end

"The Markdown report of the gate."
function gate_report(name, results)
    io = IOBuffer()
    failed = any(r -> r.status === :fail, results)
    release = !any(r -> r.status === :info && contains(r.message, "not a release PR"), results)
    println(io, "## Release gate — $name: ", failed ? "❌ blocked" : !release ? "not a release" : "✅ ready", "\n")
    println(io, "| | Rule | Check |\n| --- | --- | --- |")
    for r in results
        println(io, "| ", r.status === :pass ? "✅" : r.status === :fail ? "❌" : "ℹ️", " | ", r.rule, " | ", r.message, " |")
    end
    return String(take!(io))
end
