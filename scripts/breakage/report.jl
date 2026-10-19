# The report of a breakage run: one table for every downstream package tested, and on a
# release PR, the REL1 check of ct-conventions against the run on the base commit.
#
# usage: julia report.jl CELLS OUT --expected N [--baseline BASELINE] [--base-version V0 --head-version V1]
#
# CELLS holds one TOML file per tested cell (name, owner, version = "latest" | "stable",
# break = "test" | "doc", tag, compat, status = "pass" | "fail" | "no_tag", job), written
# by the `break` jobs of breakage-suite.yml; N is the number of cells the matrix has. OUT
# receives `breakage.toml` (the cells, the baseline of the next runs) and `summary.md`.
#
# A downstream failure is not a failure of the run: it is expected from a breaking change.
# What fails the run is a release PR (V1 ≠ V0) whose number says "not breaking" while a
# downstream package, in its **stable** column (its last release), passes on the base
# (BASELINE, the `breakage.toml` of the run on the base commit) and fails with the PR: the
# version must then be breaking (REL1). A release PR also fails when the comparison cannot
# be made: no baseline, or cells missing. Exit code 0, 1 (blocked), 2 (usage). Stdlib only.

using TOML

include(joinpath(@__DIR__, "..", "release", "versions.jl"))

"The marker of the PR comment of a group, so that a run updates its own comment only."
marker(group) = "<!-- ct-breakage:$group -->"

"The cells of `dir`, sorted by package, then version."
function read_cells(dir)
    cells = [TOML.parsefile(joinpath(dir, f)) for f in readdir(dir) if endswith(f, ".toml")]
    return sort!(cells; by=c -> (c["name"], c["break"], c["version"]))
end

"The key of a cell, across runs."
key(c) = (c["name"], c["break"], c["version"])

"""
    verdict(cells, baseline; expected, base_version, head_version) -> (; release, ok, lines)

What the run says about a release PR (`base_version != head_version`): the downstream
packages broken by it (stable column: ✅ on the base, ❌ with the PR), and whether the
version agrees (REL1). `baseline` is the list of cells of the base run, or `nothing`.
Outside a release, always ok.
"""
function verdict(cells, baseline; expected::Int, base_version=nothing, head_version=nothing)
    lines = String[]
    release = base_version !== nothing && head_version !== nothing && base_version != head_version
    release || return (; release, ok=true, lines)
    ok = true
    if length(cells) < expected
        push!(lines, "❌ $(expected - length(cells)) of $expected cells have no result: a job did not finish; rerun it")
        ok = false
    end
    if baseline === nothing
        push!(lines, "❌ no breakage run on the base commit to compare with: run the Breakage workflow on `main` (workflow_dispatch), then rerun this one")
        return (; release, ok=false, lines)
    end
    before = Dict(key(c) => c["status"] for c in baseline)
    broken = [c for c in cells if c["version"] == "stable" && c["status"] == "fail" && get(before, key(c), nothing) == "pass"]
    already = [c for c in cells if c["version"] == "stable" && c["status"] == "fail" && get(before, key(c), nothing) == "fail"]
    breaking = is_breaking(base_version, head_version)
    for c in already
        push!(lines, "ℹ️ $(c["name"]) ($(c["break"])) already fails on the base: says nothing about the release")
    end
    for c in cells
        c["version"] == "stable" && !haskey(before, key(c)) &&
            push!(lines, "ℹ️ $(c["name"]) ($(c["break"])) has no result on the base (a new target): not compared")
    end
    if isempty(broken)
        push!(lines, "✅ no downstream release broken by `$base_version` → `$head_version`")
    elseif breaking
        push!(lines, "✅ `$base_version` → `$head_version` is breaking, as the breakage shows: " *
                     join(("$(c["name"]) ($(c["break"]))" for c in broken), ", "))
    else
        push!(lines, "❌ `$base_version` → `$head_version` is not breaking, but it breaks the last release of " *
                     join(("$(c["name"]) ($(c["break"]))" for c in broken), ", ") *
                     ": the version must be breaking (REL1), with its `💥 Breaking Changes` entry")
        ok = false
    end
    return (; release, ok, lines)
end

"One cell of the table."
function cell_text(c)
    c === nothing && return "—"
    mark = c["status"] == "pass" ? "✅" : c["status"] == "no_tag" ? "⚠️ no tag" : "❌"
    compat = isempty(get(c, "compat", "")) ? "" : ", compat $(c["compat"])"
    return "[$mark]($(c["job"])) `$(c["tag"])`$compat"
end

"The Markdown summary: the marker, the table, and the verdict of a release PR."
function summary(group, sha, cells, v)
    io = IOBuffer()
    println(io, marker(group))
    println(io, "## Breakage — $group\n")
    println(io, "Tested commit: `$sha`. Each package is tested at its default branch (Latest) and its newest tag (Stable).\n")
    println(io, "| Package | Check | Latest | Stable |\n| --- | --- | --- | --- |")
    byname = Dict(key(c) => c for c in cells)
    for (name, brk) in unique((c["name"], c["break"]) for c in cells)
        println(io, "| $name | $brk | ", cell_text(get(byname, (name, brk, "latest"), nothing)), " | ",
                cell_text(get(byname, (name, brk, "stable"), nothing)), " |")
    end
    if v.release
        println(io, "\n**Release check (REL1, stable column against the base):**\n")
        foreach(l -> println(io, "- ", l), v.lines)
    end
    return String(take!(io))
end

"Parse the arguments, write the report; return the exit code."
function report_main(args)
    args = collect(String, args)
    opt(name) = (i = findfirst(==("--$name"), args); i === nothing ? nothing : (x = args[i+1]; deleteat!(args, i:i+1); x))
    expected = opt("expected"); baseline_path = opt("baseline")
    v0 = opt("base-version"); v1 = opt("head-version")
    group = something(opt("group"), "packages"); sha = something(opt("sha"), "")
    (length(args) == 2 && expected !== nothing) ||
        (println(stderr, "usage: julia report.jl CELLS OUT --expected N [--group G] [--sha SHA] [--baseline FILE] [--base-version V0 --head-version V1]"); return 2)
    cells = read_cells(args[1])
    baseline = baseline_path === nothing || !isfile(baseline_path) ? nothing :
               get(TOML.parsefile(baseline_path), "cell", [])
    v = verdict(cells, baseline; expected=parse(Int, expected),
                base_version=v0 === nothing ? nothing : VersionNumber(v0),
                head_version=v1 === nothing ? nothing : VersionNumber(v1))
    mkpath(args[2])
    open(io -> TOML.print(io, Dict("sha" => sha, "group" => group, "cell" => cells)), joinpath(args[2], "breakage.toml"), "w")
    text = summary(group, sha, cells, v)
    write(joinpath(args[2], "summary.md"), text)
    print(text)
    return v.ok ? 0 : 1
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(report_main(ARGS))
end
