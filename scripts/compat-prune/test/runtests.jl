# Unit tests of the pure logic of compat-prune (no resolution, no network).
#
# usage: julia scripts/compat-prune/test/runtests.jl

using Test

include(joinpath(@__DIR__, "..", "classify.jl"))
include(joinpath(@__DIR__, "..", "validate.jl"))

# Baseline results keyed "<env>@<julia>", as classify.jl builds them.
ok(versions...) = Dict("ok" => true, "versions" => Dict(versions...))

const AUDITED = Dict("CTSolvers" => "0.5.8", "CTParser" => "0.9.5-beta", "CTBase" => "0.30.9")

# Captured from real runs (2026-10-15): DocStringExtensions restricted to 0.10.
const CONFLICT_ON_DEP = """
Unsatisfiable requirements detected for package DocStringExtensions [ffbed154]:
 DocStringExtensions [ffbed154] log:
 ├─possible versions are: 0.9.3 - 0.10.0 or uninstalled
 ├─restricted to versions 0.10 by project [4e53ef5c], leaving only versions: 0.10.0
 │ └─project [4e53ef5c] log:
 │   ├─possible versions are: 0.0.0 or uninstalled
 │   └─project [4e53ef5c] is fixed to version 0.0.0
 └─restricted by compatibility requirements with SciMLBase [0bca4576] to versions: 0.9.5 — no versions left
   └─SciMLBase [0bca4576] log:
     ├─possible versions are: 2.77.2 - 3.58.0 or uninstalled
     └─restricted by compatibility requirements with Deeper [00000000] to versions: 3
"""
const CONFLICT_ON_OTHER = """
Unsatisfiable requirements detected for package DocumenterVitepress [4710194d]:
 DocumenterVitepress [4710194d] log:
 ├─possible versions are: 0.3.4 - 0.3.8 or uninstalled
 └─restricted by compatibility requirements with DocStringExtensions [ffbed154] to versions: uninstalled — no versions left
   └─DocStringExtensions [ffbed154] log:
     └─restricted to versions 0.10 by project [064cce67], leaving only versions: 0.10.0
"""

