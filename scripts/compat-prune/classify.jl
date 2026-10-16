# Classify every multi-specifier compat entry from the baselines of all Julia versions.
#
# usage: julia classify.jl <collected dir> <out.toml> <baseline.toml>...
#
# A specifier of the entry of `owner` on `dep` is *used* when, in an environment where that
# entry applies (see `applies` in common.jl) and on some Julia version, the resolved `dep`
# falls in it. Then, ordering specifiers by their lower bound:
#   prune    unused specifiers older than the newest used one: obsolete lanes;
#   blocked  the newest specifier is unused: something caps `dep` below it (reported, the
#            blocker is identified by validate.jl);
#   idle     `dep` is resolved nowhere the entry applies (e.g. a weak dependency no audited
#            environment loads): nothing can be proven, nothing is touched.
# Unused specifiers between the newest used one and the newest declared one are blocked
# lanes too, never pruned. If any baseline environment failed to resolve, the lanes it would
# have used are unknown: every prune is then withheld, and the failure is reported.

include("common.jl")

"Specifiers of a compat string, in declaration order."
specifiers(s) = String.(strip.(split(s, ",")))

"Lower bound of one specifier, for ordering (`\"0.7 - 0.8\"` → v0.7, `\"^1.2\"` → v1.2)."
lower(s) = VersionNumber(match(r"\d+(\.\d+){0,2}", s).match)

"""
    classify_entry(owner, file, dep, compat, results, audited) -> Dict

`results` maps `"<env>@<julia>"` to the parsed result of that environment. Returns a record
with `status` (`prune`, `blocked`, `keep`, `idle`), the specifiers used, and the evidence:
where each used specifier was selected.
"""
function classify_entry(owner, file, dep, compat, results, audited)
    parts = specifiers(compat)
    evidence = Dict(p => String[] for p in parts)
    for (key, r) in sort(collect(results); by=first)
        r["ok"] || continue
        name = first(split(key, "@"))
        v = get(r["versions"], dep, nothing)
        (v === nothing || !applies(owner, file, name, r["versions"], audited)) && continue
        for p in parts
            VersionNumber(v) in spec(p) && push!(evidence[p], "$key=$v")
        end
    end
    record = Dict{String,Any}("owner" => owner, "file" => file, "dep" => dep, "before" => compat)
    used = [p for p in parts if !isempty(evidence[p])]
    record["evidence"] = Dict(p => evidence[p] for p in used)
    isempty(used) && return merge(record, Dict("status" => "idle"))
    newest_used = maximum(lower, used)
    obsolete = [p for p in parts if isempty(evidence[p]) && lower(p) < newest_used]
    if maximum(lower, parts) > newest_used
        record["status"] = "blocked"
        record["newest"] = parts[argmax(lower.(parts))]
        record["applies_in"] = sort(unique(first.(split.(reduce(vcat, values(evidence)), "@"))))
        # obsolete lanes of a blocked entry are still obsolete: report both
        isempty(obsolete) || (record["prunable"] = obsolete)
        return record
    end
    isempty(obsolete) && return merge(record, Dict("status" => "keep"))
    return merge(record, Dict("status" => "prune", "removed" => obsolete,
                              "after" => join(setdiff(parts, obsolete), ", ")))
end

"Every multi-specifier entry of the audited files, classified."
function classify(root, results, audited)
    records = Dict{String,Any}[]
    for owner in sort(collect(keys(audited))), file in AUDITED_FILES
        path = joinpath(root, "registered", owner, file)
        isfile(path) || continue
        for (dep, compat) in sort(collect(get(TOML.parsefile(path), "compat", Dict())))
            dep == "julia" && continue
            length(specifiers(compat)) > 1 || continue
            push!(records, classify_entry(owner, file, dep, compat, results, audited))
        end
    end
    return records
end

"""
    withhold(prunes, results) -> (prunes, withheld)

Withhold every prune when a baseline environment (any `"<env>@<julia>"` of `results`) failed.
"""
function withhold(prunes, results)
    failed = sort([k for (k, r) in results if !r["ok"]])
    isempty(failed) && return prunes, Dict{String,Any}[]
    why = "baseline failed in $(join(failed, ", ")): lanes used there are unknown"
    return Dict{String,Any}[], [merge(p, Dict("status" => "withheld", "reason" => why)) for p in prunes]
end

"Baseline results of every Julia version, keyed `\"<env>@<major.minor>\"`."
function load_results(files)
    results = Dict{String,Any}()
    for f in files
        b = TOML.parsefile(f)
        j = join(split(b["julia"], ".")[1:2], ".")
        for (name, r) in b["env"]; results["$name@$j"] = r; end
    end
    return results
end

"""
    classify_all(root, results) -> (prunes, others)

Classify every entry; obsolete lanes of blocked entries become prunes of their own; every
prune is withheld when a baseline failed.
"""
function classify_all(root, results)
    _, audited, _ = load_collected(root)
    records = classify(root, results, audited)
    prunes = [r for r in records if r["status"] == "prune"]
    for r in records
        r["status"] == "blocked" && haskey(r, "prunable") || continue
        parts = specifiers(r["before"])
        push!(prunes, merge(r, Dict("status" => "prune", "removed" => r["prunable"],
                                    "after" => join(setdiff(parts, r["prunable"]), ", "))))
    end
    prunes, withheld = withhold(prunes, results)
    others = vcat([r for r in records if r["status"] != "prune"], withheld)
    return prunes, others
end

if abspath(PROGRAM_FILE) == @__FILE__
    root, outfile = ARGS[1], ARGS[2]
    prunes, others = classify_all(root, load_results(ARGS[3:end]))
    open(io -> TOML.print(io, Dict("prune" => prunes, "other" => others)), outfile, "w")
    for r in sort(vcat(prunes, others); by=r -> (r["owner"], r["file"], r["dep"]))
        println(rpad("$(r["owner"]) $(r["file"])", 34), rpad(r["dep"], 26), rpad(r["before"], 18), r["status"],
                haskey(r, "after") ? " → $(r["after"])" : "")
    end
end
