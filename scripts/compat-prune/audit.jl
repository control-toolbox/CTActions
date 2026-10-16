# Run a whole audit: one registry snapshot, every Julia version.
#
# usage: julia audit.jl '<packages JSON list>' '<Julia versions JSON list>' <out dir>
#
# Each Julia version is run as `julia +<version>` (juliaup). Steps:
#   1. update the registries once; no later step updates them (see `resolve_env`)
#   2. collect.jl and envs.jl, on the last (newest) Julia version
#   3. resolve.jl: the baseline of every environment, on each Julia version
#   4. classify.jl, from all baselines
#   5. validate.jl on each Julia version, repeated with the rejected prunes removed until no
#      version rejects anything new (a smaller set of prunes is re-checked as a whole)
# Output: <out>/audit.toml (accepted prunes, rejected prunes, blockers, other entries, and
# the record of the audit itself: registries, coverage, entries), next to the intermediate
# files of every step.

using Dates, Pkg, TOML

include(joinpath(@__DIR__, "common.jl"))

short(v) = join(split(v, ".")[1:2], ".")

"""
    registry_snapshot() -> Vector{Dict}

Name and state of every reachable registry: the tree hash of a registry installed from a
tarball (General, through the package server), the commit of one cloned with git.
"""
function registry_snapshot()
    out = Dict{String,Any}[]
    for reg in Pkg.Registry.reachable_registries()
        state = if reg.tree_info !== nothing
            "tree $(reg.tree_info)"
        elseif isdir(joinpath(reg.path, ".git"))
            "commit " * readchomp(`git -C $(reg.path) rev-parse HEAD`)
        else
            "unknown"
        end
        push!(out, Dict("name" => reg.name, "state" => state))
    end
    return sort(out; by=r -> r["name"])
end

"""
    coverage(baselines) -> Vector{Dict}

For each Julia version (`julia` => parsed baseline), how many environments resolved, and
which failed.
"""
coverage(baselines) = [Dict("julia" => j, "resolved" => count(r -> r["ok"], values(b["env"])), "total" => length(b["env"]),
                            "failed" => sort([n for (n, r) in b["env"] if !r["ok"]]))
                       for (j, b) in sort(collect(baselines); by=first)]

"""
    summarize(; date, julia, index, classified, rejected, blocked, registries, coverage) -> Dict

The content of audit.toml: the accepted prunes (classified minus rejected), the rejected
ones, the blocker probes, the other entries (keep, idle, withheld), and the record of the
audit: registries, coverage, and how many multi-specifier entries were examined, with one
status each.
"""
function summarize(; date, julia, index, classified, rejected, blocked, registries, coverage)
    gone = Set(entry_key.(rejected))
    prunes = [p for p in classified["prune"] if !(entry_key(p) in gone)]
    others = [r for r in classified["other"] if r["status"] != "blocked"]
    # one status per entry: a blocked entry may also carry a prune of its obsolete lanes
    status = Dict{Any,String}()
    for p in classified["prune"]
        status[entry_key(p)] = entry_key(p) in gone ? "rejected" : "prune"
    end
    for r in classified["other"]; status[entry_key(r)] = r["status"]; end
    entries = Dict{String,Any}(s => count(==(s), values(status)) for s in ("prune", "rejected", "keep", "blocked", "idle", "withheld"))
    entries["examined"] = length(status)
    return Dict{String,Any}(
        "date" => date, "julia" => julia, "packages" => index["packages"],
        "prune" => prunes, "rejected" => rejected, "blocked" => blocked, "other" => others,
        "record" => Dict{String,Any}("registries" => registries, "coverage" => coverage, "entries" => entries),
    )
end

function run_step(v, script, args...)
    println("\n\$ julia +$v $script ", join(args, " "))
    run(`julia +$v --startup-file=no $(joinpath(@__DIR__, script)) $args`)
end

if abspath(PROGRAM_FILE) == @__FILE__
    packages, versions, out = ARGS[1], ARGS[2], abspath(ARGS[3])
    jlv = parse_list(versions)

    Pkg.Registry.update()
    registries = registry_snapshot()
    mkpath(out)

    run_step(last(jlv), "collect.jl", packages, out)
    run_step(last(jlv), "envs.jl", out)
    for v in jlv
        run_step(v, "resolve.jl", out, joinpath(out, "baseline-$(short(v)).toml"))
    end
    run_step(last(jlv), "classify.jl", out, joinpath(out, "classified.toml"),
             (joinpath(out, "baseline-$(short(v)).toml") for v in jlv)...)

    rejected = Dict{String,Any}[]
    blocked = Dict{String,Any}[]
    for round in 1:5
        open(io -> TOML.print(io, Dict("rejected" => rejected)), joinpath(out, "rejected.toml"), "w")
        new = Dict{String,Any}[]
        empty!(blocked)
        for v in jlv
            res = joinpath(out, "validated-$(short(v)).toml")
            blockers = v == last(jlv) ? ("--blockers",) : ()
            run_step(v, "validate.jl", out, joinpath(out, "classified.toml"),
                     joinpath(out, "baseline-$(short(v)).toml"), res, joinpath(out, "rejected.toml"), blockers...)
            r = TOML.parsefile(res)
            append!(new, r["rejected"])
            append!(blocked, r["blocked"])
        end
        known = Set(entry_key.(rejected))
        fresh = [p for p in new if !(entry_key(p) in known)]
        isempty(fresh) && break
        round == 5 && error("validation did not settle after 5 rounds")
        # one record per prune, the first reason found
        for p in fresh
            entry_key(p) in known || (push!(rejected, p); push!(known, entry_key(p)))
        end
    end

    baselines = Dict(short(v) => TOML.parsefile(joinpath(out, "baseline-$(short(v)).toml")) for v in jlv)
    audit = summarize(; date=Dates.format(now(UTC), "yyyy-mm-dd HH:MM") * " UTC", julia=jlv,
                      index=TOML.parsefile(joinpath(out, "index.toml")),
                      classified=TOML.parsefile(joinpath(out, "classified.toml")),
                      rejected, blocked, registries, coverage=coverage(baselines))
    open(io -> TOML.print(io, audit), joinpath(out, "audit.toml"), "w")
    e = audit["record"]["entries"]
    println("\n", e["examined"], " entries examined: ", length(audit["prune"]), " prune(s) accepted, ",
            length(rejected), " rejected, ", e["blocked"], " blocked, ", e["keep"], " kept, ", e["idle"], " idle, ",
            e["withheld"], " withheld")
end
