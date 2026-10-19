# Tests of the breakage report.
#
# usage: julia scripts/breakage/test/runtests.jl

using Test, TOML

include(joinpath(@__DIR__, "..", "report.jl"))

cell(name, version, status; brk="test") =
    Dict("name" => name, "owner" => "o", "version" => version, "break" => brk, "tag" => version == "stable" ? "v1.0.0" : "main",
         "compat" => "v0.30.11", "status" => status, "job" => "https://x/run")

@testset "breakage report" begin
    base = [cell("A", "latest", "pass"), cell("A", "stable", "pass"), cell("B", "latest", "fail"), cell("B", "stable", "fail")]

    @testset "not a release" begin
        v = verdict([cell("A", "stable", "fail")], nothing; expected=4)
        @test !v.release && v.ok
        v = verdict([cell("A", "stable", "fail")], nothing; expected=4, base_version=v"0.30.11", head_version=v"0.30.11")
        @test !v.release && v.ok
    end

    @testset "release" begin
        V0, V1, V2 = v"0.30.11", v"0.30.12", v"0.31.0"
        # nothing broken
        v = verdict(base, base; expected=4, base_version=V0, head_version=V1)
        @test v.ok && any(contains("no downstream release broken"), v.lines)
        # B already failed on the base: says nothing
        @test any(contains("already fails on the base"), v.lines)
        # A broken by a non-breaking release: blocked
        now = [cell("A", "latest", "pass"), cell("A", "stable", "fail"), cell("B", "latest", "fail"), cell("B", "stable", "fail")]
        v = verdict(now, base; expected=4, base_version=V0, head_version=V1)
        @test !v.ok && any(contains("must be breaking"), v.lines)
        # the same with a breaking number: expected
        v = verdict(now, base; expected=4, base_version=V0, head_version=V2)
        @test v.ok && any(contains("is breaking, as the breakage shows: A (test)"), v.lines)
        # only the stable column counts
        latest_only = [cell("A", "latest", "fail"), cell("A", "stable", "pass"), cell("B", "latest", "fail"), cell("B", "stable", "fail")]
        @test verdict(latest_only, base; expected=4, base_version=V0, head_version=V1).ok
        # no baseline, missing cells: blocked
        v = verdict(base, nothing; expected=4, base_version=V0, head_version=V1)
        @test !v.ok && any(contains("no breakage run on the base"), v.lines)
        v = verdict(base[1:3], base; expected=4, base_version=V0, head_version=V1)
        @test !v.ok && any(contains("1 of 4 cells have no result"), v.lines)
        # a package without tag, or absent from the base run (a target added since), is not
        # "broken by the release": nothing to compare with
        notag = [cell("A", "latest", "pass"), cell("A", "stable", "no_tag"), cell("C", "latest", "pass"), cell("C", "stable", "fail")]
        v = verdict(notag, base; expected=4, base_version=V0, head_version=V1)
        @test v.ok && any(contains("no downstream release broken"), v.lines)
        # more cells than expected (a rerun) is not "missing"
        @test verdict(vcat(base, base[1:1]), base; expected=4, base_version=V0, head_version=V1).ok
        # a beta release is checked the same way
        @test !verdict(now, base; expected=4, base_version=v"0.30.11", head_version=v"0.30.12-beta").ok
        @test verdict(now, base; expected=4, base_version=v"0.30.11", head_version=v"0.31.0-beta").ok
        # a doc check is its own cell
        docs = [cell("A", "stable", "pass"; brk="doc"), cell("A", "stable", "fail")]
        v = verdict(docs, [cell("A", "stable", "pass"; brk="doc"), cell("A", "stable", "pass")]; expected=2, base_version=V0, head_version=V1)
        @test !v.ok && any(contains("A (test)"), v.lines) && !any(contains("A (doc)"), v.lines)
    end

    @testset "files" begin
        mktempdir() do d
            cells = joinpath(d, "cells"); out = joinpath(d, "out"); mkpath(cells)
            for (i, c) in enumerate(base)
                open(io -> TOML.print(io, c), joinpath(cells, "$i.toml"), "w")
            end
            redirect_stdout(devnull) do
                @test report_main([cells, out, "--expected", "4", "--group", "packages", "--sha", "abc"]) == 0
            end
            saved = TOML.parsefile(joinpath(out, "breakage.toml"))
            @test saved["sha"] == "abc" && length(saved["cell"]) == 4
            text = read(joinpath(out, "summary.md"), String)
            @test startswith(text, marker("packages"))
            @test contains(text, "| A | test | [✅](https://x/run) `main`, compat v0.30.11 | [✅](https://x/run) `v1.0.0`, compat v0.30.11 |")
            @test !contains(text, "Release check")
            # a release PR compared with the saved run as baseline
            redirect_stdout(devnull) do
                @test report_main([cells, joinpath(d, "out2"), "--expected", "4", "--baseline", joinpath(out, "breakage.toml"),
                                   "--base-version", "0.30.11", "--head-version", "0.30.12"]) == 0
                @test report_main([cells, joinpath(d, "out3"), "--expected", "4",
                                   "--base-version", "0.30.11", "--head-version", "0.30.12"]) == 1
                @test report_main([cells]) == 2
            end
            @test contains(read(joinpath(d, "out3", "summary.md"), String), "Release check")
        end
    end
end
