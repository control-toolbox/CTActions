# Tests of the release tool.
#
# usage: julia scripts/release/test/runtests.jl
#
# Unit tests run on fixtures, fakes and throwaway git repositories: the registries
# (`FETCH`) and `gh` (`GH`) are replaced by functions, so nothing goes to the network.
# Integration tests resolve the fixtures against the local General registry (nothing
# downloaded; seconds) and run the tool as a command; they are skipped when General is not
# installed. The fixtures depend on Example 0.5 (General has 0.5.5) and OrderedCollections 1
# and 2: a bound of 9 or more is satisfied by no version in General, which is what a
# beta-only bound looks like.

using Test, TOML

include(joinpath(@__DIR__, "..", "release.jl"))

const FIXTURES = joinpath(@__DIR__, "fixtures")
const SCRIPT = joinpath(@__DIR__, "..", "release.jl")
const EXAMPLE = "7876af07-990d-54b4-ab0e-23690620f79a"
const ORDERED = "bac558e1-5e72-5ebc-8fee-abe8a469f55d"
const PKG_UUID = "00000000-0000-0000-0000-0000000000aa"

"A registry stand-in: a name and the registered versions of each uuid."
struct FakeRegistry
    name::String
    versions::Dict{String,Vector{VersionNumber}}
end

registered_versions(r::FakeRegistry, uuid::AbstractString) = get(r.versions, uuid, VersionNumber[])

fixture(name) = TOML.parsefile(joinpath(FIXTURES, name))

"Run the tool as a command; return its exit code and standard output."
function command(args...)
    out = IOBuffer()
    p = run(pipeline(ignorestatus(`$(Base.julia_cmd()) --startup-file=no $SCRIPT $args`); stdout=out, stderr=devnull))
    return p.exitcode, String(take!(out))
end

"Run `f` with the registries replaced by `versions` (registry => name => [version strings])."
function with_registries(f, versions)
    real = FETCH[]
    FETCH[] = function (url)
        for (reg, pkgs) in versions, (name, vs) in pkgs
            url == "$(REGISTRY_URLS[reg])/$(uppercase(name[1]))/$name/Versions.toml" || continue
            return join(("[\"$v\"]\ngit-tree-sha1 = \"$(repeat('0', 40))\"\n" for v in vs), "\n")
        end
        return nothing
    end
    try
        return f()
    finally
        FETCH[] = real
    end
end

"Run `f` with `gh` replaced by `fake` (a function of the argument vector)."
function with_gh(f, fake)
    real = GH[]
    GH[] = fake
    try
        return f()
    finally
        GH[] = real
    end
end

sh(dir, cmd) = run(pipeline(Cmd(`sh -c $cmd`; dir), stdout=devnull, stderr=devnull))

"A changelog with an empty `[Unreleased]` and `entries` (version => body), newest first."
changelog(entries...) = "# Changelog\n\n## [Unreleased]\n\n" *
    join(("## [$v] - 2026-10-18\n\n$body\n\n### ✅ Compatibility\n\n- ok.\n\n" for (v, body) in entries))

