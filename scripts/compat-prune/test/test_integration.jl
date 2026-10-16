# Integration: real Pkg resolutions against the local General registry, then the
# scripts run as commands on a one-package ecosystem: Example 0.5.5, whose docs declare
# `OrderedCollections = "1, 2"` (only 2 is selectable with nothing else in the way).
#
# Run with COMPAT_PRUNE_INTEGRATION=1. Needs General installed (any recent copy).

const EXAMPLE = "7876af07-990d-54b4-ab0e-23690620f79a"
const ORDERED = "bac558e1-5e72-5ebc-8fee-abe8a469f55d"
const JULIA = Base.julia_cmd()

"Write a collected directory for Example 0.5.5 into `root`; `docs_compat` is the docs compat of OrderedCollections."
function example_collected(root; docs_compat="1, 2")
    reg = joinpath(root, "registered", "Example")
    mkpath(joinpath(reg, "docs"))
    write(joinpath(reg, "Project.toml"), """
        name = "Example"
        uuid = "$EXAMPLE"
        version = "0.5.5"

        [compat]
        julia = "1"

        [extras]
        Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

        [targets]
        test = ["Test"]
        """)
    write(joinpath(reg, "docs", "Project.toml"), """
        [deps]
        OrderedCollections = "$ORDERED"

        [compat]
        OrderedCollections = "$docs_compat"
        """)
    cp(joinpath(root, "registered"), joinpath(root, "default"))
    open(joinpath(root, "index.toml"), "w") do io
        TOML.print(io, Dict("julia" => string(VERSION), "packages" => Dict("Example" => Dict(
            "uuid" => EXAMPLE, "version" => "0.5.5", "repo" => "JuliaLang/Example.jl", "tree" => "0",
            "default_branch" => "master", "files" => ["Project.toml", "docs/Project.toml"],
            "default_files" => ["Project.toml", "docs/Project.toml"]))))
    end
    return root
end

"Run a script of compat-prune with `args` on the running Julia; return its output."
run_script(script, args...) = read(`$JULIA --startup-file=no $(joinpath(SCRIPTS, script)) $args`, String)

