# classify.jl: which specifiers are used, and what becomes of each entry.

const AUDITED_C = Dict("CTSolvers" => "0.5.8", "CTParser" => "0.9.5-beta", "CTBase" => "0.30.9")

@testset "classify" begin
    @testset "specifiers and lower bounds" begin
        @test specifiers("0.9, 0.11,0.12") == ["0.9", "0.11", "0.12"]
        @test specifiers("1") == ["1"]
        @test lower("0.7 - 0.8") == v"0.7"
        @test lower("^1.2") == v"1.2"
        @test lower("~0.3.1") == v"0.3.1"
        @test lower("=1.1.8") == v"1.1.8"
        @test lower("1") == v"1"
    end

    @testset "owner scoping keeps CTSolvers' CUDSS 0.7" begin
        # OptimalControl's tests need CUDSS 0.7, CTDirect's take 0.8: both are CTSolvers users.
        results = Dict(
            "OptimalControl/test@1.12" => ok("CTSolvers" => "0.5.8", "CUDSS" => "0.7.0"),
            "CTDirect/test@1.12" => ok("CTSolvers" => "0.5.8", "CUDSS" => "0.8.1"),
            # an older CTSolvers selecting CUDSS 0.6 is no evidence for the audited file
            "Old/test@1.12" => ok("CTSolvers" => "0.4.0", "CUDSS" => "0.6.3"),
        )
        r = classify_entry("CTSolvers", "Project.toml", "CUDSS", "0.6, 0.7, 0.8", results, AUDITED_C)
        @test r["status"] == "prune"
        @test r["removed"] == ["0.6"]
        @test r["after"] == "0.7, 0.8"
        @test r["evidence"] == Dict("0.7" => ["OptimalControl/test@1.12=0.7.0"], "0.8" => ["CTDirect/test@1.12=0.8.1"])
    end

    @testset "a lane used on Julia 1.10 only is kept" begin
        results = Dict("CTBase/test@1.10" => ok("CTBase" => "0.30.9", "JET" => "0.9.18"),
                       "CTBase/test@1.12" => ok("CTBase" => "0.30.9", "JET" => "0.12.3"))
        r = classify_entry("CTBase", "Project.toml", "JET", "0.9, 0.11, 0.12", results, AUDITED_C)
        @test r["status"] == "prune"
        @test r["removed"] == ["0.11"]
        @test r["after"] == "0.9, 0.12"
    end

    @testset "declaration order is kept in `after`" begin
        results = Dict("X@1.12" => ok("CTBase" => "0.30.9", "D" => "2.0.0"),
                       "Y@1.12" => ok("CTBase" => "0.30.9", "D" => "1.5.0"))
        r = classify_entry("CTBase", "Project.toml", "D", "1.5, 0.9, 2", results, AUDITED_C)
        @test r["after"] == "1.5, 2"
    end

    @testset "blocked, idle, keep" begin
        results = Dict("CTParser/test@1.12" => ok("CTParser" => "0.9.5-beta", "CTBase" => "0.29.3", "CUDSS" => "0.7.0"))
        r = classify_entry("CTParser", "test/Project.toml", "CTBase", "0.29, 0.30", results, AUDITED_C)
        @test r["status"] == "blocked"
        @test r["newest"] == "0.30"
        @test r["applies_in"] == ["CTParser/test"]
        @test !haskey(r, "prunable")
        # blocked, with an obsolete lane below the one in use
        r = classify_entry("CTParser", "test/Project.toml", "CUDSS", "0.6, 0.7, 0.8", results, AUDITED_C)
        @test r["status"] == "blocked"
        @test r["prunable"] == ["0.6"]
        # an unused lane between the used one and the newest is blocked, never pruned
        r = classify_entry("CTParser", "test/Project.toml", "CUDSS", "0.7, 0.8, 0.9", results, AUDITED_C)
        @test r["status"] == "blocked" && r["newest"] == "0.9" && !haskey(r, "prunable")
        # resolved nowhere the entry applies
        r = classify_entry("CTParser", "test/Project.toml", "CUDA", "5, 6", results, AUDITED_C)
        @test r["status"] == "idle"
        # every lane in use
        results = Dict("CTParser/test@1.10" => ok("CTParser" => "0.9.5-beta", "JET" => "0.9.18"),
                       "CTParser/test@1.12" => ok("CTParser" => "0.9.5-beta", "JET" => "0.12.3"))
        r = classify_entry("CTParser", "test/Project.toml", "JET", "0.9, 0.12", results, AUDITED_C)
        @test r["status"] == "keep"
    end

    @testset "a failed environment is no evidence" begin
        results = Dict("CTBase/test@1.10" => failed(),
                       "CTBase/test@1.12" => ok("CTBase" => "0.30.9", "JET" => "0.12.3"))
        r = classify_entry("CTBase", "Project.toml", "JET", "0.9, 0.12", results, AUDITED_C)
        @test r["status"] == "prune" && r["after"] == "0.12"
    end

    @testset "withhold" begin
        r = prune("CTBase", "Project.toml", "JET", "0.9, 0.12", "0.12")
        results = Dict("CTBase/test@1.10" => failed(), "CTBase/test@1.12" => ok())
        kept, withheld = withhold([r], results)
        @test isempty(kept)
        @test only(withheld)["status"] == "withheld"
        @test occursin("CTBase/test@1.10", only(withheld)["reason"])
        kept, withheld = withhold([r], Dict("CTBase/test@1.12" => ok()))
        @test kept == [r] && isempty(withheld)
    end

    @testset "classify_all on the fixture" begin
        with_collected() do root
            prunes, others = classify_all(root, fixture_results())
            got = Dict(entry_key(r) => r for r in vcat(prunes, others))
            # Alpha's Dep1: 0.6 on 1.10 (joint), 0.7 on 1.12 → 0.5 is obsolete
            p = got[("Alpha", "Project.toml", "Dep1")]
            @test p["status"] == "prune" && p["after"] == "0.6, 0.7"
            # test/ entry: Tool 2 only
            p = got[("Alpha", "test/Project.toml", "Tool")]
            @test p["status"] == "prune" && p["after"] == "2"
            # docs/ entry: Doc 1 never selected
            b = got[("Alpha", "docs/Project.toml", "Doc")]
            @test b["status"] == "blocked" && b["newest"] == "1" && b["applies_in"] == ["Alpha/docs"]
            # Beta's Dep1: both lanes in use
            @test got[("Beta", "Project.toml", "Dep1")]["status"] == "keep"
            # Beta's weak dep: in no resolved environment
            @test got[("Beta", "Project.toml", "Weak")]["status"] == "idle"
            # single-specifier entries are not classified
            @test !haskey(got, ("Beta", "Project.toml", "Tool"))
            @test !haskey(got, ("Alpha", "Project.toml", "Beta"))
            @test length(prunes) == 2 && length(others) == 3
        end
    end

    @testset "classify_all: obsolete lane of a blocked entry, failed baseline" begin
        with_collected() do root
            results = fixture_results()
            # Doc: 0.8 lane obsolete, 1 blocked
            path = joinpath(root, "registered", "Alpha", "docs", "Project.toml")
            write(path, replace(read(path, String), "Doc = \"0.9, 1\"" => "Doc = \"0.8, 0.9, 1\""))
            prunes, others = classify_all(root, results)
            p = only(filter(r -> r["dep"] == "Doc", prunes))
            @test p["after"] == "0.9, 1" && p["removed"] == ["0.8"]
            @test any(r -> r["dep"] == "Doc" && r["status"] == "blocked", others)
            # a failed baseline withholds every prune
            results["Beta/test@1.10"] = failed()
            prunes, others = classify_all(root, results)
            @test isempty(prunes)
            @test count(r -> r["status"] == "withheld", others) == 3
        end
    end

    @testset "load_results" begin
        mktempdir() do dir
            for (j, v) in (("1.10.11", "0.6.4"), ("1.12.6", "0.7.2"))
                open(io -> TOML.print(io, Dict("julia" => j, "env" => Dict("joint" => ok("Dep1" => v)))),
                     joinpath(dir, "b-$j.toml"), "w")
            end
            r = load_results(joinpath.(dir, ["b-1.10.11.toml", "b-1.12.6.toml"]))
            @test r == Dict("joint@1.10" => ok("Dep1" => "0.6.4"), "joint@1.12" => ok("Dep1" => "0.7.2"))
        end
    end
end
