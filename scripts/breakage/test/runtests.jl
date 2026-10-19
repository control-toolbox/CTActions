# Tests of the breakage report.
#
# usage: julia scripts/breakage/test/runtests.jl

using Test, TOML

include(joinpath(@__DIR__, "..", "report.jl"))
include(joinpath(@__DIR__, "..", "consumers.jl"))

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
        @test any(contains("C (test) has no result on the base (a new target): not compared"), v.lines)
        @test !any(contains("A (test) has no result"), v.lines)
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

# --- consumers.jl: the downstream packages, derived from the Project.toml files ------------

const UU = Dict(n => "0000000a-bcde-f000-0000-" * lpad(i, 12, '0') for (i, n) in enumerate(
    ["Base", "Mid", "Leaf", "Other", "Twin", "Dead", "Forked"]))

"The text of a Project.toml."
function toml_text(name; uuid=UU[name], deps=(), weakdeps=(), extras=(), version="1.0.0")
    io = IOBuffer()
    println(io, "name = \"$name\"")
    uuid === nothing || println(io, "uuid = \"$uuid\"")
    println(io, "version = \"$version\"")
    for (table, names) in (("deps", deps), ("weakdeps", weakdeps), ("extras", extras))
        isempty(names) && continue
        println(io, "\n[$table]")
        for n in names
            println(io, "$n = \"$(UU[n])\"")
        end
    end
    return String(take!(io))
end

"Run `f` with an organization made of `repos` — `(name, archived, fork)` — and `files` — `(repo, path) => text | Exception`."
function with_org(f, repos, files)
    list, read = LIST[], READ[]
    LIST[] = org -> repos isa Exception ? throw(repos) : repos
    READ[] = function (org, repo, path)
        v = get(files, (repo, path), nothing)
        v isa Exception && throw(v)
        return v
    end
    try
        return f()
    finally
        LIST[], READ[] = list, read
    end
end

"The standard output of `f()`, with its result."
function captured(f)
    mktemp() do path, io
        result = redirect_stdout(f, io)
        flush(io)
        return result, read(path, String)
    end
end

names(ts) = [t.name for t in ts]

