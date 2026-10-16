# Build the audited environments from the collected files.
#
# usage: julia envs.jl <collected dir>     (writes <collected dir>/envs.toml)
#
# Environments:
#   joint       every package together (what a user of the root package resolves)
#   <name>/test the test environment of a package: `test/Project.toml` when the package has
#               one, else the package plus its `[targets] test` with the package's own compat
#   <name>/docs `docs/Project.toml` plus the package itself (developed by `docs/make.jl`)
#
# The package that owns an environment (every package, for `joint`) is pinned to its audited
# version, so that the files read are exactly the ones resolved. Other packages float within
# the environment's own compat: `CTParser/test` may well require an older `CTModels`.
# Compat cannot name a prerelease (`=1.1.8-beta` does not parse), but `=1.1.8` admits
# `1.1.8-beta`: the pin drops the suffix and `resolve.jl` checks that the audited version is
# the one selected.

include("common.jl")

"Keep the compat entries that apply to `deps` (plus `julia`)."
restrict(compat, deps) = Dict(k => v for (k, v) in compat if k == "julia" || haskey(deps, k))

function test_env(name, uuid, dir)
    file = joinpath(dir, "test", "Project.toml")
    if isfile(file)
        t = TOML.parsefile(file)
        deps = merge(Dict(name => uuid), get(t, "deps", Dict()))
        return deps, restrict(get(t, "compat", Dict()), deps)
    end
    t = TOML.parsefile(joinpath(dir, "Project.toml"))
    known = merge(get(t, "deps", Dict()), get(t, "weakdeps", Dict()), get(t, "extras", Dict()))
    targets = get(get(t, "targets", Dict()), "test", collect(keys(get(t, "extras", Dict()))))
    deps = merge(Dict(name => uuid), Dict(k => known[k] for k in targets))
    return deps, restrict(get(t, "compat", Dict()), deps)
end

function docs_env(name, uuid, dir)
    file = joinpath(dir, "docs", "Project.toml")
    isfile(file) || return nothing
    t = TOML.parsefile(file)
    deps = merge(Dict(name => uuid), get(t, "deps", Dict()))
    return deps, restrict(get(t, "compat", Dict()), deps)
end

"""
    build_envs(root) -> Dict

The audited environments of a collected directory, as written to `envs.toml`: name =>
`owner`, `kind`, `deps`, `compat`, `pins` (the packages pinned to their audited version).
"""
function build_envs(root)
    index = TOML.parsefile(joinpath(root, "index.toml"))["packages"]
    pins = Dict(n => VersionNumber(p["version"]) for (n, p) in index)
    envs = Dict{String,Any}()
    envs["joint"] = (Dict(n => p["uuid"] for (n, p) in index), Dict{String,Any}())
    for (n, p) in index
        dir = joinpath(root, "registered", n)
        envs["$n/test"] = test_env(n, p["uuid"], dir)
        docs = docs_env(n, p["uuid"], dir)
        docs === nothing || (envs["$n/docs"] = docs)
    end
    out = Dict{String,Any}()
    for (name, (deps, compat)) in envs
        owner, kind = name == "joint" ? ("", "joint") : split(name, "/")
        pinned = Dict(string(k) => string(pins[k]) for k in (kind == "joint" ? keys(pins) : (owner,)))
        compat = merge(compat, Dict(k => (v = VersionNumber(v); "=$(v.major).$(v.minor).$(v.patch)") for (k, v) in pinned))
        out[name] = Dict("owner" => owner, "kind" => kind, "deps" => deps, "compat" => compat, "pins" => pinned)
    end
    return out
end

if abspath(PROGRAM_FILE) == @__FILE__
    root = ARGS[1]
    out = build_envs(root)
    open(io -> TOML.print(io, Dict("env" => out)), joinpath(root, "envs.toml"), "w")
    println(length(out), " environments: ", join(sort(collect(keys(out))), ", "))
end
