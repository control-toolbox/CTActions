# Helpers shared by the compat-prune scripts. Stdlib only.

using Pkg, TOML

# Resolution only: never precompile the throwaway environments.
ENV["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
# Every resolution of an audit must see the same registry snapshot, or a release published
# meanwhile shows up as a difference: registries are updated once, by `audit.jl`, before
# anything else, and never again.
Pkg.offline(true)

"Run `gh` with `args` and return its standard output."
gh(args...) = read(`gh $args`, String)

"`gh api` call returning the raw body (blobs, file contents)."
gh_raw(path) = gh("api", path, "-H", "Accept: application/vnd.github.raw")

"`gh api` call returning one field extracted with `--jq`."
gh_jq(path, jq) = strip(gh("api", path, "--jq", jq))

"""
    resolve_env(deps, compat) -> Dict

Resolve a throwaway environment whose `[deps]` are `deps` (name => uuid) and whose
`[compat]` is `compat` (name => specifier), on the running Julia. Returns
`Dict("ok" => true, "manifest" => …)` with the parsed `Manifest.toml`, or
`Dict("ok" => false, "error" => …)` when the requirements are unsatisfiable.
"""
function resolve_env(deps::AbstractDict, compat::AbstractDict)
    dir = mktempdir()
    open(joinpath(dir, "Project.toml"), "w") do io
        TOML.print(io, Dict("deps" => deps, "compat" => compat))
    end
    current = Base.active_project()
    try
        Pkg.activate(dir; io=devnull)
        Pkg.resolve(; io=devnull)
        return Dict("ok" => true, "manifest" => TOML.parsefile(joinpath(dir, "Manifest.toml")))
    catch e
        # Only an unsatisfiable resolution is a result; anything else is a bug of the caller.
        e isa Pkg.Resolve.ResolverError || rethrow()
        return Dict("ok" => false, "error" => sprint(showerror, e))
    finally
        Pkg.activate(current; io=devnull)
        rm(dir; recursive=true, force=true)
    end
end

"Map name => version string for every entry of a parsed manifest (stdlibs: `\"stdlib\"`)."
manifest_versions(m) = Dict(k => get(v[1], "version", "stdlib") for (k, v) in m["deps"])

"Map name => git-tree-sha1 for every registered entry of a parsed manifest."
manifest_trees(m) =
    Dict(k => v[1]["git-tree-sha1"] for (k, v) in m["deps"] if haskey(v[1], "git-tree-sha1"))

"""
    registry_lookup(name) -> (uuid, repo)

UUID and GitHub `owner/repo` of a registered package, read from the first reachable registry
that knows it.
"""
function registry_lookup(name)
    for reg in Pkg.Registry.reachable_registries()
        uuids = Pkg.Registry.uuids_from_name(reg, name)
        isempty(uuids) && continue
        entry = reg[uuids[1]]
        # Signature changed in Julia 1.13: registry_info(entry) → registry_info(reg, entry).
        info = applicable(Pkg.Registry.registry_info, reg, entry) ?
            Pkg.Registry.registry_info(reg, entry) : Pkg.Registry.registry_info(entry)
        m = match(r"github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$", info.repo)
        m === nothing && error("$name: repository $(info.repo) is not on GitHub")
        return (string(uuids[1]), String(m[1]))
    end
    error("$name is not in any reachable registry")
end

const spec = Pkg.Types.semver_spec

"Render a VersionSpec back into a compat string (bounds carry no prerelease, so `-` only separates)."
render(vs) = join([replace(string(r), r"\s*-\s*" => " - ") for r in vs.ranges], ", ")

"""
    applies(owner, file, name, versions, audited) -> Bool

Does the compat entry of `owner` read from `file` constrain environment `name`, whose
resolved versions are `versions`? An entry of `Project.toml` applies wherever `owner` is
resolved at its audited version (another version carries other entries); an entry of
`test/` or `docs/Project.toml` applies only in that very environment.
"""
function applies(owner, file, name, versions, audited)
    file == "Project.toml" && return get(versions, owner, nothing) == audited[owner]
    return name == "$owner/$(first(splitpath(file)))"
end

"""
    simulate(name, env, narrowings, uuids) -> Dict

Resolve environment `name` (an entry of `envs.toml`) with each `dep => specifier` of
`narrowings` intersected into its compat. Pkg intersects the compat of every package of an
environment, so this is exactly what dropping specifiers from an entry that applies here
would do, without touching any file. Returns `Dict("ok" => true, "versions" => …)` or
`Dict("ok" => false, "error" => …)`; an empty intersection or a pinned package resolved at
another version than the audited one are failures too.
"""
function simulate(name, env, narrowings, uuids)
    deps, compat = copy(env["deps"]), copy(env["compat"])
    for (dep, s) in narrowings
        compat[dep] = render(spec(get(compat, dep, ">= 0")) ∩ spec(s))
        deps[dep] = uuids[dep]    # a transitive dep must be listed to carry a compat entry
    end
    empty = sort([k for (k, v) in compat if isempty(v)])
    isempty(empty) || return Dict("ok" => false, "error" => "empty compat intersection for $(join(empty, ", "))")
    res = resolve_env(deps, compat)
    res["ok"] || return res
    versions = manifest_versions(res["manifest"])
    off = ["$k $(versions[k]) (audited $v)" for (k, v) in env["pins"] if versions[k] != v]
    isempty(off) || return Dict("ok" => false, "error" => "pinned versions not selected: $(join(off, ", "))")
    return Dict("ok" => true, "versions" => versions)
end

"""
    narrowings(prunes, name, versions, audited) -> Dict

The `dep => kept specifiers` that `prunes` impose on environment `name` (baseline
`versions`): intersection over every prune whose entry applies here and whose dep is present.
"""
function narrowings(prunes, name, versions, audited)
    out = Dict{String,String}()
    for p in prunes
        haskey(versions, p["dep"]) && applies(p["owner"], p["file"], name, versions, audited) || continue
        out[p["dep"]] = haskey(out, p["dep"]) ? render(spec(out[p["dep"]]) ∩ spec(p["after"])) : p["after"]
    end
    return out
end

"""
    load_collected(root) -> (envs, audited, uuids)

`envs.toml`, the audited versions, and the uuid of every package named in an audited file
(`[deps]`, `[weakdeps]`, `[extras]`): a pruned dep is always declared by its owner, even
when it is only a transitive dependency of the environments.
"""
function load_collected(root)
    envs = TOML.parsefile(joinpath(root, "envs.toml"))["env"]
    audited = Dict(n => p["version"] for (n, p) in TOML.parsefile(joinpath(root, "index.toml"))["packages"])
    uuids = Dict{String,Any}()
    for (dir, _, files) in walkdir(joinpath(root, "registered")), f in files
        t = TOML.parsefile(joinpath(dir, f))
        for s in ("deps", "weakdeps", "extras"); merge!(uuids, get(t, s, Dict())); end
    end
    return envs, audited, uuids
end

"Parse a JSON list of strings such as `[\"a\",\"b\"]` (inputs of the reusable workflow)."
parse_list(s) = String[m[1] for m in eachmatch(r"\"([^\"]+)\"", s)]
