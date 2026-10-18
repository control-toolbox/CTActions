# Tests of registrable.jl.
#
# usage: julia scripts/registrable/test/runtests.jl
#
# Unit tests run on parsed projects and a fake registry (no resolution). Integration tests
# resolve the fixtures against the local General registry (nothing downloaded; seconds) and
# run the script as a command; they are skipped when General is not installed. The fixtures
# depend on Example 0.5 (General has 0.5.5) and OrderedCollections 1 and 2: a bound of 9 or
# more is satisfied by no version in General, which is what a beta-only bound looks like.

using Test, TOML

include(joinpath(@__DIR__, "..", "registrable.jl"))

const FIXTURES = joinpath(@__DIR__, "fixtures")
const SCRIPT = joinpath(@__DIR__, "..", "registrable.jl")
const EXAMPLE = "7876af07-990d-54b4-ab0e-23690620f79a"
const ORDERED = "bac558e1-5e72-5ebc-8fee-abe8a469f55d"

"A registry stand-in: a name and the registered versions of each uuid."
struct FakeRegistry
    name::String
    versions::Dict{String,Vector{VersionNumber}}
end

registered_versions(r::FakeRegistry, uuid::AbstractString) = get(r.versions, uuid, VersionNumber[])

fixture(name) = TOML.parsefile(joinpath(FIXTURES, name))

"Run the script as a command; return its exit code and standard output."
function command(args...)
    out = IOBuffer()
    p = run(pipeline(ignorestatus(`$(Base.julia_cmd()) --startup-file=no $SCRIPT $args`); stdout=out))
    return p.exitcode, String(take!(out))
end

@testset "registrable" begin
    @testset "applies" begin
        stable = Dict("version" => "1.2.0")
        @test applies(stable, Dict("version" => "1.1.0")) == (true, "`1.1.0` → `1.2.0`: a stable release")
        @test first(applies(stable, Dict{String,Any}()))           # no version in the base
        @test !first(applies(stable, Dict("version" => "1.2.0")))  # unchanged
        @test !first(applies(Dict("version" => "1.2.0-beta"), Dict("version" => "1.1.0")))
        # without a base, on request: always, a pre-release included
        @test first(applies(Dict("version" => "1.2.0-beta"), nothing))
        @test !first(applies(Dict{String,Any}(), nothing))
    end

    @testset "environments" begin
        envs = environments(fixture("stable.toml"))
        @test first.(envs) == ["[deps]", "[deps] + OrderedCollections"]
        @test last(envs[1]) == Dict("Example" => EXAMPLE)
        @test last(envs[2]) == Dict("Example" => EXAMPLE, "OrderedCollections" => ORDERED)
        @test first.(environments(fixture("beta-only.toml"))) == ["[deps]"]
    end

    @testset "compat_for" begin
        p = fixture("stable.toml")
        @test compat_for(p, Dict("Example" => EXAMPLE)) == Dict("Example" => "0.5")
        @test !haskey(compat_for(p, last(environments(p)[2])), "julia")
    end

    @testset "satisfying" begin
        vs = [v"0.8.15", v"0.9.0-beta", v"0.9.5-beta"]
        # Pkg's specifiers accept a pre-release of a version in range: ct-registry relies on it
        @test satisfying("0.9", vs) == [v"0.9.0-beta", v"0.9.5-beta"]
        @test satisfying("0.8", vs) == [v"0.8.15"]
        @test isempty(satisfying("1", vs))
    end

    @testset "diagnose" begin
        general = FakeRegistry("General", Dict(EXAMPLE => [v"0.5.5"], ORDERED => [v"1.6.0", v"2.0.3"]))
        beta = FakeRegistry("ct-registry", Dict(EXAMPLE => [v"0.9.0-beta"]))
        @test isempty(diagnose(fixture("stable.toml"), general, [beta]))
        found = diagnose(fixture("beta-only.toml"), general, [beta])
        @test length(found) == 1
        @test found[1].name == "Example" && found[1].spec == "0.9" && found[1].registered
        @test found[1].elsewhere == ["ct-registry" => [v"0.9.0-beta"]]
        # a weak dependency is diagnosed too; absent from General, satisfied nowhere
        found = diagnose(fixture("weak-beta-only.toml"), FakeRegistry("General", Dict(EXAMPLE => [v"0.5.5"])), [beta])
        @test only(found).name == "OrderedCollections"
        @test !only(found).registered && isempty(only(found).elsewhere)
    end

    @testset "report" begin
        ok = report("P", "`1.2.0`, checked on request", ["[deps]" => (true, "")], NamedTuple[])
        @test occursin("resolves from General alone: ✅ yes", ok)
        @test !occursin("Resolver error", ok)
        found = [(; name="Example", spec="0.9", registered=true, elsewhere=["ct-registry" => [v"0.9.0-beta"]])]
        ko = report("P", "w", ["[deps]" => (false, "unsatisfiable")], found)
        @test occursin("❌ no", ko)
        @test occursin("- `Example = \"0.9\"`: satisfied in ct-registry: `0.9.0-beta`.", ko)
        @test occursin("Resolver error, [deps]", ko)
    end

    general_installed = any(r -> r.name == GENERAL, Pkg.Registry.reachable_registries())
    if general_installed
        @testset "integration" begin
            g = registry(Pkg.Registry.reachable_registries(), GENERAL)
            p = fixture("stable.toml")
            @test all(first(resolve(deps, compat_for(p, deps), [g])) for (_, deps) in environments(p))
            p = fixture("beta-only.toml")
            resolved, msg = resolve(last(only(environments(p))), compat_for(p, Dict("Example" => EXAMPLE)), [g])
            @test !resolved && occursin("Example", msg)
            @test only(diagnose(p, g, [])).name == "Example"

            code, out = command(joinpath(FIXTURES, "stable.toml"))
            @test code == 0 && occursin("✅ yes", out)
            code, out = command(joinpath(FIXTURES, "beta-only.toml"))
            @test code == 1 && occursin("`Example = \"0.9\"`", out)
            # [deps] resolves, the environment of the weak dependency does not
            code, out = command(joinpath(FIXTURES, "weak-beta-only.toml"))
            @test code == 1
            @test occursin("| [deps] | ✅ |", out) && occursin("| [deps] + OrderedCollections | ❌ |", out)
            # a pull request that does not set a new stable version is not checked
            base = joinpath(FIXTURES, "beta-only.toml")  # version 1.2.0, as every fixture
            code, out = command("--base", base, base)
            @test code == 0 && occursin("not checked", out)
            @test command()[1] == 2
        end
    else
        @info "Integration tests skipped: the General registry is not installed"
    end
end
