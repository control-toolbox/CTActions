# Resolve every audited environment on the running Julia.
#
# usage: julia resolve.jl <collected dir> <out.toml> [<prunes.toml> <baseline.toml>]
#
# Without prunes this is the baseline. With prunes, they are simulated all together (see
# `simulate` and `narrowings` in common.jl); environments that failed at baseline are copied
# as they are, there is nothing to compare them with.

include("common.jl")

"""
    resolve_all(root; prunes=[], baseline=Dict(), sim=simulate) -> Dict

Result of every environment of a collected directory, the baseline when `prunes` is empty.
"""
function resolve_all(root; prunes=[], baseline=Dict(), sim=simulate)
    envs, audited, uuids = load_collected(root)
    results = Dict{String,Any}()
    for name in sort(collect(keys(envs)))
        if isempty(prunes)
            r = sim(name, envs[name], Dict(), uuids)
        else
            base = baseline[name]
            r = base["ok"] ? sim(name, envs[name], narrowings(prunes, name, base["versions"], audited), uuids) : base
        end
        results[name] = r
        println(VERSION, "  ", rpad(name, 24), r["ok"] ? "ok" : "UNSAT")
    end
    return results
end

if abspath(PROGRAM_FILE) == @__FILE__
    root, outfile = ARGS[1], ARGS[2]
    prunes = length(ARGS) ≥ 4 ? TOML.parsefile(ARGS[3])["prune"] : []
    baseline = length(ARGS) ≥ 4 ? TOML.parsefile(ARGS[4])["env"] : Dict()
    results = resolve_all(root; prunes, baseline)
    open(io -> TOML.print(io, Dict("julia" => string(VERSION), "env" => results)), outfile, "w")
end
