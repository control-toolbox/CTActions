# report.jl: Markdown body of the tracking issue (golden file + properties).

"An audit and its edits covering every section of the report."
function report_fixture()
    index = TOML.parsefile(joinpath(COLLECTED, "index.toml"))["packages"]
    ev(pairs...) = Dict{String,Any}(spec => list for (spec, list) in pairs)
    edited = [
        merge(prune("Alpha", "Project.toml", "Dep1", "0.5, 0.6, 0.7", "0.6, 0.7"), Dict(
            "evidence" => ev("0.6" => ["joint@1.10=0.6.4"], "0.7" => ["joint@1.12=0.7.2", "Alpha/test@1.12=0.7.2"]),
            "status" => "edited", "detail" => "")),
        merge(prune("Alpha", "test/Project.toml", "Tool", "1, 2", "2"), Dict(
            "evidence" => ev("2" => ["Alpha/test@1.10=2.0.0", "Alpha/test@1.12=2.0.0"]),
            "status" => "edited", "detail" => "")),
        merge(prune("Beta", "Project.toml", "Dep1", "0.6, 0.7", "0.7"), Dict(
            "evidence" => ev("0.7" => ["Beta/test@1.12=0.7.2"]), "status" => "edited", "detail" => "")),
    ]
    already = [merge(prune("Beta", "Project.toml", "Tool", "1, 2", "2"), Dict("status" => "already", "detail" => "already `2`"))]
    drift = [merge(prune("Alpha", "docs/Project.toml", "Doc", "0.8, 0.9", "0.9"),
                   Dict("status" => "drift", "detail" => "`0.9, 1` on the default branch, `0.8, 0.9` audited"))]
    audit = Dict{String,Any}(
        "date" => "2026-10-15 19:48 UTC",
        "julia" => ["1.10", "1.12", "1.13"],
        "packages" => index,
        "prune" => vcat(edited, already, drift),
        "rejected" => [Dict("owner" => "Beta", "file" => "Project.toml", "dep" => "Weak", "where" => "Beta/test@1.10",
                            "reason" => "manifest differs: A 1.0.0 → 1.1.0 | odd\nsecond line")],
        "blocked" => [
            Dict("owner" => "Alpha", "file" => "docs/Project.toml", "dep" => "Doc", "newest" => "1",
                 "where" => "Alpha/docs@1.13", "blockers" => ["Documenter"], "detail" => ""),
            Dict("owner" => "Alpha", "file" => "docs/Project.toml", "dep" => "Doc", "newest" => "1",
                 "where" => "joint@1.13", "blockers" => ["Beta", "Documenter"], "detail" => ""),
            Dict("owner" => "Beta", "file" => "Project.toml", "dep" => "Weak", "newest" => "0.2",
                 "where" => "Beta/test@1.13", "blockers" => String[], "detail" => "resolves, but…"),
        ],
        "other" => [Dict("owner" => "Alpha", "file" => "Project.toml", "dep" => "Dep2", "before" => "1, 2",
                         "removed" => ["1"], "status" => "withheld",
                         "reason" => "baseline failed in joint@1.10: lanes used there are unknown")],
    )
    return audit, vcat(edited, already, drift)
end

@testset "report" begin
    audit, edits = report_fixture()
    prs = Dict("Alpha" => "https://github.com/example-org/Alpha.jl/pull/12")
    body = render_report(audit, edits; prs, run_url="https://github.com/example-org/Root.jl/actions/runs/1")

    @testset "golden" begin
        @test golden("report.md", body)
    end

    @testset "marker and sections" begin
        @test startswith(body, MARKER * "\n")
        for h in ("## Summary", "## To prune", "### Alpha — https://github.com/example-org/Alpha.jl/pull/12",
                  "### Beta", "## Merged, awaiting release", "## Drift", "## Rejected", "## Withheld",
                  "## Blocked", "## Audited versions")
            @test occursin("\n" * h * "\n", body)
        end
        # the reason of a rejection stays on one table row
        @test occursin("A 1.0.0 → 1.1.0 \\| odd second line", body)
        # blockers aggregated over environments; none found → resolver preference
        @test occursin("| Alpha `docs/Project.toml` `Doc` | `1` | Beta, Documenter |", body)
        @test occursin("| Beta `Project.toml` `Weak` | `0.2` | resolver preference |", body)
        @test occursin("| to prune (open PRs) | 3 |", body)
        @test occursin("| blocked (information) | 2 |", body)
    end

    @testset "deterministic" begin
        shuffled = deepcopy(audit)
        reverse!(shuffled["blocked"])
        @test render_report(shuffled, reverse(edits); prs, run_url="https://github.com/example-org/Root.jl/actions/runs/1") == body
    end

    @testset "empty sections are left out" begin
        quiet = Dict{String,Any}("date" => "2026-11-01 03:00 UTC", "julia" => ["1.10"], "packages" => audit["packages"],
                                 "prune" => [], "rejected" => [], "blocked" => [], "other" => [])
        b = render_report(quiet, [])
        @test occursin("| to prune (open PRs) | 0 |", b)
        for h in ("## To prune", "## Merged", "## Drift", "## Rejected", "## Withheld", "## Blocked")
            @test !occursin(h, b)
        end
        @test !occursin("[run]", b)
        @test occursin("## Audited versions", b)
    end

    @testset "helpers" begin
        @test table(["a", "b"], [["1", "2"]]) == "| a | b |\n| --- | --- |\n| 1 | 2 |"
        @test selected(Dict("0.9" => ["CTBase/test@1.10=0.9.18"], "0.12" => ["CTBase/test@1.12=0.12.3", "joint@1.13=0.12.3"])) ==
              "0.12.3 on 1.12, 1.13; 0.9.18 on 1.10"
        @test selected(Dict{String,Any}()) == ""
    end
end
