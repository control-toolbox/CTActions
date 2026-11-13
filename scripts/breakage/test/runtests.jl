# Tests of the breakage report.
#
# usage: julia scripts/breakage/test/runtests.jl

using Test, TOML

include(joinpath(@__DIR__, "..", "report.jl"))
include(joinpath(@__DIR__, "..", "consumers.jl"))
include(joinpath(@__DIR__, "..", "cell.jl"))
include(joinpath(@__DIR__, "..", "pr.jl"))

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
        # nothing to test: no cell, an empty baseline; nothing is broken
        v = verdict([], []; expected=0, base_version=V0, head_version=V1)
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
        # nothing to test: no cell; the empty breakage.toml on main is the baseline of a release
        mktempdir() do d
            empty = joinpath(d, "cells"); mkpath(empty)
            redirect_stdout(devnull) do
                @test report_main([empty, joinpath(d, "main"), "--expected", "0"]) == 0
                @test report_main([empty, joinpath(d, "pr"), "--expected", "0", "--baseline", joinpath(d, "main", "breakage.toml"),
                                   "--base-version", "0.30.11", "--head-version", "0.30.12"]) == 0
            end
            @test !haskey(TOML.parsefile(joinpath(d, "main", "breakage.toml")), "cell") ||
                  isempty(TOML.parsefile(joinpath(d, "main", "breakage.toml"))["cell"])
            text = read(joinpath(d, "pr", "summary.md"), String)
            @test contains(text, "No downstream package to test: nothing to do") && !contains(text, "| Package |")
            @test contains(text, "no downstream release broken")
        end
    end

    @testset "--base-sha reads the two versions" begin
        mktempdir() do d
            git(args...) = run(pipeline(`git -C $d $args`; stdout=devnull, stderr=devnull))
            git("init", "-q"); git("config", "user.email", "t@t"); git("config", "user.name", "t")
            write(joinpath(d, "Project.toml"), "name = \"P\"\nversion = \"0.30.11\"\n"); git("add", "."); git("commit", "-qm", "base")
            sha = strip(read(`git -C $d rev-parse HEAD`, String))
            write(joinpath(d, "Project.toml"), "name = \"P\"\nversion = \"0.31.0\"\n")
            cd(d) do
                @test versions_at(sha) == ("0.30.11", "0.31.0")
                mkpath("cells")
                redirect_stdout(devnull) do
                    # a release without baseline: blocked, so the versions were read
                    @test report_main(["cells", "out", "--expected", "0", "--base-sha", sha]) == 1
                    @test report_main(["cells", "out2", "--expected", "0", "--base-sha", ""]) == 0   # not a PR
                end
            end
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
        old = GH_RUN[]
        GH_RUN[] = args -> (push!(calls, args); api[])
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
            GH_RUN[] = old
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
            # nothing to test: no target, not an error; the suite then runs no cell and passes
            @test isempty(plan("Leaf", UU["Leaf"]))
            @test isempty(plan("Base", UU["Base"]; derive=false))
            @test json_targets(plan("Leaf", UU["Leaf"])) == "[]"
            @test contains(targets_table("Leaf", Target[]), "nothing to do")
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

              end
              code, out = captured() do
                  consumers_main(["plan", "--project", proj, "--no-derive", "--declared", """[{"name": "App", "owner": "me", "break": "doc"}]""",
                                  "--summary", summary_file])
              end
              @test code == 0 && out == """[{"name":"App","owner":"me","break":"doc"}]\n"""
              @test contains(read(summary_file, String), "| App | doc | me | declared |")
              # nothing to test: an empty list and success, the summary says so
              code, out = captured(() -> consumers_main(["plan", "--project", proj, "--no-derive", "--summary", summary_file]))
              @test code == 0 && out == "[]\n"
              @test contains(read(summary_file, String), "No downstream package to test: nothing to do")
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

# --- cell.jl: one downstream package at one version -----------------------------------------