@testset "compat-prune" begin
    @testset "specifiers" begin
        @test specifiers("0.9, 0.11,0.12") == ["0.9", "0.11", "0.12"]
        @test lower("0.7 - 0.8") == v"0.7"
        @test lower("^1.2") == v"1.2"
        @test lower("=1.1.8") == v"1.1.8"
        @test render(spec("0.6, 0.7, 0.8") ∩ spec("0.7, 0.8")) == "0.7 - 0.8"
        @test render(spec("0.9, 0.11, 0.12") ∩ spec("0.9, 0.12")) == "0.9, 0.12"
        @test isempty(render(spec("0.7") ∩ spec("0.8")))
    end

    @testset "applies" begin
        v = Dict("CTSolvers" => "0.5.8")
        @test applies("CTSolvers", "Project.toml", "OptimalControl/test", v, AUDITED)
        # another version of the owner carries other compat entries
        @test !applies("CTSolvers", "Project.toml", "X/test", Dict("CTSolvers" => "0.4.0"), AUDITED)
        @test !applies("CTSolvers", "Project.toml", "X/test", Dict{String,String}(), AUDITED)
        # test/ and docs/ entries apply in their own environment only
        @test applies("CTParser", "test/Project.toml", "CTParser/test", v, AUDITED)
        @test !applies("CTParser", "test/Project.toml", "CTParser/docs", v, AUDITED)
        @test !applies("CTParser", "docs/Project.toml", "OptimalControl/docs", v, AUDITED)
    end

    @testset "owner scoping keeps CTSolvers' CUDSS 0.7" begin
        # OptimalControl's tests need CUDSS 0.7, CTDirect's take 0.8: both are CTSolvers users.
        results = Dict(
            "OptimalControl/test@1.12" => ok("CTSolvers" => "0.5.8", "CUDSS" => "0.7.0"),
            "CTDirect/test@1.12" => ok("CTSolvers" => "0.5.8", "CUDSS" => "0.8.1"),
            # an older CTSolvers selecting CUDSS 0.6 is not evidence for the audited file
            "Old/test@1.12" => ok("CTSolvers" => "0.4.0", "CUDSS" => "0.6.3"),
        )
        r = classify_entry("CTSolvers", "Project.toml", "CUDSS", "0.6, 0.7, 0.8", results, AUDITED)
        @test r["status"] == "prune"
        @test r["removed"] == ["0.6"]
        @test r["after"] == "0.7, 0.8"
        @test r["evidence"]["0.7"] == ["OptimalControl/test@1.12=0.7.0"]
    end

    @testset "a lane used on Julia 1.10 only is kept" begin
        results = Dict(
            "CTBase/test@1.10" => ok("CTBase" => "0.30.9", "JET" => "0.9.18"),
            "CTBase/test@1.12" => ok("CTBase" => "0.30.9", "JET" => "0.12.3"),
        )
        r = classify_entry("CTBase", "Project.toml", "JET", "0.9, 0.11, 0.12", results, AUDITED)
        @test r["status"] == "prune"
        @test r["after"] == "0.9, 0.12"
    end

    @testset "blocked, idle, keep" begin
        results = Dict("CTParser/test@1.12" => ok("CTParser" => "0.9.5-beta", "CTBase" => "0.29.3", "CUDSS" => "0.7.0"))
        r = classify_entry("CTParser", "test/Project.toml", "CTBase", "0.29, 0.30", results, AUDITED)
        @test r["status"] == "blocked"
        @test r["newest"] == "0.30"
        @test r["applies_in"] == ["CTParser/test"]
        @test !haskey(r, "prunable")
        # blocked, with an obsolete lane below the one in use
        r = classify_entry("CTParser", "test/Project.toml", "CUDSS", "0.6, 0.7, 0.8", results, AUDITED)
        @test r["status"] == "blocked"
        @test r["prunable"] == ["0.6"]
        # resolved nowhere the entry applies
        r = classify_entry("CTParser", "test/Project.toml", "CUDA", "5, 6", results, AUDITED)
        @test r["status"] == "idle"
        # every lane in use
        results = Dict("CTParser/test@1.10" => ok("CTParser" => "0.9.5-beta", "JET" => "0.9.18"),
                       "CTParser/test@1.12" => ok("CTParser" => "0.9.5-beta", "JET" => "0.12.3"))
        r = classify_entry("CTParser", "test/Project.toml", "JET", "0.9, 0.12", results, AUDITED)
        @test r["status"] == "keep"
    end

    @testset "a failed baseline withholds every prune" begin
        # On its own, the entry would lose 0.9: the 1.10 environment that uses it failed.
        results = Dict("CTBase/test@1.10" => Dict("ok" => false, "error" => "unsatisfiable"),
                       "CTBase/test@1.12" => ok("CTBase" => "0.30.9", "JET" => "0.12.3"))
        r = classify_entry("CTBase", "Project.toml", "JET", "0.9, 0.12", results, AUDITED)
        @test r["status"] == "prune"
        kept, withheld = withhold([r], results)
        @test isempty(kept)
        @test only(withheld)["status"] == "withheld"
        @test occursin("CTBase/test@1.10", only(withheld)["reason"])
        # all baselines resolved: nothing withheld
        kept, withheld = withhold([r], Dict("CTBase/test@1.12" => results["CTBase/test@1.12"]))
        @test kept == [r] && isempty(withheld)
    end

    @testset "narrowings" begin
        prunes = [Dict("owner" => "CTSolvers", "file" => "Project.toml", "dep" => "CUDSS", "after" => "0.7, 0.8"),
                  Dict("owner" => "CTSolvers", "file" => "docs/Project.toml", "dep" => "CUDSS", "after" => "0.8"),
                  Dict("owner" => "CTBase", "file" => "Project.toml", "dep" => "JET", "after" => "0.9, 0.12")]
        v = Dict("CTSolvers" => "0.5.8", "CUDSS" => "0.8.1", "CTBase" => "0.30.9")
        # JET absent: nothing to bind; the docs entry intersects with the root one
        @test narrowings(prunes, "CTSolvers/docs", v, AUDITED) == Dict("CUDSS" => "0.8")
        @test narrowings(prunes, "CTDirect/test", v, AUDITED) == Dict("CUDSS" => "0.7, 0.8")
        @test isempty(narrowings(prunes, "CTDirect/test", Dict("CUDSS" => "0.8.1"), AUDITED))
    end

    @testset "validate helpers" begin
        @test blockers(CONFLICT_ON_DEP, "DocStringExtensions") == ["SciMLBase"]
        @test blockers(CONFLICT_ON_OTHER, "DocStringExtensions") == ["DocumenterVitepress"]
        @test isempty(blockers("empty compat intersection for CUDSS", "CUDSS"))
        base = Dict("A" => "1.0.0", "B" => "2.0.0")
        @test departure(Dict("ok" => true, "versions" => copy(base)), base) === nothing
        @test departure(Dict("ok" => true, "versions" => Dict("A" => "1.0.0", "B" => "2.1.0")), base) ==
              "manifest differs: B 2.0.0 → 2.1.0"
        @test departure(Dict("ok" => false, "error" => "empty compat intersection for CUDSS"), base) ==
              "empty compat intersection for CUDSS"
    end
end