@testset "integration" begin
    @testset "resolve_env" begin
        r = resolve_env(Dict("Example" => EXAMPLE), Dict("Example" => "0.5"))
        @test r["ok"]
        @test startswith(r["versions"]["Example"], "0.5.")
        # the registered tree is known, stdlibs have none
        @test length(r["trees"]["Example"]) == 40
        r = resolve_env(Dict("Example" => EXAMPLE, "LinearAlgebra" => "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"), Dict())
        @test haskey(r["versions"], "LinearAlgebra") && !haskey(r["trees"], "LinearAlgebra")
        # unsatisfiable: a result, not an exception
        r = resolve_env(Dict("Example" => EXAMPLE), Dict("Example" => "99"))
        @test !r["ok"] && occursin("Example", r["error"])
        # anything else is a bug of the caller: thrown
        @test_throws Exception resolve_env(Dict("Example" => EXAMPLE), Dict("Example" => "not a version"))
    end

    @testset "registry_snapshot" begin
        snap = registry_snapshot()
        @test any(r -> r["name"] == "General", snap)
        @test issorted([r["name"] for r in snap])
        @test all(r -> occursin(r"^(tree|commit) [0-9a-f]{40}$|^unknown$", r["state"]), snap)
    end

    @testset "registry_lookup" begin
        @test registry_lookup("Example") == (EXAMPLE, "JuliaLang/Example.jl")
        @test_throws ErrorException registry_lookup("NoSuchPackageForCompatPrune")
    end

    @testset "collect.jl as a command (fake gh on PATH)" begin
        mktempdir() do dir
            # canned answers of `gh api <path> …`, one file per path
            answers = joinpath(dir, "answers")
            mkpath(answers)
            put(path, text) = write(joinpath(answers, replace(path, r"[/?=]" => "_")), text)
            project = "name = \"Example\"\nuuid = \"$EXAMPLE\"\nversion = \"0.5.5\"\n"
            tree = resolve_env(Dict("Example" => EXAMPLE), Dict("Example" => "=0.5.5"))["trees"]["Example"]
            put("repos/JuliaLang/Example.jl", "master\n")
            put("repos/JuliaLang/Example.jl/git/trees/$tree?recursive=1", "Project.toml b1\nsrc/Example.jl b2\n")
            put("repos/JuliaLang/Example.jl/git/trees/master?recursive=1", "Project.toml b3\n")
            put("repos/JuliaLang/Example.jl/git/blobs/b1", project)
            put("repos/JuliaLang/Example.jl/git/blobs/b3", project * "# moved on\n")
            bin = joinpath(dir, "bin")
            mkpath(bin)
            write(joinpath(bin, "gh"), """
                #!/bin/sh
                exec cat "$answers/\$(printf '%s' "\$2" | tr '/?=' '___')"
                """)
            chmod(joinpath(bin, "gh"), 0o755)
            out = joinpath(dir, "audit")
            withenv("PATH" => bin * ":" * ENV["PATH"]) do
                run_script("collect.jl", "[\"Example\"]", out)
            end
            index = TOML.parsefile(joinpath(out, "index.toml"))["packages"]["Example"]
            @test index["version"] == "0.5.5" && index["tree"] == tree
            @test index["repo"] == "JuliaLang/Example.jl" && index["default_branch"] == "master"
            @test read(joinpath(out, "registered", "Example", "Project.toml"), String) == project
            @test endswith(read(joinpath(out, "default", "Example", "Project.toml"), String), "# moved on\n")
        end
    end

    @testset "checkout.sh (local origins)" begin
        mktempdir() do dir
            # two packages, one with a dict-valued index entry each (sorting must not compare them)
            index = Dict("Beta" => Dict("repo" => "org/Beta.jl", "default_branch" => "dev"),
                         "Alpha" => Dict("repo" => "org/Alpha.jl", "default_branch" => "main"))
            for (name, p) in index
                bare = joinpath(dir, "org", "$name.jl.git")
                work = joinpath(dir, "seed-$name")
                run(`git -c init.defaultBranch=$(p["default_branch"]) init --quiet $work`)
                write(joinpath(work, "Project.toml"), "name = \"$name\"\n")
                run(`git -C $work add --all`)
                run(`git -C $work -c user.name=t -c user.email=t@example.org commit --quiet -m init`)
                run(`git clone --quiet --bare $work $bare`)
            end
            audit = joinpath(dir, "audit")
            mkpath(audit)
            open(io -> TOML.print(io, Dict("packages" => index)), joinpath(audit, "index.toml"), "w")
            withenv("COMPAT_PRUNE_GIT_BASE" => "file://$dir") do
                run(`$(joinpath(SCRIPTS, "checkout.sh")) $audit $(joinpath(dir, "checkouts"))`)
            end
            for (name, p) in index
                co = joinpath(dir, "checkouts", name)
                @test read(joinpath(co, "Project.toml"), String) == "name = \"$name\"\n"
                @test readchomp(`git -C $co rev-parse --abbrev-ref HEAD`) == p["default_branch"]
            end
        end
    end

    @testset "simulate" begin
        env = Dict("deps" => Dict("Example" => EXAMPLE), "compat" => Dict("Example" => "=0.5.5"),
                   "pins" => Dict("Example" => "0.5.5"))
        base = simulate("x", env, Dict(), Dict())
        @test base["ok"] && base["versions"]["Example"] == "0.5.5"
        # the pin is checked: =0.5.4 admitted, but the audited version says 0.5.5
        env4 = Dict("deps" => env["deps"], "compat" => Dict("Example" => "=0.5.4"), "pins" => env["pins"])
        r = simulate("x", env4, Dict(), Dict())
        @test !r["ok"] && occursin("pinned versions not selected: Example 0.5.4 (audited 0.5.5)", r["error"])
        # a narrowing that moves a transitive dependency departs from the baseline
        free = Dict("deps" => Dict("Example" => EXAMPLE, "OrderedCollections" => ORDERED), "compat" => Dict(), "pins" => Dict())
        b = simulate("x", free, Dict(), Dict())
        @test b["versions"]["OrderedCollections"] == "2.0.3" || VersionNumber(b["versions"]["OrderedCollections"]) ≥ v"2"
        r = simulate("x", free, Dict("OrderedCollections" => "1"), Dict("OrderedCollections" => ORDERED))
        @test startswith(departure(r, b["versions"]), "manifest differs: OrderedCollections")
        @test departure(simulate("x", free, Dict("OrderedCollections" => "2"), Dict("OrderedCollections" => ORDERED)), b["versions"]) === nothing
    end

    @testset "scripts end to end" begin
        mktempdir() do dir
            root = example_collected(joinpath(dir, "audit"))
            out = run_script("envs.jl", root)
            @test occursin("3 environments: Example/docs, Example/test, joint", out)
            j = join(split(string(VERSION), ".")[1:2], ".")
            base = joinpath(root, "baseline-$j.toml")
            run_script("resolve.jl", root, base)
            b = TOML.parsefile(base)
            @test all(r -> r["ok"], values(b["env"]))
            @test VersionNumber(b["env"]["Example/docs"]["versions"]["OrderedCollections"]) ≥ v"2"

            classified = joinpath(root, "classified.toml")
            out = run_script("classify.jl", root, classified, base)
            @test occursin("prune → 2", out)
            c = TOML.parsefile(classified)
            p = only(c["prune"])
            @test entry_key(p) == ("Example", "docs/Project.toml", "OrderedCollections") && p["after"] == "2"

            # validation accepts it
            empty_rejected = joinpath(root, "rejected.toml")
            write(empty_rejected, "")
            validated = joinpath(root, "validated.toml")
            run_script("validate.jl", root, classified, base, validated, empty_rejected, "--blockers")
            @test isempty(TOML.parsefile(validated)["rejected"])

            # resolve.jl with the prunes: same manifests
            pruned = joinpath(root, "pruned.toml")
            run_script("resolve.jl", root, pruned, classified, base)
            @test TOML.parsefile(pruned)["env"] == b["env"]

            # a prune that moves the manifest is rejected
            c["prune"][1]["after"] = "1"
            bad = joinpath(root, "classified-bad.toml")
            open(io -> TOML.print(io, c), bad, "w")
            run_script("validate.jl", root, bad, base, validated, empty_rejected)
            r = only(TOML.parsefile(validated)["rejected"])
            @test r["where"] == "Example/docs@$j"
            @test occursin("OrderedCollections", r["reason"])

            # edit a checkout, then report
            open(joinpath(root, "audit.toml"), "w") do io
                TOML.print(io, Dict("date" => "2026-10-15 00:00 UTC", "julia" => [j], "prune" => TOML.parsefile(classified)["prune"],
                                    "rejected" => [], "blocked" => [], "other" => [],
                                    "packages" => TOML.parsefile(joinpath(root, "index.toml"))["packages"]))
            end
            checkouts = joinpath(dir, "checkouts")
            cp(joinpath(root, "default"), checkouts)
            out = run_script("edit.jl", root, checkouts)
            @test occursin(r"edited\s+1", out)
            @test occursin("OrderedCollections = \"2\"", read(joinpath(checkouts, "Example", "docs", "Project.toml"), String))
            @test read(joinpath(checkouts, "Example", "Project.toml"), String) ==
                  read(joinpath(root, "default", "Example", "Project.toml"), String)
            # a second run finds it done
            out = run_script("edit.jl", root, checkouts)
            @test occursin(r"already\s+1", out)
            run_script("report.jl", root)
            report = read(joinpath(root, "report.md"), String)
            @test startswith(report, MARKER)
            @test occursin("| merged, awaiting release | 1 |", report)
        end
    end

    @testset "a blocked entry is probed" begin
        mktempdir() do dir
            # newest lane 3 does not exist: never selected, the probe cannot resolve it
            root = example_collected(joinpath(dir, "audit"); docs_compat="1, 2, 3")
            run_script("envs.jl", root)
            j = join(split(string(VERSION), ".")[1:2], ".")
            base = joinpath(root, "baseline-$j.toml")
            run_script("resolve.jl", root, base)
            classified = joinpath(root, "classified.toml")
            run_script("classify.jl", root, classified, base)
            c = TOML.parsefile(classified)
            b = only(filter(r -> r["status"] == "blocked", c["other"]))
            @test b["newest"] == "3" && b["prunable"] == ["1"]
            # its obsolete lane is still a prune
            @test only(c["prune"])["after"] == "2, 3"
            rejected = joinpath(root, "rejected.toml"); write(rejected, "")
            validated = joinpath(root, "validated.toml")
            run_script("validate.jl", root, classified, base, validated, rejected, "--blockers")
            probe = only(TOML.parsefile(validated)["blocked"])
            @test probe["where"] == "Example/docs@$j"
            @test occursin("OrderedCollections", probe["detail"])
        end
    end
end