"Run `f` with commands answered by `answer(cmd_text, dir)` → `(ok, stdout)`; the commands go to `calls`."
function with_commands(f, answer)
    calls = String[]
    real = RUN[]
    RUN[] = function (cmd)
        text = join(cmd.exec, " ")
        push!(calls, text)
        return answer(text, cmd.dir)
    end
    try
        f(calls)
    finally
        RUN[] = real
    end
end

@testset "cell" begin
    @testset "pick_ref" begin
        @test pick_ref("latest", "main", ["v2", "v1"]) == "main"
        @test pick_ref("stable", "main", ["v2", "v1"]) == "v2"
        @test pick_ref("stable", "main", String[]) === nothing
        @test pick_ref("v1.2.3", "main", String[]) == "v1.2.3"
    end

    @testset "program" begin
        @test occursin("Pkg.test()", program("test")) && occursin("Pkg.activate(\".\")", program("test"))
        @test occursin("docs/make.jl", program("doc")) && occursin("Pkg.activate(\"docs\")", program("doc"))
        @test_throws ErrorException program("bench")
    end

    "A world where the clone works, the tags are `tags`, a checkout works, the test answers `test_ok`."
    world(; clone=true, tags="v2.0.0\nv1.0.0\n", checkout=true, test_ok=true) = function (text, dir)
        startswith(text, "git clone") && return (clone, "")
        occursin("rev-parse", text) && return (true, "main\n")
        occursin("tag -l", text) && return (true, tags)
        occursin("checkout", text) && return (checkout, "")
        occursin("fetch", text) && return (true, "")
        (occursin("Pkg.test()", text) || occursin("docs/make.jl", text)) && return (test_ok, "")
        occursin("Pkg.dependencies", text) && return (true, "v0.30.11")
        return (false, "")
    end

    mktempdir() do d
        out = joinpath(d, "cells")
        src = joinpath(d, "CTBase.jl"); mkpath(src)
        kw = (name="A", owner="o", source=src, out=out, job="https://x/run")
        redirect_stdout(devnull) do
            with_commands(world()) do calls
                path = run_cell(; kw..., brk="test", version="stable")
                c = TOML.parsefile(path)
                @test basename(path) == "A-test-stable.toml"
                @test c == Dict("name" => "A", "owner" => "o", "break" => "test", "version" => "stable", "tag" => "v2.0.0",
                                "compat" => "v0.30.11", "status" => "pass", "job" => "https://x/run")
                @test any(contains("git clone --quiet https://github.com/o/A.jl"), calls)
                @test any(contains("checkout --quiet v2.0.0"), calls)
            end
            with_commands(world(test_ok=false)) do calls
                c = TOML.parsefile(run_cell(; kw..., brk="doc", version="latest"))
                @test c["status"] == "fail" && c["tag"] == "main" && c["break"] == "doc"
                @test !any(contains("checkout"), calls)                     # latest: the clone's branch
                @test any(contains("--project=docs"), calls)
            end
            with_commands(world(tags="")) do calls
                c = TOML.parsefile(run_cell(; kw..., brk="test", version="stable"))
                @test c["status"] == "no_tag" && c["tag"] == "none" && c["compat"] == ""
                @test !any(contains("Pkg.test()"), calls)
            end
            with_commands(world(checkout=false)) do _
                c = TOML.parsefile(run_cell(; kw..., brk="test", version="v9.9.9"))
                @test c["status"] == "no_tag"                               # a ref that does not exist
            end
            with_commands(world(clone=false)) do _
                @test run_cell(; kw..., brk="test", version="latest") === nothing
            end
        end
        @test cell_main(["--name", "A"]) == 2
        @test cell_main(["--name", "A", "--owner", "o", "--break", "bench", "--version", "latest", "--source", src, "--out", out]) == 2
    end

    @testset "SRC_NAME is the directory without .jl" begin
        seen = Ref{Any}(nothing)
        mktempdir() do d
            src = joinpath(d, "CTBase.jl"); mkpath(src)
            RUN_real = RUN[]
            RUN[] = function (cmd)
                text = join(cmd.exec, " ")
                startswith(text, "git clone") && return (true, "")
                occursin("rev-parse", text) && return (true, "main")
                cmd.env === nothing || seen[] !== nothing || (seen[] = filter(e -> startswith(e, "SRC_NAME=") || startswith(e, "SOURCE="), cmd.env))
                return (true, "")
            end
            try
                redirect_stdout(devnull) do
                    run_cell(; name="A", owner="o", brk="test", version="latest", source=src * "/", out=joinpath(d, "c"))
                end
            finally
                RUN[] = RUN_real
            end
            @test "SRC_NAME=CTBase" in seen[]
            @test "SOURCE=$src" in seen[]
        end
    end
