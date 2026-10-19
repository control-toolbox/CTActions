# The downstream packages of a package: the targets of the breakage suite, read from the
# Project.toml files of the organization instead of written by hand in every package.
#
# usage: julia consumers.jl list --project Project.toml [--org control-toolbox]
#        julia consumers.jl plan --project Project.toml [--declared JSON] [--no-derive]
#                                [--org control-toolbox] [--summary FILE]
#
# A package of the organization is a consumer of P when it lists P (by uuid) in the
# `[deps]`, `[weakdeps]` or `[extras]` of its `Project.toml`, or in the `[deps]` of its
# `test/Project.toml`: whatever loads P when its tests run. `list` prints those consumers;
# `plan` adds the `--declared` targets (a JSON list of {"name", "owner", "break"}) that
# cannot be derived — an application owned outside the organization, a documentation build —
# and prints the targets of the suite, one JSON line; `--summary` appends a table saying
# where each one comes from. A failure to read the organization is an error, never an
# empty list. Needs `gh`, authenticated (GH_TOKEN). Exit code 0, 1 (error), 2 (usage).
# Stdlib only.

using TOML

const ORG = "control-toolbox"

"Repositories that are not part of the ecosystem to test, with the reason."
const EXCLUDED = Dict(
    "CTAppTemplate" => "a template of a new package, not a package of the ecosystem",
    "CTBenchmarks" => "its compat is out of date (CTBase 0.16, OptimalControl =1.1.6), so its tests fail whatever the change: remove this line once it is updated",
)

"A target of the suite."
const Target = NamedTuple{(:name, :owner, :break_, :source), NTuple{4,String}}

"The characters a package name and an owner may have: they end up in a git URL and in a shell."
valid_name(s::AbstractString) = occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", s)

# What is read from GitHub, replaced in the tests.

"Run `gh api …`: `(exit code, stdout, stderr)`."
function gh_api(args...)
    out, err = IOBuffer(), IOBuffer()
    p = run(pipeline(ignorestatus(`gh api $args`); stdout=out, stderr=err))
    return (p.exitcode, String(take!(out)), String(take!(err)))
end

const API = Ref{Function}(gh_api)

"The repositories of `org`, as `(name, archived, fork)`; throws when GitHub does not answer."
function list_repos(org::AbstractString)
    code, out, err = API[]("--paginate", "orgs/$org/repos?per_page=100", "--jq", ".[] | \"\\(.name)\\t\\(.archived)\\t\\(.fork)\"")
    code == 0 || error("cannot list the repositories of $org: $(strip(err))")
    return [(n, a == "true", f == "true") for (n, a, f) in (split(l, '\t') for l in split(out, '\n'; keepempty=false))]
end

"The text of `path` on the default branch of `org/repo`; `nothing` when the file does not exist, an error otherwise."
function read_file(org::AbstractString, repo::AbstractString, path::AbstractString)
    code, out, err = API[]("repos/$org/$repo/contents/$path", "-H", "Accept: application/vnd.github.raw")
    code == 0 && return out
    occursin("HTTP 404", err) && return nothing
    error("cannot read $path of $org/$repo: $(strip(err))")
end

const LIST = Ref{Function}(list_repos)
const READ = Ref{Function}(read_file)

"The parsed TOML `text` of `where`; `nothing`, with a warning, when it cannot be parsed."
function parse_toml(text::AbstractString, where::AbstractString)
    try
        return TOML.parse(text)
    catch e
        @warn "cannot parse $where, skipped: $(sprint(showerror, e))"
        return nothing
    end
end

"""
    package_of(project) -> (; name, uuid) | nothing

The name and uuid of a parsed `Project.toml`; `nothing` when it is not a package (no
`name` or no `uuid`).
"""
function package_of(project::AbstractDict)
    (haskey(project, "name") && haskey(project, "uuid")) || return nothing
    return (; name=string(project["name"]), uuid=lowercase(string(project["uuid"])))
end

"""
    loaded_by(project, test, uuid) -> String | nothing

How the package of `uuid` is needed by a project (its parsed `Project.toml`, and its
`test/Project.toml` or `nothing`): `deps`, `weakdeps`, `extras` or `test`; `nothing` if not.
A table maps names to uuids, so that a package of the same name but another uuid is not it.
"""
function loaded_by(project::AbstractDict, test, uuid::AbstractString)
    has(tbl) = tbl isa AbstractDict && any(u -> lowercase(string(u)) == uuid, values(tbl))
    for table in ("deps", "weakdeps", "extras")
        has(get(project, table, nothing)) && return table
    end
    test !== nothing && has(get(test, "deps", nothing)) && return "test"
    return nothing
end

"""
    consumers(name, uuid; org=ORG) -> Vector{Target}

The packages of `org` that load the package `name` (of `uuid`), by their repository name
without `.jl`, sorted. Archived repositories, forks, `EXCLUDED` ones and any package of
the same uuid (the package itself) are left out.
"""
function consumers(name::AbstractString, uuid::AbstractString; org::AbstractString=ORG)
    uuid = lowercase(uuid)
    found = Target[]
    for (repo, archived, fork) in LIST[](org)
        endswith(repo, ".jl") || continue
        pkg = repo[1:end-3]
        (archived || fork || haskey(EXCLUDED, pkg)) && continue
        valid_name(pkg) || error("the repository name $(repr(pkg)) of $org is not a valid package name")
        text = READ[](org, repo, "Project.toml")
        text === nothing && continue
        project = parse_toml(text, "$repo/Project.toml")
        project === nothing && continue
        info = package_of(project)
        (info === nothing || info.uuid == uuid) && continue
        test_text = READ[](org, repo, "test/Project.toml")
        test = test_text === nothing ? nothing : parse_toml(test_text, "$repo/test/Project.toml")
        via = loaded_by(project, test, uuid)
        via === nothing && continue
        push!(found, (; name=pkg, owner=org, break_="test", source="derived (in the $via of $pkg)"))
    end
    return sort!(found; by=t -> (t.name, t.break_))