"""
A throwaway package repository: `Pkg` 0.4.2 tagged, then `after` (a shell command: the
changes since the release), merged on `main`; then a release branch that sets `version`
with `entries` in the changelog and a BREAKING note. Returns the directory and the base.
"""
function package_repo(; version="0.4.3", after="mkdir -p src && echo '# fix' >> src/Pkg.jl",
                      entries=(version => "### 🐛 Bug Fixes\n\n- a fix.",), breaking_md="## Non-breaking note ($version)\n\n- none.\n",
                      extra="", workflows=true)
    dir = mktempdir()
    project(v) = "name = \"Pkg\"\nuuid = \"$PKG_UUID\"\nversion = \"$v\"\n\n[deps]\nExample = \"$EXAMPLE\"\n\n[compat]\nExample = \"0.5\"\n"
    write(joinpath(dir, "Project.toml"), project("0.4.2"))
    write(joinpath(dir, "CHANGELOG.md"), changelog("0.4.2" => "### 🐛 Bug Fixes\n\n- first."))
    write(joinpath(dir, "BREAKING.md"), "# Breaking\n\n## Non-breaking note (0.4.2)\n\n- none.\n")
    mkpath(joinpath(dir, "src")); write(joinpath(dir, "src", "Pkg.jl"), "module Pkg end\n")
    if workflows
        mkpath(joinpath(dir, ".github", "workflows"))
        write(joinpath(dir, ".github", "workflows", "CI.yml"),
              "if: contains(github.event.pull_request.labels.*.name, 'run ci github-runner')\n")
    end
    sh(dir, "git init -q -b main && git -c user.name=t -c user.email=t@t add -A && git -c user.name=t -c user.email=t@t commit -qm init && git tag v0.4.2")
    isempty(after) || sh(dir, "$after && git add -A && git -c user.name=t -c user.email=t@t commit -qm change")
    base = strip(read(Cmd(`git rev-parse HEAD`; dir), String))
    sh(dir, "git checkout -q -b release/v$version")
    write(joinpath(dir, "Project.toml"), project(version))
    old = read(joinpath(dir, "CHANGELOG.md"), String)
    write(joinpath(dir, "CHANGELOG.md"), changelog(entries...) * split(old, "## [Unreleased]\n\n")[2])
    b = read(joinpath(dir, "BREAKING.md"), String)
    write(joinpath(dir, "BREAKING.md"), replace(b, "# Breaking\n\n" => "# Breaking\n\n$breaking_md\n"))
    isempty(extra) || sh(dir, extra)
    sh(dir, "git add -A && git -c user.name=t -c user.email=t@t commit -qm release")
    return dir, base
end

failures(results) = [r.message for r in results if r.status === :fail]

