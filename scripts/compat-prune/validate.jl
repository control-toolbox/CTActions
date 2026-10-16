# Validate the prunes and identify the blockers, on the running Julia.
#
# usage: julia validate.jl <collected dir> <classified.toml> <baseline.toml> <out.toml> <rejected.toml> [--blockers]
#
# Prunes: all of them (minus those already rejected) are simulated together; an environment
# whose manifest differs from the baseline, or that no longer resolves, is a failure. The
# prunes that apply in a failing environment are then simulated one by one there: those that
# fail alone are rejected; if none does, the failure comes from their combination and all of
# them are rejected. `audit.jl` repeats until no Julia version rejects anything.
#
# Blockers (`--blockers`, given by `audit.jl` on the newest Julia version only, as they are
# information and cost one resolution per environment): for each blocked entry, each
# environment where it applies is resolved with the dependency restricted to the newest
# specifier; the resolver's explanation names the packages that cap it.

include("common.jl")

"Short description of how `r` departs from the baseline versions `base`."
function departure(r, base)
    r["ok"] || return first(r["error"], 600)
    d = sort(["$k $(get(base, k, "—")) → $(get(r["versions"], k, "—"))"
              for k in union(keys(base), keys(r["versions"])) if get(base, k, "") != get(r["versions"], k, "")])
    isempty(d) ? nothing : "manifest differs: " * join(first(d, 6), ", ") * (length(d) > 6 ? ", …" : "")
end

"""
    blockers(msg, dep) -> Vector{String}

Packages that cap `dep`, read from the resolver's error when `dep` is restricted to its newest
specifier. The resolver reports the first conflict it meets, not every one: when that conflict
is on another package, that package is the blocker (its compat excludes the newest `dep`);
when it is on `dep` itself, the blockers are the first-level `restricted by compatibility
requirements with …` lines of its log (deeper lines explain those blockers, they are not
blockers of `dep`).
"""
function blockers(msg, dep)
    head = match(r"Unsatisfiable requirements detected for package (\S+) \[", msg)
    head === nothing && return String[]
    head[1] == dep || return [String(head[1])]
    first_level = r"^ [├└]─restricted by compatibility requirements with (\S+) \["m
    return sort(unique(String[m[1] for m in eachmatch(first_level, msg)]))
end


"""
    validate_prunes(envs, audited, uuids, prunes, baseline, julia; sim=simulate) -> rejected

Simulate `prunes` together in every environment of `envs` that resolved at `baseline`; in an
environment that departs from its baseline, simulate the prunes that apply there one by one
and reject those that fail alone, or all of them when none does. Returns the rejected
records (`owner`, `file`, `dep`, `where`, `reason`).
"""
function validate_prunes(envs, audited, uuids, prunes, baseline, julia; sim=simulate)
    prunes = copy(prunes)
    rejected = Dict{String,Any}[]
    for name in sort(collect(keys(envs)))
        base = baseline[name]
        base["ok"] || continue
        n = narrowings(prunes, name, base["versions"], audited)
        isempty(n) && continue
        why = departure(sim(name, envs[name], n, uuids), base["versions"])
        why === nothing && continue
        println(julia, "  ", rpad(name, 24), "fails together: ", why)
        suspects = [p for p in prunes if !isempty(narrowings([p], name, base["versions"], audited))]
        alone = Dict{Any,String}()
        for p in suspects
            w = departure(sim(name, envs[name], narrowings([p], name, base["versions"], audited), uuids), base["versions"])
            w === nothing || (alone[entry_key(p)] = w)
        end
        culprits = isempty(alone) ? suspects : [p for p in suspects if haskey(alone, entry_key(p))]
        for p in culprits
            reason = get(alone, entry_key(p), "fails only combined with other prunes: $why")
            push!(rejected, Dict("owner" => p["owner"], "file" => p["file"], "dep" => p["dep"],
                                 "where" => "$name@$julia", "reason" => reason))
            println("    rejected: $(p["owner"]) $(p["file"]) $(p["dep"]) → $(p["after"])")
        end
        gone = Set(entry_key.(culprits))
        filter!(p -> !(entry_key(p) in gone), prunes)
    end
    return rejected
end

"""
    probe_blockers(envs, uuids, blocked, baseline, julia; sim=simulate) -> probes

For each blocked entry, resolve every environment where it applies with the dependency
restricted to its newest specifier, and read the blockers from the resolver's error.
"""
function probe_blockers(envs, uuids, blocked, baseline, julia; sim=simulate)
    found = Dict{String,Any}[]
    for b in blocked, name in b["applies_in"]
        base = baseline[name]
        base["ok"] && haskey(base["versions"], b["dep"]) || continue
        r = sim(name, envs[name], Dict(b["dep"] => b["newest"]), uuids)
        push!(found, Dict("owner" => b["owner"], "file" => b["file"], "dep" => b["dep"],
                          "newest" => b["newest"], "where" => "$name@$julia",
                          "blockers" => r["ok"] ? String[] : blockers(r["error"], b["dep"]),
                          "detail" => r["ok"] ? "resolves, but the resolver prefers other versions" : first(r["error"], 2000)))
        println(julia, "  blocked: $(b["owner"]) $(b["file"]) $(b["dep"]) $(b["newest"]) in $name, by ",
                r["ok"] ? "nothing (resolver preference)" : join(found[end]["blockers"], ", "))
    end
    return found
end

if abspath(PROGRAM_FILE) == @__FILE__
    # usage: … <out.toml> <rejected.toml> [--blockers]
    root, classified, basefile, outfile, rejectedfile = ARGS[1:5]
    rejected_before = Set(entry_key.(get(TOML.parsefile(rejectedfile), "rejected", [])))
    envs, audited, uuids = load_collected(root)
    c = TOML.parsefile(classified)
    prunes = [p for p in c["prune"] if !(entry_key(p) in rejected_before)]
    baseline = TOML.parsefile(basefile)["env"]
    julia = join(split(string(VERSION), ".")[1:2], ".")
    rejected = validate_prunes(envs, audited, uuids, prunes, baseline, julia)
    blocked = [b for b in get(c, "other", []) if b["status"] == "blocked"]
    found = "--blockers" in ARGS ? probe_blockers(envs, uuids, blocked, baseline, julia) : Dict{String,Any}[]
    open(io -> TOML.print(io, Dict("julia" => string(VERSION), "rejected" => rejected, "blocked" => found)), outfile, "w")
    println(julia, "  ", length(rejected), " prune(s) rejected, ", length(found), " blocker probe(s)")
end
