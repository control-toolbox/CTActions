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
# Output: <out>/audit.toml (accepted prunes, rejected prunes, blockers, other entries),
# next to the intermediate files of every step.

using Dates, Pkg, TOML

const HERE = @__DIR__
packages, versions, out = ARGS[1], ARGS[2], abspath(ARGS[3])
include(joinpath(HERE, "common.jl"))    # for parse_list
jlv = parse_list(versions)
short(v) = join(split(v, ".")[1:2], ".")

function run_step(v, script, args...)
    cmd = `julia +$v --startup-file=no $(joinpath(HERE, script)) $args`
    println("\n\$ julia +$v $script ", join(args, " "))
    run(cmd)
end

Pkg.Registry.update()
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

c = TOML.parsefile(joinpath(out, "classified.toml"))
gone = Set(entry_key.(rejected))
index = TOML.parsefile(joinpath(out, "index.toml"))
audit = Dict(
    "date" => Dates.format(now(UTC), "yyyy-mm-dd HH:MM") * " UTC",
    "julia" => jlv,
    "packages" => index["packages"],
    "prune" => [p for p in c["prune"] if !(entry_key(p) in gone)],
    "rejected" => rejected,
    "blocked" => blocked,
    "other" => [r for r in c["other"] if r["status"] != "blocked"],
)
open(io -> TOML.print(io, audit), joinpath(out, "audit.toml"), "w")
println("\n", length(audit["prune"]), " prune(s) accepted, ", length(rejected), " rejected, ",
        length(unique(entry_key.(blocked))), " blocked entr(y/ies)")
