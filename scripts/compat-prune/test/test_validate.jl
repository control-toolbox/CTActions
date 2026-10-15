# validate.jl: departures, rejection of failing prunes (fake simulator), blockers.

"""
A fake simulator: the baseline `versions` of each environment, departed from (`Tool` moves to
9.9.9) when `breaks(name, narrowings)` holds. Records every call.
"""
function fake_sim(baseline; breaks=(name, n) -> false, error_for=Dict())
    calls = []
    sim = function (name, env, n, uuids)
        push!(calls, (name, copy(n)))
        haskey(error_for, name) && return failed(error_for[name])
        versions = copy(baseline[name]["versions"])
        breaks(name, n) && (versions["Tool"] = "9.9.9")
        return Dict("ok" => true, "versions" => versions)
    end
    return sim, calls
end

@testset "validate" begin
    @testset "departure" begin
        base = Dict("A" => "1.0.0", "B" => "2.0.0")
        @test departure(ok("A" => "1.0.0", "B" => "2.0.0"), base) === nothing
        @test departure(ok("A" => "1.0.0", "B" => "2.1.0"), base) == "manifest differs: B 2.0.0 → 2.1.0"
        @test departure(ok("A" => "1.0.0"), base) == "manifest differs: B 2.0.0 → —"
        @test departure(ok("A" => "1.0.0", "B" => "2.0.0", "C" => "3.0.0"), base) == "manifest differs: C — → 3.0.0"
        @test departure(failed("empty compat intersection for CUDSS"), base) == "empty compat intersection for CUDSS"
        many = Dict("P$i" => "1.0.$i" for i in 1:9)
        @test endswith(departure(ok(), many), ", …")
    end

    @testset "blockers" begin
        @test blockers(CONFLICT_ON_DEP, "DocStringExtensions") == ["SciMLBase"]
        @test blockers(CONFLICT_ON_OTHER, "DocStringExtensions") == ["DocumenterVitepress"]
        @test isempty(blockers("empty compat intersection for CUDSS", "CUDSS"))
    end

    with_collected() do root
        envs, audited, uuids = load_collected(root)
        baseline = Dict(name => r for (k, r) in fixture_results() for name in (first(split(k, "@")),) if endswith(k, "@1.12"))
        dep1 = prune("Alpha", "Project.toml", "Dep1", "0.5, 0.6, 0.7", "0.6, 0.7")
        tool = prune("Alpha", "test/Project.toml", "Tool", "1, 2", "2")

        @testset "nothing departs" begin
            sim, calls = fake_sim(baseline)
            @test isempty(validate_prunes(envs, audited, uuids, [dep1, tool], baseline, "1.12"; sim))
            # one combined simulation per environment where a prune applies: Dep1 wherever
            # Alpha is (not Beta/test), Tool in Alpha/test only
            @test calls == [("Alpha/docs", Dict("Dep1" => "0.6, 0.7")),
                            ("Alpha/test", Dict("Dep1" => "0.6, 0.7", "Tool" => "2")),
                            ("joint", Dict("Dep1" => "0.6, 0.7"))]
        end

        @testset "a culprit fails alone" begin
            sim, calls = fake_sim(baseline; breaks=(name, n) -> get(n, "Tool", "") == "2")
            rejected = validate_prunes(envs, audited, uuids, [dep1, tool], baseline, "1.12"; sim)
            @test length(rejected) == 1
            r = only(rejected)
            @test entry_key(r) == entry_key(tool)
            @test r["where"] == "Alpha/test@1.12"
            @test r["reason"] == "manifest differs: Tool 2.0.0 → 9.9.9"
        end

        @testset "prunes that fail only together are all rejected" begin
            sim, _ = fake_sim(baseline; breaks=(name, n) -> haskey(n, "Tool") && haskey(n, "Dep1"))
            rejected = validate_prunes(envs, audited, uuids, [dep1, tool], baseline, "1.12"; sim)
            @test sort(entry_key.(rejected)) == sort(entry_key.([dep1, tool]))
            @test all(r -> startswith(r["reason"], "fails only combined with other prunes"), rejected)
        end

        @testset "a rejected prune is not simulated again in later environments" begin
            # Dep1 breaks everywhere: rejected in the first environment (sorted: Alpha/docs),
            # then absent from the simulations of the next ones.
            sim, calls = fake_sim(baseline; breaks=(name, n) -> haskey(n, "Dep1"))
            rejected = validate_prunes(envs, audited, uuids, [dep1], baseline, "1.12"; sim)
            @test only(rejected)["where"] == "Alpha/docs@1.12"
            # combined + alone in Alpha/docs, then nothing left to simulate
            @test length(calls) == 2
        end

        @testset "environments that failed at baseline are skipped" begin
            b = copy(baseline)
            b["joint"] = failed()
            sim, calls = fake_sim(baseline)
            validate_prunes(envs, audited, uuids, [dep1], b, "1.12"; sim)
            @test !("joint" in first.(calls))
        end

        @testset "probe_blockers" begin
            blocked = [Dict("owner" => "Alpha", "file" => "docs/Project.toml", "dep" => "Doc",
                            "newest" => "1", "applies_in" => ["Alpha/docs", "Alpha/test"])]
            msg = replace(CONFLICT_ON_OTHER, "DocStringExtensions" => "Doc")
            sim, calls = fake_sim(baseline; error_for=Dict("Alpha/docs" => msg))
            found = probe_blockers(envs, uuids, blocked, baseline, "1.12"; sim)
            # Alpha/test does not have Doc: not probed
            @test calls == [("Alpha/docs", Dict("Doc" => "1"))]
            f = only(found)
            @test f["where"] == "Alpha/docs@1.12"
            @test f["blockers"] == ["DocumenterVitepress"]
            @test f["newest"] == "1"
            # restricted to the newest, it resolves: the resolver merely prefers other versions
            sim, _ = fake_sim(baseline)
            f = only(probe_blockers(envs, uuids, blocked, baseline, "1.12"; sim))
            @test isempty(f["blockers"])
            @test f["detail"] == "resolves, but the resolver prefers other versions"
        end
    end
end
