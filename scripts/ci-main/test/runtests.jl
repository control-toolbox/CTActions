# Tests of the changes-only decision (scripts/ci-main/changes.jl).
#
# usage: julia scripts/ci-main/test/runtests.jl
#
# `gh` (`GH`) and `git` (`GIT`) are replaced by functions, so nothing goes to the network:
# the pull request, its commits and files, the label events and the earlier runs are
# described by a table; the diff comes from a throwaway git repository.

using Test

include(joinpath(@__DIR__, "..", "changes.jl"))

const SHA = repeat("c", 40)
const BASE = repeat("b", 40)

"Answers `gh` from a table of (substring of the arguments => output); anything else fails."
function with_gh(f, table)
    real = GH[]
    GH[] = function (args)
        line = join(args, " ")
        for (needle, out) in table
            occursin(needle, line) && return out
        end
        return nothing
    end
    try
        return f()
    finally
        GH[] = real
    end
end

"A repository with a commit `BASE`-like and a following one touching `files`; returns (dir, base, head)."
function repo_with(files)
    dir = mktempdir()
    run(`git -C $dir init -q -b main`)
    run(`git -C $dir config user.email t@t`); run(`git -C $dir config user.name t`)
    write(joinpath(dir, "Project.toml"), "name = \"X\"\n")
    run(`git -C $dir add -A`); run(`git -C $dir commit -q -m base`)
    base = strip(read(`git -C $dir rev-parse HEAD`, String))
    for f in files
        mkpath(dirname(joinpath(dir, f))); write(joinpath(dir, f), "x$(rand())\n")
    end
    run(`git -C $dir add -A`); run(`git -C $dir commit -q -m change`)
    head = strip(read(`git -C $dir rev-parse HEAD`, String))
    return dir, base, head
end

pr_line(labels; head="docs/something", number=7) = "$number\t$head\t$(join(labels, ","))\n"
runs_line(base) = "11\t$base\n12\t$(repeat("d", 40))\n"
green_jobs = "call / test (1.10, ubuntu-latest)\tsuccess\ncall / test (1.12, ubuntu-latest)\tsuccess\n"

function table(; labels=[LABEL], head="docs/x", actor="ocots", commits="", files="", base=BASE, jobs=green_jobs)
    return [
        "commits/" => pr_line(labels; head),
        "issues/7/events" => actor === nothing ? "" : "$actor\n",
        "pulls/7/commits" => commits,
        "pulls/7/files" => files,
        "workflows/CI.yml/runs" => base === nothing ? "" : runs_line(base),
        "actions/runs/11/jobs" => jobs,
        "actions/runs/12/jobs" => "call / test (1.10, ubuntu-latest)\tfailure\n",
    ]
end

@testset "relevant" begin
    @test relevant("tests", "src/A.jl")
    @test relevant("tests", "test/suite/a.jl")
    @test !relevant("tests", "docs/src/index.md")
    @test relevant("docs", "docs/make.jl")
    @test relevant("docs", "src/A.jl")            # docstrings
    @test !relevant("docs", "test/runtests.jl")
    @test relevant("breakage", "ext/E.jl")
    @test !relevant("breakage", "test/a.jl")
    @test !relevant("breakage", "docs/make.jl")
    for s in keys(SCOPES)
        @test relevant(s, "Project.toml")
        @test !relevant(s, "CHANGELOG.md")
        @test !relevant(s, "AGENTS.md")
        @test !relevant(s, ".gitignore")
        @test relevant(s, ".github/workflows/CI.yml")   # unknown: run
        @test relevant(s, "newdir/file.jl")
    end
end

@testset "job_of" begin
    @test job_of("call / test (1.10, ubuntu-latest, x64)", "test")
    @test job_of("test", "test")
    @test !job_of("call / test-gpu (1)", "test")
    @test !job_of("call / retest", "test")
end

