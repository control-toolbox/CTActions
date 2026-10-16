# common.jl: specifier arithmetic, where an entry applies, simulation (fake resolver).

const AUDITED = Dict("CTSolvers" => "0.5.8", "CTParser" => "0.9.5-beta", "CTBase" => "0.30.9")

@testset "common" begin
    @testset "parse_list" begin
        @test parse_list("[\"CTBase\",\"CTParser\"]") == ["CTBase", "CTParser"]
        @test parse_list("[ \"1.10\" , \"1.12\" ]") == ["1.10", "1.12"]
        @test isempty(parse_list("[]"))
    end

    @testset "render" begin
        @test render(spec("0.6, 0.7, 0.8") ∩ spec("0.7, 0.8")) == "0.7 - 0.8"
        @test render(spec("0.9, 0.11, 0.12") ∩ spec("0.9, 0.12")) == "0.9, 0.12"
        @test render(spec(">= 0") ∩ spec("1")) == "1"
        @test isempty(render(spec("0.7") ∩ spec("0.8")))
        # a rendered spec parses back to the same set
        for s in ("0.6, 0.7, 0.8", "1.8, 2", "0.30.8", "5 - 6")
            @test spec(render(spec(s))) == spec(s)
        end
    end

    @testset "entry_key" begin
        p = prune("CTSolvers", "Project.toml", "CUDSS", "0.6, 0.7, 0.8", "0.7, 0.8")
        @test entry_key(p) == ("CTSolvers", "Project.toml", "CUDSS")
    end

    @testset "applies" begin
        v = Dict("CTSolvers" => "0.5.8")
        @test applies("CTSolvers", "Project.toml", "OptimalControl/test", v, AUDITED)
        @test applies("CTSolvers", "Project.toml", "joint", v, AUDITED)
        # another version of the owner carries other compat entries
        @test !applies("CTSolvers", "Project.toml", "X/test", Dict("CTSolvers" => "0.4.0"), AUDITED)
        @test !applies("CTSolvers", "Project.toml", "X/test", Dict{String,String}(), AUDITED)
        # test/ and docs/ entries apply in their own environment only
        @test applies("CTParser", "test/Project.toml", "CTParser/test", v, AUDITED)
        @test applies("CTParser", "docs/Project.toml", "CTParser/docs", v, AUDITED)
        @test !applies("CTParser", "test/Project.toml", "CTParser/docs", v, AUDITED)
        @test !applies("CTParser", "docs/Project.toml", "OptimalControl/docs", v, AUDITED)
        @test !applies("CTParser", "test/Project.toml", "joint", v, AUDITED)
    end

    @testset "narrowings" begin
        prunes = [prune("CTSolvers", "Project.toml", "CUDSS", "0.6, 0.7, 0.8", "0.7, 0.8"),
                  prune("CTSolvers", "docs/Project.toml", "CUDSS", "0.6, 0.7, 0.8", "0.8"),
                  prune("CTBase", "Project.toml", "JET", "0.9, 0.11, 0.12", "0.9, 0.12")]
        v = Dict("CTSolvers" => "0.5.8", "CUDSS" => "0.8.1", "CTBase" => "0.30.9")
        # JET absent: nothing to bind; the docs entry intersects with the root one
        @test narrowings(prunes, "CTSolvers/docs", v, AUDITED) == Dict("CUDSS" => "0.8")
        @test narrowings(prunes, "CTDirect/test", v, AUDITED) == Dict("CUDSS" => "0.7, 0.8")
        # the owner is absent: the entry does not apply
        @test isempty(narrowings(prunes, "CTDirect/test", Dict("CUDSS" => "0.8.1"), AUDITED))
        @test narrowings(prunes, "CTBase/test", Dict("CTBase" => "0.30.9", "JET" => "0.12.3"), AUDITED) ==
              Dict("JET" => "0.9, 0.12")
        @test isempty(narrowings([], "joint", v, AUDITED))
    end

    @testset "simulate (fake resolver)" begin
        env = Dict("deps" => Dict("Own" => "u-own", "A" => "u-a"),
                   "compat" => Dict("Own" => "=1.0.0", "A" => "0.6, 0.7, 0.8"),
                   "pins" => Dict("Own" => "1.0.0"))
        uuids = Dict("A" => "u-a", "T" => "u-t")
        calls = []
        resolver(versions) = (deps, compat) -> (push!(calls, (copy(deps), copy(compat)));
                                                Dict("ok" => true, "versions" => Dict{String,Any}(versions), "trees" => Dict()))
        # the narrowed compat is intersected with the environment's own
        r = simulate("Own/test", env, Dict("A" => "0.7, 0.8"), uuids; resolver=resolver(Dict("Own" => "1.0.0", "A" => "0.8.1")))
        @test r == Dict("ok" => true, "versions" => Dict("Own" => "1.0.0", "A" => "0.8.1"))
        @test last(calls)[2]["A"] == "0.7 - 0.8"
        @test last(calls)[2]["Own"] == "=1.0.0"
        # a transitive dependency is listed to carry its compat entry
        simulate("Own/test", env, Dict("T" => "2"), uuids; resolver=resolver(Dict("Own" => "1.0.0", "T" => "2.1.0")))
        @test last(calls)[1]["T"] == "u-t"
        @test last(calls)[2]["T"] == "2"
        # the environment itself is not modified
        @test !haskey(env["deps"], "T")
        # an empty intersection fails without calling the resolver
        n = length(calls)
        r = simulate("Own/test", env, Dict("A" => "0.5"), uuids; resolver=resolver(Dict()))
        @test !r["ok"] && occursin("empty compat intersection for A", r["error"])
        @test length(calls) == n
        # a pinned package resolved at another version (e.g. a stable release next to the
        # audited prerelease) is a failure
        r = simulate("Own/test", env, Dict(), uuids; resolver=resolver(Dict("Own" => "1.0.1")))
        @test !r["ok"] && occursin("pinned versions not selected: Own 1.0.1 (audited 1.0.0)", r["error"])
        # a resolver failure is passed through
        r = simulate("Own/test", env, Dict(), uuids; resolver=(d, c) -> failed("boom"))
        @test r == failed("boom")
    end

    @testset "load_collected" begin
        mktempdir() do dir
            cp(COLLECTED, joinpath(dir, "c"))
            root = joinpath(dir, "c")
            write(joinpath(root, "envs.toml"), "[env]\n")
            envs, audited, uuids = load_collected(root)
            @test audited == Dict("Alpha" => "0.3.1", "Beta" => "1.2.0-beta")
            # every package named in an audited file, from [deps], [weakdeps] and [extras]
            for n in ("Beta", "Dep1", "Tool", "Doc", "Weak", "Unused", "Test")
                @test haskey(uuids, n)
            end
        end
    end
end
