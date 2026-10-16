# audit.jl: coverage of the baselines, and the record summarizing an audit.

@testset "audit" begin
    @testset "coverage" begin
        baselines = Dict(
            "1.12" => Dict("env" => Dict("joint" => ok(), "A/test" => ok(), "A/docs" => ok())),
            "1.10" => Dict("env" => Dict("joint" => ok(), "A/test" => failed(), "A/docs" => failed())),
        )
        c = coverage(baselines)
        @test [x["julia"] for x in c] == ["1.10", "1.12"]
        @test c[1]["resolved"] == 1 && c[1]["total"] == 3 && c[1]["failed"] == ["A/docs", "A/test"]
        @test c[2]["resolved"] == 3 && isempty(c[2]["failed"])
    end

    @testset "summarize" begin
        p(owner, dep, status="prune") = merge(prune(owner, "Project.toml", dep, "1, 2", "2"), Dict("status" => status))
        classified = Dict(
            "prune" => [p("A", "D1"), p("A", "D2"), p("B", "D3"),
                        p("B", "D5")],                                        # obsolete lane of a blocked entry
            "other" => [merge(p("B", "D4"), Dict("status" => "keep")),
                        merge(p("B", "D5"), Dict("status" => "blocked", "newest" => "3")),
                        merge(p("B", "D6"), Dict("status" => "idle")),
                        merge(p("A", "D7"), Dict("status" => "withheld"))],
        )
        rejected = [Dict("owner" => "A", "file" => "Project.toml", "dep" => "D2", "where" => "joint@1.12", "reason" => "x")]
        blocked = [Dict("owner" => "B", "file" => "Project.toml", "dep" => "D5", "newest" => "3", "where" => "joint@1.12",
                        "blockers" => ["Z"], "detail" => "")]
        a = summarize(; date="2026-11-01 04:00 UTC", julia=["1.10", "1.12"], index=Dict("packages" => Dict()),
                      classified, rejected, blocked, registries=[Dict("name" => "General", "state" => "tree abc")],
                      coverage=[Dict("julia" => "1.12", "resolved" => 2, "total" => 2, "failed" => String[])])
        # accepted prunes: classified minus rejected, the blocked entry's obsolete lane included
        @test sort(entry_key.(a["prune"])) == [("A", "Project.toml", "D1"), ("B", "Project.toml", "D3"), ("B", "Project.toml", "D5")]
        @test a["rejected"] == rejected && a["blocked"] == blocked
        # blocked records live in `blocked` (probes), not in `other`
        @test sort([r["status"] for r in a["other"]]) == ["idle", "keep", "withheld"]
        # one status per entry
        @test a["record"]["entries"] == Dict("examined" => 7, "prune" => 2, "rejected" => 1, "keep" => 1,
                                             "blocked" => 1, "idle" => 1, "withheld" => 1)
        @test a["record"]["registries"] == [Dict("name" => "General", "state" => "tree abc")]
        @test only(a["record"]["coverage"])["resolved"] == 2
        # the record survives a TOML round trip
        mktempdir() do dir
            path = joinpath(dir, "audit.toml")
            open(io -> TOML.print(io, a), path, "w")
            @test TOML.parsefile(path)["record"] == a["record"]
        end
    end
end