@testset "consumers" begin
    @testset "what loads a package" begin
        repos = [("Mid.jl", false, false), ("Leaf.jl", false, false), ("Twin.jl", false, false), ("Other.jl", false, false),
                 ("Dead.jl", true, false), ("Forked.jl", false, true), ("Base.jl", false, false),
                 ("website", false, false), ("Empty.jl", false, false), ("NoUuid.jl", false, false), ("Mirror.jl", false, false)]
        files = Dict(
            ("Base.jl", "Project.toml") => toml_text("Base"; extras=["Base"]),              # lists itself: still not its own consumer
            ("Mid.jl", "Project.toml") => toml_text("Mid"; deps=["Base"]),
            ("Mirror.jl", "Project.toml") => toml_text("Base"; extras=["Base"]),            # the same package, under another name
            ("Leaf.jl", "Project.toml") => toml_text("Leaf"; extras=["Base"]),
            ("Twin.jl", "Project.toml") => toml_text("Twin"; weakdeps=["Base"]),
            ("Other.jl", "Project.toml") => toml_text("Other"),
            ("Other.jl", "test/Project.toml") => "[deps]\nBase = \"$(UU["Base"])\"\n",
            ("Dead.jl", "Project.toml") => toml_text("Dead"; deps=["Base"]),
            ("Forked.jl", "Project.toml") => toml_text("Forked"; deps=["Base"]),
            ("website", "Project.toml") => toml_text("Mid"; deps=["Base"]),
            ("NoUuid.jl", "Project.toml") => toml_text("NoUuid"; uuid=nothing, deps=["Base"]),
        )
        with_org(repos, files) do
            found = consumers("Base", UU["Base"])
            # deps, extras, weakdeps and the test environment count; the package itself, an archived
            # repository, a fork, an excluded one, a non-package and a non-.jl repository do not
            @test names(found) == ["Leaf", "Mid", "Other", "Twin"]
            @test all(t -> t.owner == "control-toolbox" && t.break_ == "test", found)
            @test [t.source for t in found] == ["derived (in the extras of Leaf)", "derived (in the deps of Mid)",
                                                "derived (in the test of Other)", "derived (in the weakdeps of Twin)"]
            # the uuid decides, not the name: nobody loads a package of the same name
            @test isempty(consumers("Base", "11111111-1111-1111-1111-111111111111"))
            @test names(consumers("Base", uppercase(UU["Base"]))) == ["Leaf", "Mid", "Other", "Twin"]
            @test package_of(TOML.parse(toml_text("Base"; uuid=uppercase(UU["Base"])))).uuid == UU["Base"]
            # a package nobody loads has no consumer
            @test isempty(consumers("Leaf", UU["Leaf"]))
        end
        # the excluded repositories are consumers by their Project.toml, and left out
        for excluded in keys(EXCLUDED)
            with_org([("$excluded.jl", false, false)], Dict(("$excluded.jl", "Project.toml") => toml_text("Mid"; deps=["Base"]))) do
                @test isempty(consumers("Base", UU["Base"]))
            end
        end
        @test all(!isempty, values(EXCLUDED))                # each with its reason
    end

    @testset "reading GitHub" begin
        calls = Vector{Vector{String}}()
        api = Ref{Any}((0, "", ""))
        old = API[]
        API[] = (args...) -> (push!(calls, collect(String, args)); api[])
        try
            api[] = (0, "A.jl\tfalse\tfalse\nB.jl\ttrue\tfalse\nC.jl\tfalse\ttrue\n", "")
            @test list_repos("org") == [("A.jl", false, false), ("B.jl", true, false), ("C.jl", false, true)]
            @test "--paginate" in calls[end] && any(contains("orgs/org/repos"), calls[end])
            api[] = (1, "", "HTTP 403: rate limit")
            @test_throws ErrorException list_repos("org")
            api[] = (0, "name = \"x\"\n", "")
            @test read_file("org", "A.jl", "Project.toml") == "name = \"x\"\n"
            @test any(contains("repos/org/A.jl/contents/Project.toml"), calls[end])
            api[] = (1, "", "gh: Not Found (HTTP 404)")
            @test read_file("org", "A.jl", "test/Project.toml") === nothing      # no such file: not an error
            api[] = (1, "", "gh: Bad Gateway (HTTP 502)")
            @test_throws ErrorException read_file("org", "A.jl", "Project.toml")  # anything else is
        finally
            API[] = old
        end
    end

    @testset "errors are not empty lists" begin
        @test_throws ErrorException with_org(() -> consumers("Base", UU["Base"]), ErrorException("cannot list"), Dict())
        files = Dict(("Mid.jl", "Project.toml") => ErrorException("cannot read Project.toml of x/Mid.jl: HTTP 502"))
        @test_throws ErrorException with_org(() -> consumers("Base", UU["Base"]), [("Mid.jl", false, false)], files)
        # a Project.toml that cannot be parsed is skipped, with a warning
        files = Dict(("Mid.jl", "Project.toml") => "name = ", ("Leaf.jl", "Project.toml") => toml_text("Leaf"; deps=["Base"]))
        with_org([("Mid.jl", false, false), ("Leaf.jl", false, false)], files) do
            found = @test_logs (:warn, r"cannot parse Mid.jl/Project.toml") consumers("Base", UU["Base"])
            @test names(found) == ["Leaf"]
        end
        # a repository name that is not a name
        with_org([("a b.jl", false, false)], Dict()) do
            @test_throws ErrorException consumers("Base", UU["Base"])
        end
    end

    @testset "declared targets" begin
        t = parse_targets("""[{"name": "A"}, {"name": "B", "owner": "me", "break": "doc"}]""")
        @test [(x.name, x.owner, x.break_, x.source) for x in t] ==
              [("A", "control-toolbox", "test", "declared"), ("B", "me", "doc", "declared")]
        @test parse_targets("") == [] && parse_targets("[]") == [] && parse_targets("  [ ]  ") == []
        @test parse_targets("""[{"name":"A"},{"name":"B"}]""") |> length == 2
        for bad in ("""{"name": "A"}""", """["A"]""", """[{"name": "A"}] x""", """[{"owner": "me"}]""",
                    """[{"name": "A", "color": "red"}]""", """[{"name": "A", "break": "docs"}]""",
                    """[{"name": "A B"}]""", """[{"name": "../x"}]""", """[{"name": "A", "owner": "a;b"}]""",
                    """[{"name": 3}]""", """[{"name": "A", "break": null}]""", """[{"name": "A"} {"name": "B"}""")
            @test_throws ArgumentError parse_targets(bad)
        end
    end

    @testset "plan" begin
        repos = [("Mid.jl", false, false), ("Leaf.jl", false, false)]
        files = Dict(("Mid.jl", "Project.toml") => toml_text("Mid"; deps=["Base"]), ("Leaf.jl", "Project.toml") => toml_text("Leaf"; deps=["Base"]))
        with_org(repos, files) do
            @test names(plan("Base", UU["Base"])) == ["Leaf", "Mid"]
            # a declared target is added; a doc check of a derived package is a target of its own
            decl = parse_targets("""[{"name": "App", "owner": "me", "break": "doc"}, {"name": "Mid", "break": "doc"}]""")
            p = plan("Base", UU["Base"]; declared=decl)
            @test [(t.name, t.break_) for t in p] == [("App", "doc"), ("Leaf", "test"), ("Mid", "doc"), ("Mid", "test")]
            # a declared target replaces the derived one of the same package, owner and check
            p = plan("Base", UU["Base"]; declared=parse_targets("""[{"name": "Mid"}]"""))
            @test [(t.name, t.source) for t in p] == [("Leaf", "derived (in the deps of Leaf)"), ("Mid", "declared")]
            # without derivation, the declared targets only
            p = plan("Base", UU["Base"]; declared=decl, derive=false)
            @test [(t.name, t.break_) for t in p] == [("App", "doc"), ("Mid", "doc")]
            # nothing to test is an error, not an empty matrix
            @test_throws ErrorException plan("Leaf", UU["Leaf"])
            @test_throws ErrorException plan("Base", UU["Base"]; derive=false)
        end
        t = parse_targets("""[{"name": "A"}, {"name": "B", "owner": "me", "break": "doc"}]""")
        @test json_targets(t) == """[{"name":"A","owner":"control-toolbox","break":"test"},{"name":"B","owner":"me","break":"doc"}]"""
        table = targets_table("Base", t)
        @test contains(table, "| A | test | control-toolbox | declared |") && contains(table, "| B | doc | me | declared |")
    end

    @testset "command line" begin
        mktempdir() do d
            proj = joinpath(d, "Project.toml"); write(proj, toml_text("Base"))
            summary_file = joinpath(d, "summary.md")
            with_org(ErrorException("the organization must not be read"), Dict()) do
              redirect_stderr(devnull) do
                @test consumers_main(String[]) == 2
                @test consumers_main(["nope"]) == 2
                @test consumers_main(["list"]) == 2                                       # --project is required
                @test consumers_main(["list", "--project", proj, "extra"]) == 2
                @test consumers_main(["plan", "--project", proj, "--declared", "{"]) == 2
                write(joinpath(d, "NoPkg.toml"), "x = 1\n")
                @test consumers_main(["list", "--project", joinpath(d, "NoPkg.toml")]) == 2
                @test consumers_main(["plan", "--project", proj, "--no-derive"]) == 1        # nothing to test
              end
              code, out = captured() do
                  consumers_main(["plan", "--project", proj, "--no-derive", "--declared", """[{"name": "App", "owner": "me", "break": "doc"}]""",
                                  "--summary", summary_file])
              end
              @test code == 0 && out == """[{"name":"App","owner":"me","break":"doc"}]\n"""
              @test contains(read(summary_file, String), "| App | doc | me | declared |")
            end
            # derived through the (faked) organization
            files = Dict(("Mid.jl", "Project.toml") => toml_text("Mid"; deps=["Base"]))
            with_org([("Mid.jl", false, false)], files) do
                code, out = captured(() -> consumers_main(["list", "--project", proj]))
                @test code == 0 && out == """[{"name":"Mid","owner":"control-toolbox","break":"test"}]\n"""
                code, out = captured(() -> consumers_main(["plan", "--project", proj, "--declared", """[{"name": "App"}]"""]))
                @test code == 0 && out == """[{"name":"App","owner":"control-toolbox","break":"test"},{"name":"Mid","owner":"control-toolbox","break":"test"}]\n"""
            end
            # a failure to read the organization is an error, not an empty list
            redirect_stderr(devnull) do
                with_org(ErrorException("HTTP 500"), Dict()) do
                    @test consumers_main(["list", "--project", proj]) == 1
                end
            end
        end
    end

    @testset "the ecosystem, as read on 2026-10-19" begin
        # name => (deps, weakdeps, extras, test deps), as in the Project.toml files then
        eco = Dict(
            "CTBase" => ((), (), (), ()),
            "CTModels" => (("CTBase",), (), (), ()),
            "CTSolvers" => (("CTBase", "CTModels"), (), (), ()),
            "CTFlows" => (("CTBase", "CTModels", "CTSolvers"), (), ("CTLie",), ()),
            "CTDirect" => (("CTBase", "CTModels", "CTParser", "CTSolvers"), (), ("CTParser",), ()),
            "CTParser" => (("CTBase",), (), (), ("CTBase", "CTModels")),
            "CTLie" => (("CTBase",), (), (), ()),
            "OptimalControl" => (("CTBase", "CTDirect", "CTFlows", "CTLie", "CTModels", "CTParser", "CTSolvers"), (), (), ()),
            "OptimalControlProblems" => (("CTBase", "CTDirect", "CTModels"), ("OptimalControl",), (), ("CTBase", "CTDirect", "OptimalControl")),
            "CTBenchmarks" => (("CTBase", "OptimalControl", "OptimalControlProblems"), (), (), ()),
            "CTDirectShooting" => (("CTBase", "CTFlows"), (), (), ("CTBase",)),         # archived
        )
        id(n) = "00000000-0000-0000-0001-" * lpad(findfirst(==(n), sort!(collect(keys(eco)))), 12, '0')
        files = Dict{Tuple{String,String},Any}()
        for (n, (deps, weak, extras, test)) in eco
            tbl(names) = isempty(names) ? "" : join(("$x = \"$(id(x))\"" for x in names), "\n") * "\n"
            text = "name = \"$n\"\nuuid = \"$(id(n))\"\n[deps]\n$(tbl(deps))[weakdeps]\n$(tbl(weak))[extras]\n$(tbl(extras))"
            files[("$n.jl", "Project.toml")] = text
            isempty(test) || (files[("$n.jl", "test/Project.toml")] = "[deps]\n$(tbl(test))")
        end
        expected = Dict(
            "CTBase" => ["CTDirect", "CTFlows", "CTLie", "CTModels", "CTParser", "CTSolvers", "OptimalControl", "OptimalControlProblems"],
            "CTModels" => ["CTDirect", "CTFlows", "CTParser", "CTSolvers", "OptimalControl", "OptimalControlProblems"],
            "CTSolvers" => ["CTDirect", "CTFlows", "OptimalControl"],
            "CTFlows" => ["OptimalControl"],                       # CTDirectShooting is archived
            "CTDirect" => ["OptimalControl", "OptimalControlProblems"],
            "CTParser" => ["CTDirect", "OptimalControl"],
            "CTLie" => ["CTFlows", "OptimalControl"],
            "OptimalControl" => ["OptimalControlProblems"],        # CTBenchmarks is excluded
        )
        with_org([("$n.jl", n == "CTDirectShooting", false) for n in keys(eco)], files) do
            for (pkg, want) in expected
                @test names(consumers(pkg, id(pkg))) == want
            end
        end
    end
end