@testset "release" begin
    @testset "versions" begin
        r(xs...) = VersionNumber.(collect(xs))
        @test is_breaking(v"0.30.11", v"0.31.0") && !is_breaking(v"0.30.11", v"0.30.12")
        @test is_breaking(v"1.2.3", v"2.0.0") && !is_breaking(v"1.2.3", v"1.3.0")
        @test is_breaking(v"0.0.3", v"0.0.4")
        @test allowed_suffix(v"1.0.0") && allowed_suffix(v"1.0.0-beta")
        @test !allowed_suffix(v"1.0.0-rc") && !allowed_suffix(v"1.0.0-beta.2")
        # the table of REL2
        @test expected_version(:beta, r("0.4.2"); breaking=false, feature=false) == v"0.4.3-beta"
        @test expected_version(:stable, r("0.4.2", "0.4.3-beta"); breaking=false, feature=false) == v"0.4.4"
        @test expected_version(:beta, r("0.4.2"); breaking=true, feature=false) == v"0.5.0-beta"
        @test expected_version(:stable, r("0.4.2", "0.5.0-beta", "0.5.1-beta"); breaking=true, feature=false) == v"0.5.2"
        # REL1: a feature bumps the minor from 1.0 on, the patch before
        @test expected_version(:stable, r("1.2.0"); breaking=false, feature=true) == v"1.3.0"
        @test expected_version(:stable, r("0.4.2"); breaking=false, feature=true) == v"0.4.3"
        # no number fits a non-breaking stable after breaking betas
        @test expected_version(:stable, r("0.4.2", "0.5.0-beta"); breaking=false, feature=false) === nothing
        # first releases
        @test expected_version(:stable, VersionNumber[]; breaking=false, feature=false) == v"0.1.0"
        @test expected_version(:stable, r("0.1.0-beta"); breaking=false, feature=false) == v"0.1.1"
        # REL3
        @test jump(v"0.30.11", v"0.30.12", VersionNumber[]) === :none
        @test jump(v"0.30.11", v"1.0.0", VersionNumber[]) === :none
        @test jump(v"0.30.11", v"0.30.13", r("0.30.12-beta")) === :betas
        @test jump(v"0.4.2", v"0.5.2", r("0.5.0-beta", "0.5.1-beta")) === :betas
        @test jump(v"0.4.2", v"0.6.0", VersionNumber[]) === :unexplained
        @test jump(nothing, v"0.1.0", VersionNumber[]) === :none
        with_registries(Dict("General" => Dict("Pkg" => ["0.4.2"]), "ct-registry" => Dict("Pkg" => ["0.4.3-beta"]))) do
            @test collect(keys(registry_versions("General", "Pkg"))) == [v"0.4.2"]
            @test collect(keys(registry_versions("ct-registry", "Pkg"))) == [v"0.4.3-beta"]
            @test isempty(registry_versions("General", "Other"))
        end
    end

    @testset "changelog" begin
        ok = changelog("0.4.3" => "### 🐛 Bug Fixes\n\n- a fix.", "0.4.2" => "- first.")
        @test isempty(check_changelog(ok, v"0.4.3"))
        @test first.(sections(ok)) == ["Unreleased", "0.4.3", "0.4.2"]
        @test any(contains("not empty"), check_changelog(replace(ok, "## [Unreleased]\n" => "## [Unreleased]\n\n- pending.\n"), v"0.4.3"))
        @test any(contains("first versioned section"), check_changelog(ok, v"0.4.4"))
        @test any(contains("Compatibility"), check_changelog(replace(ok, "### ✅ Compatibility" => "### Compat"), v"0.4.3"))
        @test any(contains("no date"), check_changelog(replace(ok, "## [0.4.3] - 2026-10-18" => "## [0.4.3]"), v"0.4.3"))
        @test any(contains("Unreleased"), check_changelog(replace(ok, "## [Unreleased]\n\n" => ""), v"0.4.3"))
        c = changelog("0.5.1-beta" => "### ✨ New Features\n\n- x.", "0.5.0-beta" => "### 💥 Breaking Changes\n\n- y.", "0.4.2" => "- z.")
        @test changes_since(c, v"0.4.2") == (; breaking=true, feature=true, versions=["Unreleased", "0.5.1-beta", "0.5.0-beta"])
        @test changes_since(c, v"0.5.0-beta").breaking == false
        # BREAKING.md headings as the packages write them
        @test names_version("## Non-breaking note (0.30.12)", v"0.30.12")
        @test names_version("## v0.6.1 (2026-10-15)", v"0.6.1")
        @test names_version("## 0.18.1", v"0.18.1")
        @test names_version("## Breaking Changes: v2.0 → v2.1.0-beta", v"2.1.0-beta")
        @test !names_version("## Non-breaking note (0.30.11)", v"0.30.1")
        @test !names_version("## Breaking Changes: v2.0 → v2.1.0-beta", v"2.1.0")
        @test !names_version("- 0.30.12 in a list", v"0.30.12")
    end

    @testset "changes" begin
        p = Dict("name" => "P", "version" => "1.0.0", "deps" => Dict("A" => "u"))
        @test isempty(shipped(["test/runtests.jl", ".github/workflows/CI.yml", "CHANGELOG.md"], p, merge(p, Dict("version" => "1.0.1"))))
        @test shipped(["src/P.jl", "test/x.jl"], p, p) == ["src/P.jl"]
        @test shipped(["docs/make.jl"], p, p) == ["docs/make.jl"]
        @test shipped(String[], p, merge(p, Dict("compat" => Dict("A" => "1")))) == ["Project.toml"]
        mktempdir() do d
            write(joinpath(d, "CI.yml"), "contains(github.event.pull_request.labels.*.name, 'run ci github-runner')\n" *
                  "contains(github.event.pull_request.labels.*.name, 'run ci kkt-runner')\n" *
                  "contains(github.event.pull_request.labels.*.name, 'run ci occidata-runner')\n" *
                  "contains(github.event.pull_request.labels.*.name, 'run probe')\n")
            e = run_labels(d)
            @test e == Set(["run ci github-runner", "run ci kkt-runner", "run ci occidata-runner", "run probe"])
            @test missing_labels(e, ["run ci github-runner", "run ci kkt-runner"]) == String[]
            @test missing_labels(e, ["run ci github-runner", "run ci occidata-runner"]) == String[]   # the fallback
            @test missing_labels(e, ["run ci github-runner"]) == ["one of `run ci kkt-runner`, `run ci occidata-runner`"]
            @test missing_labels(e, String[]) == ["run ci github-runner", "one of `run ci kkt-runner`, `run ci occidata-runner`"]
        end
        @test isempty(run_labels("/nonexistent"))
    end

    @testset "gate" begin
        regs = Dict("General" => Dict("Pkg" => ["0.4.2"]), "ct-registry" => Dict{String,Vector{String}}())
        labels = ["run ci github-runner"]
        with_registries(regs) do
            dir, base = package_repo()
            r = gate(dir, base; labels, resolution=false)
            @test isempty(failures(r))
            @test occursin("✅ ready", gate_report("Pkg", r))
            # a PR that keeps the version is not a release
            @test only(gate(dir, "HEAD"; labels, resolution=false)).status === :info
            # missing label
            @test any(contains("missing labels"), failures(gate(dir, base; labels=String[], resolution=false)))
            # a breaking number without a breaking entry, and not the expected one
            dir, base = package_repo(version="0.5.0")
            f = failures(gate(dir, base; labels, resolution=false))
            @test any(contains("is breaking, but the changelog"), f)
            @test any(contains("the expected version is `0.4.3`"), f)
            # a breaking entry with a breaking number passes
            dir, base = package_repo(version="0.5.0", entries=("0.5.0" => "### 💥 Breaking Changes\n\n- removed.",))
            @test isempty(failures(gate(dir, base; labels, resolution=false)))
            # REL7: tests only since the last release
            dir, base = package_repo(after="mkdir -p test && echo x > test/t.jl")
            @test any(contains("nothing reaches a user"), failures(gate(dir, base; labels, resolution=false)))
            # docs only: a release
            dir, base = package_repo(after="mkdir -p docs && echo x > docs/make.jl")
            @test isempty(failures(gate(dir, base; labels, resolution=false)))
            # the PR touches more than the release files
            dir, base = package_repo(extra="echo '# more' >> src/Pkg.jl")
            @test any(contains("also changes `src/Pkg.jl`"), failures(gate(dir, base; labels, resolution=false)))
            # no BREAKING entry
            dir, base = package_repo(breaking_md="")
            @test any(contains("`BREAKING.md` has no"), failures(gate(dir, base; labels, resolution=false)))
            # a suffix that is not -beta
            dir, base = package_repo(version="0.4.3-rc", entries=("0.4.3-rc" => "- x.",))
            @test any(contains("only suffix allowed"), failures(gate(dir, base; labels, resolution=false)))
        end
        # REL2/REL3: the betas took 0.4.3, the stable is 0.4.4, a jump explained by them
        with_registries(Dict("General" => Dict("Pkg" => ["0.4.2"]), "ct-registry" => Dict("Pkg" => ["0.4.3-beta"]))) do
            dir, base = package_repo()
            @test any(contains("not above every version released"), failures(gate(dir, base; labels, resolution=false)))
            dir, base = package_repo(version="0.4.4")
            r = gate(dir, base; labels, resolution=false)
            @test isempty(failures(r))
            @test any(x -> x.status === :info && contains(x.message, "[merge approved]"), r)
        end
        # an unexplained jump
        with_registries(regs) do
            dir, base = package_repo(version="0.4.5")
            f = failures(gate(dir, base; labels, resolution=false))
            @test any(contains("a jump that no beta explains"), f)
        end
    end

    @testset "tag plan" begin
        dir, base = package_repo()
        sh(dir, "git checkout -q main && git -c user.name=t -c user.email=t@t merge -q --no-ff release/v0.4.3 -m merge")
        p = tag_plan(dir)
        @test p.tag == "v0.4.3" && p.previous == "v0.4.2" && !p.prerelease
        @test p.target == strip(read(Cmd(`git rev-parse HEAD`; dir), String))
        # a later commit on main: the merge commit is still the target
        sh(dir, "echo x >> src/Pkg.jl && git -c user.name=t -c user.email=t@t commit -qam later")
        @test tag_plan(dir).target == p.target
        # idempotent: once tagged, nothing to do
        sh(dir, "git tag v0.4.3 $(p.target)")
        @test tag_plan(dir).tag === nothing && contains(tag_plan(dir).reason, "already tagged")
        # a beta: pre-release, notes since the last release of any kind
        dir, base = package_repo(version="0.4.3-beta", entries=("0.4.3-beta" => "- x.",))
        sh(dir, "git checkout -q main && git -c user.name=t -c user.email=t@t merge -q --no-ff release/v0.4.3-beta -m merge")
        p = tag_plan(dir)
        @test p.tag == "v0.4.3-beta" && p.prerelease && p.previous == "v0.4.2"
    end

    @testset "status" begin
        base = (; repo="o/P", name="P", version=v"0.4.3", kind=:stable, main_version=v"0.4.3", main_sha="M",
                issue=(; number=1, state="OPEN"), mentions=0, pr=(; number=2, state="MERGED", merge="M", auto=true),
                tag="M", tag_tree="T", release=false, registry="General", registered=nothing, general_pr=nothing)
        at(; kw...) = merge(base, (; kw...))
        @test phase(at(issue=nothing, pr=nothing, tag=nothing, release=nothing)).phase == 0
        @test phase(at(pr=nothing, tag=nothing, release=nothing)).phase == 3
        @test phase(at(pr=(; number=2, state="OPEN", merge=nothing, auto=true), tag=nothing, release=nothing)).state === :waiting
        @test phase(at(pr=(; number=2, state="CLOSED", merge=nothing, auto=false), tag=nothing)).state === :blocked
        @test phase(at(tag=nothing, release=nothing)).phase == 6
        @test phase(at(tag="X")).state === :blocked                         # tag on another commit
        @test phase(at(release=true)).state === :blocked                    # a stable marked pre-release
        p = phase(at())
        @test p.phase == 7 && p.state === :todo && contains(p.next, "once")
        # REL6: posted, no General PR: never again
        p = phase(at(mentions=1))
        @test p.state === :blocked && contains(only(p.blockers), "never post it again")
        @test phase(at(main_sha="N")).state === :blocked                    # main moved past the merge
        @test phase(at(mentions=1, general_pr=(; number=9, state="OPEN"))).state === :waiting
        @test phase(at(mentions=1, general_pr=(; number=9, state="CLOSED"))).state === :blocked
        @test phase(at(registered="T")).phase == 8
        @test phase(at(registered="T", issue=(; number=1, state="CLOSED"))).state === :done
        @test phase(at(registered="U")).state === :blocked                  # another tree registered
        @test phase(at(registered="T", tag=nothing, tag_tree=nothing)).state === :blocked   # REL5: no tag
        @test phase(at(registered="T", release=nothing)).phase == 6
        beta = at(version=v"0.4.3-beta", kind=:beta, release=true, registry="ct-registry")
        @test contains(phase(beta).next, "ct-registry")
        # facts, through a fake gh: an issue with the mention counted, nothing else yet
        with_registries(Dict("General" => Dict("P" => ["0.4.2"]))) do
            with_gh(function (args)
                    a = join(args, " ")
                    contains(a, "contents/Project.toml") && return "name = \"P\"\nversion = \"0.4.2\"\n"
                    contains(a, "commits/main") && return "M\n"
                    contains(a, "issue list") && contains(a, "open") && return "[RELEASE] v0.4.3\n"
                    contains(a, "issue list") && return "7 OPEN\n"
                    contains(a, "issue view") && return "0\n"
                    contains(a, "pr list -R o/P") && return ""
                    return nothing
                end) do
                f = facts("o/P")
                @test f.version == v"0.4.3" && f.issue == (; number=7, state="OPEN") && f.pr === nothing
                @test phase(f).phase == 3
            end
        end
    end

    @testset "registrable" begin
        @testset "applies" begin
            stable = Dict("version" => "1.2.0")
            @test applies(stable, Dict("version" => "1.1.0")) == (true, "`1.1.0` → `1.2.0`: a stable release")
            @test first(applies(stable, Dict{String,Any}()))
            @test !first(applies(stable, Dict("version" => "1.2.0")))
            @test !first(applies(Dict("version" => "1.2.0-beta"), Dict("version" => "1.1.0")))
            @test first(applies(Dict("version" => "1.2.0-beta"), nothing))
            @test !first(applies(Dict{String,Any}(), nothing))
        end
        @testset "environments" begin
            envs = environments(fixture("stable.toml"))
            @test first.(envs) == ["[deps]", "[deps] + OrderedCollections"]
            @test last(envs[2]) == Dict("Example" => EXAMPLE, "OrderedCollections" => ORDERED)
            @test compat_for(fixture("stable.toml"), Dict("Example" => EXAMPLE)) == Dict("Example" => "0.5")
        end
        @testset "satisfying" begin
            vs = [v"0.8.15", v"0.9.0-beta", v"0.9.5-beta"]
            # Pkg's specifiers accept a pre-release of a version in range: ct-registry relies on it
            @test satisfying("0.9", vs) == [v"0.9.0-beta", v"0.9.5-beta"]
            @test isempty(satisfying("1", vs))
        end
        @testset "diagnose" begin
            general = FakeRegistry("General", Dict(EXAMPLE => [v"0.5.5"], ORDERED => [v"1.6.0", v"2.0.3"]))
            beta = FakeRegistry("ct-registry", Dict(EXAMPLE => [v"0.9.0-beta"]))
            @test isempty(diagnose(fixture("stable.toml"), general, [beta]))
            found = only(diagnose(fixture("beta-only.toml"), general, [beta]))
            @test found.name == "Example" && found.spec == "0.9" && found.elsewhere == ["ct-registry" => [v"0.9.0-beta"]]
            found = only(diagnose(fixture("weak-beta-only.toml"), FakeRegistry("General", Dict(EXAMPLE => [v"0.5.5"])), [beta]))
            @test found.name == "OrderedCollections" && !found.registered
        end
    end

    @testset "command line" begin
        @test command()[1] == 2
        @test command("nope")[1] == 2
        @test command("gate")[1] == 2                     # --base is required
        dir, base = package_repo()
        sh(dir, "git checkout -q main")                    # the release PR is not merged
        code, out = command("tag-plan", dir)
        @test code == 0 && contains(out, "tag=\nreason=`v0.4.2` is already tagged")
    end

    if any(r -> r.name == GENERAL, Pkg.Registry.reachable_registries())
        @testset "integration" begin
            g = registry(Pkg.Registry.reachable_registries(), GENERAL)
            p = fixture("stable.toml")
            @test all(first(resolve(deps, compat_for(p, deps), [g])) for (_, deps) in environments(p))
            code, out = command("registrable", joinpath(FIXTURES, "stable.toml"))
            @test code == 0 && occursin("✅ yes", out)
            code, out = command("registrable", joinpath(FIXTURES, "beta-only.toml"))
            @test code == 1 && occursin("`Example = \"0.9\"`", out)
            code, out = command("registrable", joinpath(FIXTURES, "weak-beta-only.toml"))
            @test code == 1 && occursin("| [deps] + OrderedCollections | ❌ |", out)
            base = joinpath(FIXTURES, "beta-only.toml")
            code, out = command("registrable", "--base", base, base)
            @test code == 0 && occursin("not checked", out)
            # the gate with REL4, on a package that resolves (Example 0.5), registries faked
            with_registries(Dict("General" => Dict("Pkg" => ["0.4.2"]))) do
                dir, base = package_repo()
                r = gate(dir, base; labels=["run ci github-runner"])
                @test any(x -> x.rule == "REL4" && x.status === :pass, r)
                @test isempty(failures(r))
            end
        end
    else
        @info "Integration tests skipped: the General registry is not installed"
    end
end
