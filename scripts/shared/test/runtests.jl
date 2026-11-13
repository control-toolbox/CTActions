# Tests of the code shared by the tools of scripts/ (scripts/shared).
#
# usage: julia scripts/shared/test/runtests.jl
#
# `gh` is replaced by a fake runner (`GH_RUN`): nothing goes to the network.

using Test

include(joinpath(@__DIR__, "..", "github.jl"))

"Run `f` with `GH_RUN` answering `answer(args)`; the arguments of each call go to `calls`."
function with_run(f, answer)
    calls = Vector{Vector{String}}()
    real = GH_RUN[]
    GH_RUN[] = args -> (push!(calls, args); answer(args))
    try
        f(calls)
    finally
        GH_RUN[] = real
    end
end

@testset "github" begin
    @testset "gh and gh_strip: stdout, or nothing on a failure" begin
        with_run(_ -> (0, " out\n", "")) do calls
            @test gh("api", "x") == " out\n"
            @test gh_strip("api", "x") == "out"
            @test calls[end] == ["api", "x"]
        end
        with_run(_ -> (1, "", "gh: Not Found (HTTP 404)")) do _
            @test gh("api", "x") === nothing
            @test gh_strip("api", "x") === nothing
        end
    end

    @testset "gh_status: the three parts" begin
        with_run(_ -> (1, "o", "e")) do _
            @test gh_status("api", "x") == (1, "o", "e")
        end
    end

    @testset "gh!, gh_raw, gh_jq, gh_api: a failure is an error with stderr" begin
        with_run(_ -> (1, "", "HTTP 502")) do _
            err = try gh_jq("repos/o/r", ".x"); nothing catch e; e end
            @test err isa ErrorException
            @test occursin("HTTP 502", err.msg) && occursin("repos/o/r", err.msg)
            @test_throws ErrorException gh_raw("p")
            @test_throws ErrorException gh_api("POST", "p")
        end
        with_run(_ -> (0, "body", "")) do calls
            @test gh_raw("repos/o/r/contents/f") == "body"
            @test calls[end] == ["api", "repos/o/r/contents/f", "-H", "Accept: application/vnd.github.raw"]
            @test gh_jq("p", ".x") == "body"
            @test gh_api("PATCH", "p", "state" => "closed", "body" => "a b"; jq=".url") == "body"
            @test calls[end] == ["api", "--method", "PATCH", "p", "-f", "state=closed", "-f", "body=a b", "--jq", ".url"]
        end
    end

    @testset "a fake GH is used as is" begin
        real = GH[]
        GH[] = args -> join(args, " ")
        try
            @test gh!("a", "b") == "a b"
        finally
            GH[] = real
        end
    end

    @testset "a second include keeps the runners" begin
        mine = args -> (0, "kept", "")
        real = GH_RUN[]
        GH_RUN[] = mine
        try
            include(joinpath(@__DIR__, "..", "github.jl"))
            @test GH_RUN[] === mine
        finally
            GH_RUN[] = real
        end
    end
end
