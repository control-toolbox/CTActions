# Resolve every audited environment on the running Julia.
#
# usage: julia resolve.jl <collected dir> <out.toml> [<prunes.toml> <baseline.toml>]
#
# Without prunes this is the baseline. With prunes, they are simulated all together (see
# `simulate` and `narrowings` in common.jl); environments that failed at baseline are copied
# as they are, there is nothing to compare them with.

include("common.jl")

root, outfile = ARGS[1], ARGS[2]
prunes = length(ARGS) ≥ 4 ? TOML.parsefile(ARGS[3])["prune"] : []
baseline = length(ARGS) ≥ 4 ? TOML.parsefile(ARGS[4])["env"] : Dict()
envs, audited, uuids = load_collected(root)

results = Dict{String,Any}()
for name in sort(collect(keys(envs)))
    if isempty(prunes)
        r = simulate(name, envs[name], Dict(), uuids)
    else
        base = baseline[name]
        r = base["ok"] ? simulate(name, envs[name], narrowings(prunes, name, base["versions"], audited), uuids) : base
    end
    results[name] = r
    println(VERSION, "  ", rpad(name, 24), r["ok"] ? "ok" : "UNSAT")
end
open(io -> TOML.print(io, Dict("julia" => string(VERSION), "env" => results)), outfile, "w")