@testset "decide" begin
    dir, base, head = repo_with(["docs/src/a.md"])
    d(tbl; kw...) = with_gh(() -> decide("o/r", head; scope="tests", workflow="CI.yml", job="test", dir, kw...), tbl)

    @testset "everything runs unless asked" begin
        @test d(table(); event="pull_request").run
        @test d(table(); ref="refs/tags/v1").run
        @test d(table(labels=String["x"], base=base)).run                 # no label
        @test occursin("no label", d(table(labels=String["x"], base=base)).reason)
        @test d(table(head="release/v1.0.0", base=base)).run              # release PR
        @test occursin("release", d(table(head="release/v1.0.0", base=base)).reason)
        @test d(table(actor="someone", base=base)).run                    # wrong actor
        @test occursin("may not", d(table(actor="someone", base=base)).reason)
        @test d(table(actor=nothing, base=base)).run
        @test d([("nothing", "")]).run                                     # no PR found
        @test d(table(base=nothing)).run                                   # no green run
    end

    @testset "changes only" begin
        r = d(table(base=base))                       # docs/ changed, scope tests
        @test !r.run
        r = with_gh(() -> decide("o/r", head; scope="docs", workflow="CI.yml", job="test", dir), table(base=base))
        @test r.run
        @test occursin("docs/src/a.md", r.reason)
    end

    @testset "the base is a run where the job really passed" begin
        @test d(table(base=base, jobs="call / test (1.10)\tskipped\n")).run     # skipped run: not a base
        @test d(table(base=base, jobs="call / test (1.10)\tfailure\n")).run     # failed run
        @test d(table(base=base, jobs="call / other\tsuccess\n")).run           # the job did not run there
        @test !d(table(base=base, jobs="call / test (1.10)\tsuccess\ncall / test (1.12)\tskipped\n")).run
    end

    @testset "the base must be an ancestor" begin
        @test d(table(base=repeat("a", 40))).run
    end

    @testset "formatting only" begin
        fmt = table(commits="Format .jl files\nFormat .jl files\n", files="src/A.jl\next/E.jl\n")
        @test !with_gh(() -> decide("o/r", head; scope="tests", workflow="CI.yml", job="test", dir), fmt).run
        for (c, f) in (("Format .jl files\nfix bug\n", "src/A.jl\n"),      # another commit
                       ("Format .jl files\n", "src/A.jl\nREADME.md\n"),     # not only .jl
                       ("", "src/A.jl\n"))
            t = table(commits=c, files=f)
            @test with_gh(() -> decide("o/r", head; scope="tests", workflow="CI.yml", job="test", dir), t).run
        end
        # the label and the actor still count
        @test with_gh(() -> decide("o/r", head; scope="tests", workflow="CI.yml", job="test", dir),
                      table(labels=String[], commits="Format .jl files\n", files="src/A.jl\n")).run
        @test with_gh(() -> decide("o/r", head; scope="tests", workflow="CI.yml", job="test", dir),
                      table(actor="someone", commits="Format .jl files\n", files="src/A.jl\n")).run
    end

    @testset "the baseline run is reported" begin
        @test d(table(base=base)).base_run == "11"
        @test d(table(commits="Format .jl files\n", files="src/A.jl\n", base=base)).base_run == "11"
        @test d(table(labels=String[], base=base)).base_run == ""
        # formatting only, but nothing to start from: run
        @test d(table(commits="Format .jl files\n", files="src/A.jl\n", base=nothing)).run
    end

    @testset "a change that matters" begin
        dir2, base2, head2 = repo_with(["src/A.jl"])
        r = with_gh(() -> decide("o/r", head2; scope="tests", workflow="CI.yml", job="test", dir=dir2), table(base=base2))
        @test r.run
    end
end

@testset "command line" begin
    @test main(String[]) == 2
    @test main(["--repo", "o/r", "--sha", SHA, "--scope", "nope", "--workflow", "CI.yml", "--job", "test"]) == 2
end