end

# --- pr.jl: the pull request, the baseline, the comment -------------------------------------

"Run `f` with `gh` answered by `table` (substring of the arguments => output | nothing); the calls go to `calls`."
function with_gh_table(f, table)
    calls = Vector{Vector{String}}()
    real = GH[]
    GH[] = function (args)
        push!(calls, args)
        line = join(args, " ")
        for (needle, out) in table
            occursin(needle, line) && return out
        end
        return nothing
    end
    try
        f(calls)
    finally
        GH[] = real
    end
end

@testset "pr" begin
    with_gh_table(["pulls/7" => "abc false\n"]) do _
        @test pr_facts("o/r", "7") == ("abc", false)
    end
    with_gh_table(["pulls/7" => "abc true\n"]) do _
        @test pr_facts("o/r", "7") == ("abc", true)
    end

    @testset "baseline: the run outside a pull request, or none" begin
        with_gh_table(["actions/workflows/Breakage.yml/runs" => "42\n", "run download" => ""]) do calls
            @test baseline_run("o/r", "Breakage.yml", "abc") == "42"
            @test occursin("head_sha=abc&status=completed", join(calls[end], " "))
            @test occursin("select(.event != \"pull_request\")", join(calls[end], " "))
            @test redirect_stdout(() -> download_baseline("o/r", "Breakage.yml", "abc", "packages", "b"), devnull)
            @test calls[end] == ["run", "download", "42", "--repo", "o/r", "--name", "breakage-packages", "--dir", "b"]
        end
        with_gh_table(["actions/workflows" => "\n"]) do _
            @test baseline_run("o/r", "Breakage.yml", "abc") === nothing
            @test !redirect_stdout(() -> download_baseline("o/r", "Breakage.yml", "abc", "packages", "b"), devnull)
        end
        with_gh_table(["actions/workflows" => "42\n"]) do _                    # the artifact is gone
            @test !redirect_stdout(() -> download_baseline("o/r", "Breakage.yml", "abc", "packages", "b"), devnull)
        end
    end

    @testset "comment: updated when the group has one, created otherwise" begin
        with_gh_table(["issues/7/comments --jq" => "11\n12\n", "--method PATCH" => "{}"]) do calls
            @test upsert_comment("o/r", "7", "packages", "body") == :updated
            @test calls[end] == ["api", "--method", "PATCH", "repos/o/r/issues/comments/11", "-f", "body=body"]
            @test occursin("startswith(\"<!-- ct-breakage:packages -->\")", join(calls[1], " "))
        end
        with_gh_table(["issues/7/comments --jq" => "", "--method POST" => "{}"]) do calls
            @test upsert_comment("o/r", "7", "packages", "body") == :created
            @test calls[end] == ["api", "--method", "POST", "repos/o/r/issues/7/comments", "-f", "body=body"]
        end
    end

    @testset "command line" begin
        @test pr_main(String[]) == 2
        @test pr_main(["nope"]) == 2
        @test pr_main(["facts", "--repo", "o/r"]) == 2
        with_gh_table(["pulls/7" => "abc false\n"]) do _
            code, out = captured(() -> pr_main(["facts", "--repo", "o/r", "--pr", "7"]))
            @test code == 0 && out == "base_sha=abc\nfork=false\n"
        end
        with_gh_table(Pair{String,Any}[]) do _
            @test redirect_stderr(() -> pr_main(["facts", "--repo", "o/r", "--pr", "7"]), devnull) == 1
        end
    end
end
