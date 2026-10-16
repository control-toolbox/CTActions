# Non-regression on a real audit (2026-10-15): the collected files of the eight CT packages,
# their default branches, and the baselines of Julia 1.10, 1.12, 1.13 (trimmed to the audited
# packages and the dependencies named in a compat entry, which is all classification reads).
# Environments, classification and edits must stay identical; the golden files are the
# reviewed outputs of that audit.

const SNAPSHOT = joinpath(FIXTURES, "snapshot-2026-10-15")

"Lines `owner | file | dep | status | detail`, sorted, for a golden file."
summary_lines(records, detail) =
    join(sort(["$(r["owner"]) | $(r["file"]) | $(r["dep"]) | $(r["status"]) | $(detail(r))" for r in records]), "\n") * "\n"

@testset "regression 2026-10-15" begin
    mktempdir() do dir
        root = joinpath(dir, "snapshot")
        cp(SNAPSHOT, root)
        envs = build_envs(root)
        open(io -> TOML.print(io, Dict("env" => envs)), joinpath(root, "envs.toml"), "w")

        @testset "environments" begin
            @test length(envs) == 17
            text = join(sort(["$name: deps=$(join(sort(collect(keys(e["deps"]))), ",")) " *
                              "pins=$(join(sort(["$k=$v" for (k, v) in e["pins"]]), ","))" for (name, e) in envs]), "\n") * "\n"
            @test golden("envs-2026-10-15.txt", text)
            # the docs env of every package contains the package itself
            @test all(e -> haskey(e["deps"], e["owner"]), [e for e in values(envs) if e["kind"] == "docs"])
        end

        results = load_results([joinpath(root, "baseline-$j.toml") for j in ("1.10", "1.12", "1.13")])
        prunes, others = classify_all(root, results)

        @testset "classification" begin
            detail(r) = r["status"] == "prune" ? r["after"] : r["status"] == "blocked" ? "newest " * r["newest"] : ""
            @test golden("classified-2026-10-15.txt", summary_lines(vcat(prunes, others), detail))
            got = Dict(entry_key(r) => r for r in vcat(prunes, others))
            @test length(prunes) == 42
            # CTSolvers keeps CUDSS 0.7: OptimalControl's tests and docs select it
            @test got[("CTSolvers", "Project.toml", "CUDSS")]["after"] == "0.7, 0.8"
            @test got[("CTSolvers", "docs/Project.toml", "CUDSS")]["after"] == "0.8"
            # JET 0.9 is what Julia 1.10 selects
            @test got[("CTBase", "Project.toml", "JET")]["after"] == "0.9, 0.12"
            # CTParser's own CTBase 0.29 lane is used by its test env (CTModels 0.18)
            @test got[("CTParser", "Project.toml", "CTBase")]["status"] == "keep"
            @test got[("CTParser", "test/Project.toml", "CTBase")]["status"] == "blocked"
            @test got[("CTBase", "Project.toml", "DocStringExtensions")]["status"] == "blocked"
        end

        @testset "edits against the default branches" begin
            records, texts = plan_edits(Dict("prune" => prunes), read_checkout(joinpath(root, "default")))
            @test golden("edits-2026-10-15.txt", summary_lines(records, r -> r["detail"]))
            @test count(r -> r["status"] == "edited", records) == 35
            drift = [r for r in records if r["status"] == "drift"]
            # CTParser's default branch is behind its registered version (CTParser#326)
            @test length(drift) == 7 && all(r -> r["owner"] == "CTParser", drift)
            # every edited file differs from its default branch by compat lines only
            for ((owner, file), text) in texts
                original = read(joinpath(root, "default", owner, file), String)
                a, b = TOML.parse(original), TOML.parse(text)
                delete!(a, "compat"); delete!(b, "compat")
                @test a == b
                changed = [l for l in split(text, '\n') if !(l in split(original, '\n'))]
                @test all(l -> occursin(r"^\w+ = \"[^\"]+\"$", l), changed)
            end
        end
    end
end
