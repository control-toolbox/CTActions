# REL4 of ct-conventions: a stable release resolves from the General registry alone.
#
# usage: julia registrable.jl [--base BASE_PROJECT] PROJECT
#
# PROJECT is the Project.toml of the package. With `--base`, the Project.toml of the base of
# a pull request: the check runs only when PROJECT sets a stable version (no pre-release
# suffix) other than the base's, and otherwise says why it does not apply and succeeds.
# Without `--base` it always runs.
#
# The `[deps]` of the package are resolved with its `[compat]`, then once more with each
# `[weakdeps]` entry added, against General only: the other registries of the depot
# (ct-registry) are ignored, so the check runs as is on a developer's machine. Resolution
# only, through Pkg's resolver: nothing is downloaded or installed. Every bound that no
# version in General satisfies is reported, with the versions of the other registries that
# do (a beta, usually). The Markdown report goes to standard output, and to
# $GITHUB_STEP_SUMMARY when set; the exit code is 1 when an environment does not resolve.
# Stdlib only.

using Pkg, TOML

const GENERAL = "General"

"""
    applies(project, base) -> (Bool, String)

Whether the check applies to `project` (a parsed Project.toml), given the `base` of the pull
request (`nothing` without one), and why.
"""
function applies(project::AbstractDict, base::Union{Nothing,AbstractDict})
    haskey(project, "version") || return (false, "no `version` in Project.toml")
    v = VersionNumber(project["version"])
    base === nothing && return (true, "`$v`, checked on request")
    isempty(v.prerelease) || return (false, "`$v` is a pre-release: REL4 applies to stable releases only")
    b = get(base, "version", nothing)
    b !== nothing && VersionNumber(b) == v && return (false, "`$v` is the version of the base: not a release")
    return (true, "`$(something(b, "none"))` → `$v`: a stable release")
end

"""
    environments(project) -> Vector{Pair{String,Dict{String,String}}}

The environments to resolve, as label => deps (name => uuid): the `[deps]` of `project`,
then the `[deps]` with each `[weakdeps]` entry added (one environment per extension trigger,
so that a weak dependency is never resolved against another one).
"""
function environments(project::AbstractDict)
    deps = Dict{String,String}(get(project, "deps", Dict()))
    envs = ["[deps]" => deps]
    for (name, uuid) in sort!(collect(get(project, "weakdeps", Dict())); by=first)
        push!(envs, "[deps] + $name" => merge(deps, Dict(name => uuid)))
    end
    return envs
end

"The `[compat]` entries of `project` that apply to `deps` (the `julia` entry is left to the running Julia)."
compat_for(project::AbstractDict, deps::AbstractDict) =
    Dict{String,String}(k => v for (k, v) in get(project, "compat", Dict()) if haskey(deps, k))

"The registry named `name` among `registries`, or `nothing`."
function registry(registries, name)
    i = findfirst(r -> r.name == name, registries)
    return i === nothing ? nothing : registries[i]
end

"The versions of the package `uuid` registered in `reg`, yanked ones excluded, sorted; empty if absent."
function registered_versions(reg, uuid::AbstractString)
    u = Base.UUID(uuid)
    haskey(reg, u) || return VersionNumber[]
    # internal: `registry_info(entry)` up to Julia 1.12, `registry_info(reg, entry)` from 1.13
    entry = reg[u]
    info = applicable(Pkg.Registry.registry_info, reg, entry) ?
           Pkg.Registry.registry_info(reg, entry) : Pkg.Registry.registry_info(entry)
    return sort!([v for v in keys(info.version_info) if !Pkg.Registry.isyanked(info, v)])
end

"The `versions` that satisfy the compat specifier `spec`."
satisfying(spec::AbstractString, versions) = filter(in(Pkg.Types.semver_spec(spec)), versions)