end

"""
    parse_targets(text) -> Vector{Target}

The targets of a JSON list of flat objects with string values, `{"name", "owner", "break"}`
(`owner` defaults to the organization, `break` to `test`); anything else is an error.
"""
function parse_targets(text::AbstractString; org::AbstractString=ORG)
    s = strip(text)
    isempty(s) && return Target[]
    objects = collect(eachmatch(r"\{[^{}]*\}", s))
    rest = replace(s, r"\{[^{}]*\}" => "")
    occursin(r"^\[[\s,]*\]$", rest) || throw(ArgumentError("targets must be a list of objects"))
    out = Target[]
    for m in objects
        body = m.match
        pairs = Dict{String,String}()
        for kv in eachmatch(r"\"([^\"\\]*)\"\s*:\s*\"([^\"\\]*)\"", body)
            pairs[kv[1]] = kv[2]
        end
        occursin(r"^\{[\s,]*\}$", replace(body, r"\"([^\"\\]*)\"\s*:\s*\"([^\"\\]*)\"" => "")) ||
            throw(ArgumentError("a target must have string values only: $body"))
        unknown = setdiff(keys(pairs), ("name", "owner", "break"))
        isempty(unknown) || throw(ArgumentError("unknown key $(first(unknown)) in a target: $body"))
        haskey(pairs, "name") || throw(ArgumentError("a target has no name: $body"))
        brk = get(pairs, "break", "test")
        brk in ("test", "doc") || throw(ArgumentError("break must be test or doc, not $brk: $body"))
        owner = get(pairs, "owner", org)
        (valid_name(pairs["name"]) && valid_name(owner)) || throw(ArgumentError("invalid name or owner: $body"))
        push!(out, (; name=pairs["name"], owner, break_=brk, source="declared"))
    end
    return out
end

"""
    plan(name, uuid; declared=Target[], derive=true, org=ORG) -> Vector{Target}

The targets of the suite: the derived consumers and the declared targets. A declared target
replaces the derived one of the same package, owner and check. Throws when there is
nothing to test: a package without consumers has no use for the suite.
"""
function plan(name::AbstractString, uuid::AbstractString; declared::Vector{Target}=Target[], derive::Bool=true, org::AbstractString=ORG)
    targets = declared
    if derive
        mine = Set((t.name, t.owner, t.break_) for t in declared)
        targets = vcat(declared, [t for t in consumers(name, uuid; org) if (t.name, t.owner, t.break_) ∉ mine])
    end
    isempty(targets) && error("no downstream package to test for $name: remove the Breakage workflow, or declare a target")
    return sort!(targets; by=t -> (t.name, t.break_, t.owner))
end

"The targets as the JSON list of the `targets` input of breakage-suite.yml, on one line."
json_targets(targets) = "[" * join(("{\"name\":\"$(t.name)\",\"owner\":\"$(t.owner)\",\"break\":\"$(t.break_)\"}" for t in targets), ",") * "]"

"A Markdown table of the targets and where each comes from."
function targets_table(name, targets)
    io = IOBuffer()
    println(io, "### Breakage targets — downstream of $name\n")
    println(io, "| Package | Check | Owner | Source |\n| --- | --- | --- | --- |")
    for t in targets
        println(io, "| $(t.name) | $(t.break_) | $(t.owner) | $(t.source) |")
    end
    return String(take!(io))
end

"The value of `--name` in `args` (removed from it), or `default`."
function option!(args, name, default=nothing)
    i = findfirst(==("--$name"), args)
    i === nothing && return default
    i == length(args) && throw(ArgumentError("--$name needs a value"))
    value = args[i+1]
    deleteat!(args, i:i+1)
    return value
end

const USAGE = """
usage: julia consumers.jl list --project Project.toml [--org ORG]
       julia consumers.jl plan --project Project.toml [--declared JSON] [--no-derive] [--org ORG] [--summary FILE]"""

"Run the command in `args`; return the exit code."
function consumers_main(args)
    args = collect(String, args)
    isempty(args) && (println(stderr, USAGE); return 2)
    command, args = args[1], args[2:end]
    command in ("list", "plan") || (println(stderr, USAGE); return 2)
    try
        project = option!(args, "project")
        project === nothing && throw(ArgumentError("--project is required"))
        org = option!(args, "org", ORG)
        declared = option!(args, "declared", "")
        summary = option!(args, "summary")
        derive = !("--no-derive" in args)
        filter!(!=("--no-derive"), args)
        isempty(args) || throw(ArgumentError("unexpected arguments: $(join(args, " "))"))
        info = package_of(TOML.parsefile(project))
        info === nothing && throw(ArgumentError("$project has no name and uuid: not a package"))
        if command == "list"
            println(json_targets(consumers(info.name, info.uuid; org)))
        else
            targets = plan(info.name, info.uuid; declared=parse_targets(declared; org), derive, org)
            println(json_targets(targets))
            summary === nothing || open(io -> print(io, targets_table(info.name, targets)), summary, "a")
        end
        return 0
    catch e
        e isa ArgumentError && (println(stderr, "error: ", e.msg, "\n", USAGE); return 2)
        println(stderr, "error: ", sprint(showerror, e))
        return 1
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(consumers_main(ARGS))
end