"""
    resolve(deps, compat, registries) -> (Bool, String)

Resolve a throwaway environment of `deps` (name => uuid) with `compat`, against `registries`
only, on the running Julia. Returns `(true, "")`, or `(false, message)` when unsatisfiable.

`Pkg.resolve` would download the result; `Pkg.Operations.resolve_versions!` only resolves.
It is internal, but its signature is the same from Julia 1.10 to 1.13 (the self-test runs
on each).
"""
function resolve(deps::AbstractDict, compat::AbstractDict, registries)
    dir = mktempdir()
    open(joinpath(dir, "Project.toml"), "w") do io
        TOML.print(io, Dict("deps" => deps, "compat" => compat))
    end
    current = Base.active_project()
    try
        Pkg.activate(dir; io=devnull)
        ctx = Pkg.Types.Context()
        pkgs = Pkg.Operations.load_direct_deps(ctx.env)
        Pkg.Operations.resolve_versions!(ctx.env, registries, pkgs, ctx.julia_version, false)
        return (true, "")
    catch e
        # Only an unsatisfiable resolution is a result; anything else is a bug.
        e isa Pkg.Resolve.ResolverError || rethrow()
        return (false, sprint(showerror, e))
    finally
        Pkg.activate(current; io=devnull)
        rm(dir; recursive=true, force=true)
    end
end

"""
    diagnose(project, general, others) -> Vector{NamedTuple}

The `[compat]` bounds of `project`'s deps and weakdeps that no version in `general`
satisfies, each with the versions of the registries `others` that do. Stdlibs are skipped.
"""
function diagnose(project::AbstractDict, general, others)
    deps = merge(Dict(get(project, "deps", Dict())), Dict(get(project, "weakdeps", Dict())))
    found = NamedTuple[]
    for (name, spec) in sort!(collect(compat_for(project, deps)); by=first)
        uuid = deps[name]
        Pkg.Types.is_stdlib(Base.UUID(uuid)) && continue
        in_general = registered_versions(general, uuid)
        isempty(satisfying(spec, in_general)) || continue
        elsewhere = [r.name => satisfying(spec, registered_versions(r, uuid)) for r in others]
        push!(found, (; name, spec, registered=!isempty(in_general), elsewhere=filter(!isempty ∘ last, elsewhere)))
    end
    return found
end

"The Markdown report."
function report(name, why, results, found)
    io = IOBuffer()
    ok = all(first ∘ last, results)
    println(io, "## REL4 — $name resolves from General alone: ", ok ? "✅ yes" : "❌ no", "\n")
    println(io, "Release: $why. Resolved on Julia $VERSION.\n")
    println(io, "| Environment | Resolves from General |\n| --- | --- |")
    for (label, (resolved, _)) in results
        println(io, "| $label | ", resolved ? "✅" : "❌", " |")
    end
    if !isempty(found)
        println(io, "\nBounds that no version in General satisfies:\n")
        for f in found
            where_ = isempty(f.elsewhere) ? "in no other registry either" :
                     join(("in $r: " * join(("`$v`" for v in vs), ", ") for (r, vs) in f.elsewhere), "; ")
            println(io, "- `$(f.name) = \"$(f.spec)\"`: ",
                    f.registered ? "" : "$(f.name) is not in General; ", "satisfied ", where_, ".")
        end
    end
    for (label, (resolved, msg)) in results
        resolved && continue
        println(io, "\n<details><summary>Resolver error, $label</summary>\n\n```text\n", strip(msg), "\n```\n</details>")
    end
    return String(take!(io))
end

"Parse the arguments, run the check, write the report; return the exit code."
function main(args)
    base = nothing
    if length(args) == 3 && args[1] == "--base"
        base = TOML.parsefile(args[2])
        args = args[3:end]
    end
    length(args) == 1 || (println(stderr, "usage: julia registrable.jl [--base BASE_PROJECT] PROJECT"); return 2)
    project = TOML.parsefile(args[1])
    name = get(project, "name", basename(dirname(abspath(args[1]))))
    run, why = applies(project, base)
    if !run
        text = "## REL4 — $name: not checked\n\n$why.\n"
        code = 0
    else
        registries = Pkg.Registry.reachable_registries()
        general = registry(registries, GENERAL)
        general === nothing && error("the General registry is not installed: `Pkg.Registry.add(\"General\")`")
        others = filter(r -> r.name != GENERAL, registries)
        results = [label => resolve(deps, compat_for(project, deps), [general]) for (label, deps) in environments(project)]
        text = report(name, why, results, diagnose(project, general, others))
        code = all(first ∘ last, results) ? 0 : 1
    end
    print(text)
    summary = get(ENV, "GITHUB_STEP_SUMMARY", "")
    isempty(summary) || open(io -> print(io, text), summary, "a")
    return code
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
