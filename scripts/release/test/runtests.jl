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
changes since the release), merged on `main` and tagged `tag_after` if given; then a release branch that sets `version`
with `entries` in the changelog and a BREAKING note. Returns the directory and the base.
"""
function package_repo(; version="0.4.3", after="mkdir -p src && echo '# fix' >> src/Pkg.jl",
                      entries=(version => "### 🐛 Bug Fixes\n\n- a fix.",), breaking_md="## Non-breaking note ($version)\n\n- none.\n",
                      extra="", workflows=true, tag_after="")
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
    isempty(tag_after) || sh(dir, "git tag $tag_after")
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
            # in the workflow, missing labels are reported, not failed: it runs once per label added
            r = gate(dir, base; labels=String[], resolution=false, labels_info=true)
            @test isempty(failures(r))
            @test any(x -> x.status === :info && contains(x.message, "labels not on the PR at this event: run ci github-runner"), r)
            @test any(x -> x.status === :pass && contains(x.message, "run labels"), gate(dir, base; labels, resolution=false, labels_info=true))
            # a broken encoding in a release file (a replacement character, or invalid UTF-8)
            for bad in ("\ufffd", "\xff")
                d2, b2 = package_repo()
                write(joinpath(d2, "CHANGELOG.md"), read(joinpath(d2, "CHANGELOG.md"), String) * bad)
                @test any(contains("replacement character"), failures(gate(d2, b2; labels, resolution=false)))
            end
            @test any(contains("no broken encoding"), [r.message for r in gate(dir, base; labels, resolution=false)])
            # the preview label: reported for a package with a Documentation.yml, never a failure
            d2, b2 = package_repo(after="mkdir -p src && echo '# fix' >> src/Pkg.jl && echo 'name: Documentation' > .github/workflows/Documentation.yml")
            r = gate(d2, b2; labels, resolution=false)
            @test isempty(failures(r)) && any(x -> x.status === :info && contains(x.message, "documentation push preview"), r)
            r = gate(d2, b2; labels=[labels; "documentation push preview"], resolution=false)
            @test isempty(failures(r)) && !any(x -> contains(x.message, "documentation push preview"), r)
            @test !any(x -> contains(x.message, "documentation push preview"), gate(dir, base; labels, resolution=false))   # no Documentation.yml
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
        # a stable after a beta, with nothing new since the beta: a release (REL7 compares
        # with the last stable), numbered above the beta, the jump explained by it
        with_registries(Dict("General" => Dict("Pkg" => ["0.4.2"]), "ct-registry" => Dict("Pkg" => ["0.4.3-beta"]))) do
            beta = "mkdir -p src && echo '# fix' >> src/Pkg.jl && sed -i.bak 's/^version = .*/version = \"0.4.3-beta\"/' Project.toml && rm Project.toml.bak"
            dir, base = package_repo(version="0.4.4", after=beta, tag_after="v0.4.3-beta",
                                     entries=("0.4.4" => "- the stable release of `0.4.3-beta`.",
                                              "0.4.3-beta" => "### 🐛 Bug Fixes\n\n- a fix."))
            @test strip(read(Cmd(`git diff --name-only v0.4.3-beta $base`; dir=dir), String)) == ""   # nothing since the beta
            r = gate(dir, base; labels, resolution=false)
            @test isempty(failures(r))
            @test any(x -> x.rule == "REL7" && x.status === :pass && contains(x.message, "since `v0.4.2`"), r)
            @test any(x -> x.rule == "REL3" && x.status === :info, r)
            # numbered 0.4.3, the beta's triple: refused
            dir, base = package_repo(version="0.4.3", after=beta, tag_after="v0.4.3-beta",
                                     entries=("0.4.3" => "- x.", "0.4.3-beta" => "### 🐛 Bug Fixes\n\n- a fix."))
            @test any(contains("not above every version released"), failures(gate(dir, base; labels, resolution=false)))
        end
        # REL6, on every PR: the bot's mention in the PR's text or a commit message
        with_registries(regs) do
            dir, base = package_repo()
            m = MENTION * " register"
            f = failures(gate(dir, base; labels, text="Release.\n\nAfter merge: $m", resolution=false))
            @test any(contains("mentioned in the PR's title or description"), f)
            @test isempty(failures(gate(dir, base; labels, text="Release. The bot is called after merge.", resolution=false)))
            # in a commit message
            sh(dir, "git -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'note: $m later'")
            @test any(contains("a commit message"), failures(gate(dir, base; labels, resolution=false)))
            # on a PR that is not a release
            r = gate(dir, "HEAD~1"; labels, text=m, resolution=false)
            @test any(x -> x.status === :info, r) && any(x -> x.rule == "REL6" && x.status === :fail, r)
            @test occursin("❌ blocked", gate_report("Pkg", r))
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
        # REL6: posted, no answer yet: wait, never post again
        p = phase(at(mentions=1))
        @test p.state === :waiting && contains(p.next, "never post it again")
        p = phase(at(mentions=1, bot_error="Error while trying to register: the tag exists"))
        @test p.state === :blocked && contains(only(p.blockers), "the tag exists")
        @test phase(at(mentions=2)).state === :blocked
        @test phase(at(issues=2)).state === :blocked                        # duplicate tracking issues
        # main moved past the merge: still todo, but on the merge commit only
        p = phase(at(main_sha="N"))
        @test p.state === :todo && p.on_commit && contains(p.next, "--on-commit")
        @test !phase(at()).on_commit
        @test phase(at(mentions=1, general_pr=(; number=9, state="OPEN"))).state === :waiting
        # a jump of version is mentioned only when there is one (REL3)
        wait7(j) = phase(at(mentions=1, general_pr=(; number=9, state="OPEN"), jump=j)).next
        @test !contains(wait7(:none), "merge approved") && contains(wait7(:betas), "`[merge approved]` is needed")
        @test contains(wait7(:unexplained), "a human decides") && !contains(wait7(:unexplained), "merge approved")
        @test !contains(phase(at(mentions=1, general_pr=(; number=9, state="OPEN"))).next, "merge approved")   # facts without a jump
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

    @testset "facts and register, on a fake GitHub" begin
        changelog_text = changelog("0.4.3" => "### 🐛 Bug Fixes\n\n- a fix. See [BREAKING.md](BREAKING.md) and [#1](https://x/1).")
        "A GitHub at phase 7 of `P` v0.4.3, whose state the fake updates when a comment is posted."
        function github(; mentions=0, answers="", main="M", kind_version="0.4.3", issues=["7 OPEN"])
            st = Dict(:mentions => mentions, :posted => String[], :on_commit => String[])
            fake = function (args)
                a = join(args, " ")
                contains(a, "contents/Project.toml") && return "name = \"P\"\nversion = \"$kind_version\"\n"
                contains(a, "contents/CHANGELOG.md") && return changelog_text
                contains(a, "commits/main") && return "$main\n"
                contains(a, "issue list") && return join(issues, "\n")
                contains(a, "issue view") && contains(a, "body,comments") && return "$(st[:mentions])\n"
                contains(a, "issue view") && return answers
                contains(a, "pr list -R o/P") && return "2 MERGED M true\n"
                contains(a, "commits/v") && contains(a, "tree") && return "T\n"
                contains(a, "commits/v") && return "M\n"
                contains(a, "release view") && contains(a, "isPrerelease") && return "$(occursin("beta", kind_version))\n"
                contains(a, "release view") && return "## What's Changed\n* fix by @a in #1\n"
                contains(a, "pr list -R JuliaRegistries/General") && return ""
                contains(a, "pr view") && return "MERGED\n"
                if contains(a, "commits/M/comments")
                    if "-F" in args
                        push!(st[:on_commit], read(replace(args[findfirst(==("-F"), args) + 1], "body=@" => ""), String))
                        st[:mentions] += 1
                        return "https://github.com/o/P/commit/M#commitcomment-1\n"
                    end
                    return contains(a, "length") ? "0\n" : ""
                end
                if contains(a, "issue comment")
                    push!(st[:posted], read(args[findfirst(==("--body-file"), args) + 1], String))
                    st[:mentions] += 1
                    return "https://github.com/o/P/issues/7#issuecomment-1\n"
                end
                return nothing
            end
            return fake, st
        end
        # a jump in General that betas explain (REL3), as `status` sees it
        with_registries(Dict("General" => Dict("P" => ["0.4.2"]), "ct-registry" => Dict("P" => ["0.4.4-beta"]))) do
            fake, _ = github()
            with_gh(fake) do
                @test facts("o/P"; version="0.4.5").jump === :betas
                @test facts("o/P"; version="0.4.3").jump === :none
                @test facts("o/P"; version="0.4.9").jump === :unexplained
                @test facts("o/P"; version="0.4.5-beta").jump === :none          # a beta has no jump
            end
        end
        # once registered, the version is in General: the jump is still read against the versions before it
        with_registries(Dict("General" => Dict("P" => ["0.4.2", "0.4.5"]), "ct-registry" => Dict("P" => ["0.4.4-beta"]))) do
            fake, _ = github()
            with_gh(fake) do
                @test facts("o/P"; version="0.4.5").jump === :betas
            end
        end
        with_registries(Dict("General" => Dict("P" => ["0.4.2"]))) do
            fake, st = github()
            with_gh(fake) do
                f = facts("o/P"; version="0.4.3")
                @test f.issue == (; number=7, state="OPEN") && f.issues == 1 && f.mentions == 0
                @test f.jump === :none
                @test phase(f).phase == 7 && phase(f).state === :todo
                # dry run: nothing posted, the mention masked
                ok, msg = register("o/P", v"0.4.3")
                @test ok && isempty(st[:posted])
                @test !occursin(MENTION, msg) && occursin("<the registration bot's mention> register", msg)
                # posted once, then refused
                ok, msg = register("o/P", v"0.4.3"; post=true)
                @test ok && length(st[:posted]) == 1
                body = only(st[:posted])
                @test startswith(body, MENTION * " register\n\nRelease notes:\n")
                @test count(MENTION, body) == 1
                @test occursin("](https://github.com/o/P/blob/v0.4.3/BREAKING.md)", body)   # made absolute
                @test occursin("[#1](https://x/1)", body)                                    # left as is
                @test occursin("## What's Changed", body)
                ok, msg = register("o/P", v"0.4.3"; post=true)
                @test !ok && length(st[:posted]) == 1 && occursin("not ready", msg)
            end
            # main moved past the merge: refused on the issue; on the merge commit only when asked
            fake, st = github(main="N")
            with_gh(fake) do
                ok, msg = register("o/P", v"0.4.3"; post=true)
                @test !ok && isempty(st[:posted]) && isempty(st[:on_commit]) && occursin("--on-commit", msg)
                ok, msg = register("o/P", v"0.4.3"; on_commit=true)          # dry run
                @test ok && isempty(st[:on_commit]) && occursin("the merge commit M", msg) && !occursin(MENTION, msg)
                ok, msg = register("o/P", v"0.4.3"; post=true, on_commit=true)
                @test ok && isempty(st[:posted]) && length(st[:on_commit]) == 1
                @test startswith(only(st[:on_commit]), MENTION * " register")
                ok, msg = register("o/P", v"0.4.3"; post=true, on_commit=true)  # never twice
                @test !ok && length(st[:on_commit]) == 1
            end
            # --on-commit while main is at the merge: refused
            fake, st = github()
            with_gh(fake) do
                ok, msg = register("o/P", v"0.4.3"; post=true, on_commit=true)
                @test !ok && isempty(st[:posted]) && isempty(st[:on_commit]) && occursin("tracking issue", msg)
            end
            # the bot answered: the General PR is read from its answer, not from the search
            fake, st = github(mentions=1, answers="Registration pull request created: [JuliaRegistries/General/172378](https://github.com/JuliaRegistries/General/pull/172378)\n")
            with_gh(fake) do
                f = facts("o/P"; version="0.4.3")
                @test f.general_pr == (; number=172378, state="MERGED") && f.bot_error === nothing
            end
            fake, st = github(mentions=1, answers="Error while trying to register: Version 0.4.3 already exists\n")
            with_gh(fake) do
                f = facts("o/P"; version="0.4.3")
                @test f.general_pr === nothing && contains(f.bot_error, "already exists")
                @test phase(f).state === :blocked
                @test !first(register("o/P", v"0.4.3"; post=true)) && isempty(st[:posted])
            end
            # two tracking issues for the same version
            fake, st = github(issues=["7 OPEN", "8 OPEN"])
            with_gh(fake) do
                @test phase(facts("o/P"; version="0.4.3")).state === :blocked
            end
        end
        # a beta is never registered with the bot
        with_registries(Dict("ct-registry" => Dict("P" => ["0.4.2"]))) do
            fake, st = github(kind_version="0.4.3-beta")
            with_gh(fake) do
                ok, msg = register("o/P", v"0.4.3-beta"; post=true)
                @test !ok && isempty(st[:posted]) && occursin("ct-registry", msg)
            end
        end
        @test_throws ArgumentError registration_body(changelog_text, v"9.9.9", "o/P", "")
    end

    @testset "properties of the numbering (random histories)" begin
        # Random sequences of releases; each new number must satisfy REL1-REL3 whatever
        # came before. A stable's changes are those since the last stable, betas included.
        rng_state = Ref(UInt64(20261019))
        rnd() = (rng_state[] = rng_state[] * 6364136223846793005 + 1442695040888963407; rng_state[] >> 33)
        chance(p) = rnd() % 1000 < p * 1000
        checked = 0
        for history in 1:2000
            released = [rnd() % 2 == 0 ? v"0.4.2" : v"1.2.0"]
            general = [released[1]]
            betas = VersionNumber[]
            breaking_since_stable = false
            for step in 1:20
                kind = chance(0.4) ? :beta : :stable
                breaking = chance(0.15)
                feature = chance(0.4)
                stable_ref = maximum(filter(isstable, released))
                cum = breaking || (kind === :stable && breaking_since_stable)
                v = expected_version(kind, released; breaking=cum, feature)
                @test v !== nothing                          # cumulative breaking always fits
                v === nothing && break
                @test allowed_suffix(v) && isbeta(v) == (kind === :beta)
                @test triple(v) > maximum(triple, released)  # REL2: a fresh triple
                ref = kind === :stable ? stable_ref : maximum(released)
                @test is_breaking(ref, v) == cum             # REL1: breaking exactly when it is
                if kind === :stable
                    @test jump(maximum(general), v, betas) !== :unexplained   # REL3
                    push!(general, v); breaking_since_stable = false
                else
                    push!(betas, v); breaking_since_stable |= breaking
                end
                push!(released, v)
                checked += 1
            end
        end
        @test checked == 40000
    end

    @testset "edge cases" begin
        # REL7: test-only entries of Project.toml do not make a release; dependencies do
        p = Dict("deps" => Dict("A" => "u"), "compat" => Dict("A" => "1", "julia" => "1.10"),
                 "extras" => Dict("Test" => "t"), "targets" => Dict("test" => ["Test"]))
        q = merge(p, Dict("extras" => Dict("Test" => "t", "Aqua" => "a"), "compat" => Dict("A" => "1", "julia" => "1.10", "Aqua" => "0.8")))
        @test isempty(shipped(String[], p, q))
        @test shipped(String[], p, merge(p, Dict("compat" => Dict("A" => "1, 2", "julia" => "1.10")))) == ["Project.toml"]
        @test shipped(String[], p, merge(p, Dict("compat" => Dict("A" => "1", "julia" => "1.11")))) == ["Project.toml"]
        @test shipped(String[], p, merge(p, Dict("weakdeps" => Dict("B" => "b")))) == ["Project.toml"]
        # a commented-out guard requires no label
        mktempdir() do d
            write(joinpath(d, "CI.yml"), "# if: contains(github.event.pull_request.labels.*.name, 'run old')\n" *
                                         "  if: contains(github.event.pull_request.labels.*.name, 'run ci github-runner')\n")
            write(joinpath(d, "Old.yml.disabled"), "contains(github.event.pull_request.labels.*.name, 'run gpu')\n")
            @test run_labels(d) == Set(["run ci github-runner"])
        end
        # the reference section missing from the changelog: stop at the first older one
        c = changelog("0.4.4" => "- x.", "0.4.1" => "### 💥 Breaking Changes\n\n- old.")
        @test changes_since(c, v"0.4.2") == (; breaking=false, feature=false, versions=["Unreleased", "0.4.4"])
        # versions going down, or a triple already taken by a stable, are refused
        with_registries(Dict("General" => Dict("Pkg" => ["0.4.2", "0.4.3"]))) do
            dir, base = package_repo()
            @test any(contains("not above every version released"), failures(gate(dir, base; labels=["run ci github-runner"], resolution=false)))
        end
        # registration_body keeps a link already absolute, an anchor, a mail
        b = registration_body(changelog("1.0.0" => "- [a](#x) [b](mailto:m@x) [c](docs/x.md) [d](http://e)"), v"1.0.0", "o/P", "")
        @test occursin("[a](#x)", b) && occursin("[b](mailto:m@x)", b) && occursin("[d](http://e)", b)
        @test occursin("[c](https://github.com/o/P/blob/v1.0.0/docs/x.md)", b)
    end

    @testset "ready and merge, on a fake GitHub" begin
        gate_if(l) = "    if: >\n      (github.event.action != 'labeled' && contains(github.event.pull_request.labels.*.name, '$l'))\n"
        workflows = Dict(
            "CI.yml" => "name: CI\non:\n  pull_request:\njobs:\n" *
                        "  test-cpu-github:\n" * gate_if("run ci github-runner") * "    uses: x\n" *
                        "  test-gpu-kkt:\n" * gate_if("run ci kkt-runner") * "    uses: x\n" *
                        "  test-gpu-occidata:\n" * gate_if("run ci occidata-runner") * "    uses: x\n" *
                        "  smoke:\n" * gate_if("run ci github-runner") * "    runs-on: ubuntu-latest\n" *
                        "  # old:\n  #   if: contains(github.event.pull_request.labels.*.name, 'run old')\n",
            "Documentation.yml" => "jobs:\n  call:\n" * gate_if("run documentation") * "    uses: x\n",
            "Breakage.yml" => "jobs:\n  call:\n" * gate_if("run breakage") * "    uses: x\n",
            "ReleaseGate.yml" => "on:\n  pull_request:\njobs:\n  call:\n    uses: x\n",
            "SpellCheck.yml" => "jobs:\n  spell:\n    runs-on: ubuntu-latest\n")
        good_runs() = [(1, "CI.yml", "completed", "skipped"), (2, "CI.yml", "completed", "success"),
                       (3, "Documentation.yml", "completed", "success"), (4, "Breakage.yml", "completed", "success"),
                       (5, "ReleaseGate.yml", "completed", "success"), (6, "SpellCheck.yml", "completed", "success")]
        good_jobs() = Dict(
            1 => [("test-cpu-github", "skipped"), ("test-gpu-kkt", "skipped"), ("test-gpu-occidata", "skipped"), ("smoke", "skipped")],
            2 => [("test-cpu-github / test (1.10, ubuntu-latest, x64)", "success"), ("test-gpu-kkt / test (1.12)", "success"),
                  ("test-gpu-occidata", "skipped"), ("smoke (ubuntu-latest)", "success")],
            3 => [("call / build", "success"), ("call / build-gpu", "skipped")],
            4 => [("call (CTModels, stable) / break", "success"), ("call / report", "success")],
            5 => [("call / gate", "success")], 6 => [("spell", "success")])
        good_labels = ["run ci github-runner", "run ci kkt-runner", "run documentation", "run breakage"]
        function fake_github(; state="OPEN", draft=false, branch="release/v0.4.3", mergeable="MERGEABLE", behind=0,
                             labels=good_labels, runs=good_runs(), jobs=good_jobs(), merge_ok=true)
            merged = String[]
            fake = function (args)
                a = join(args, " ")
                contains(a, "pr view") && return "$state\t$draft\tH\t$branch\t$mergeable\t$(join(labels, ","))\n"
                contains(a, "compare/main...H") && return "$behind\n"
                contains(a, "contents/.github/workflows?ref=H") && return join(sort(collect(keys(workflows))), "\n") * "\n"
                m = match(r"contents/\.github/workflows/([^?]+)\?ref=H", a)
                m !== nothing && return workflows[m[1]]
                contains(a, "actions/runs?head_sha=H") &&
                    return join(("$id\t.github/workflows/$f\t$st\t$c" for (id, f, st, c) in runs), "\n") * "\n"
                m = match(r"actions/runs/(\d+)/jobs", a)
                m !== nothing && return join(("$n\t$c" for (n, c) in get(jobs, parse(Int, m[1]), [])), "\n") * "\n"
                if contains(a, "pr merge")
                    push!(merged, a)
                    return merge_ok ? "" : nothing
                end
                return nothing
            end
            return fake, merged
        end
        notready(r, pattern) = !r.ready && any(l -> l.status !== :pass && contains(l.message, pattern), r.lines)

        # all green: ready; merge only with --confirm, at the head checked
        fake, merged = fake_github()
        with_gh(fake) do
            r = ready("o/P", 2)
            @test r.ready && r.head == "H" && all(l -> l.status === :pass, r.lines)
            @test any(l -> contains(l.message, "`CI.yml`, run 2"), r.lines)          # not the skipped run 1
            @test any(l -> contains(l.message, "`Documentation.yml`, run 3: 1 job(s)"), r.lines)   # build-gpu skipped is fine
            ok, msg = merge_release("o/P", 2)
            @test ok && isempty(merged) && contains(msg, "Dry run")
            ok, msg = merge_release("o/P", 2; confirm=true)
            @test ok && only(merged) == "pr merge 2 -R o/P --merge --match-head-commit H"
        end
        # the trap: a later run with every job skipped does not hide a failed run
        jobs = good_jobs(); jobs[2] = [("test-cpu-github / test (1.10)", "failure"), ("test-gpu-kkt / test", "success"), ("smoke", "success")]
        fake, merged = fake_github(runs=vcat(good_runs(), [(7, "CI.yml", "completed", "skipped")]), jobs=merge(jobs, Dict(7 => [("smoke", "skipped")])))
        with_gh(fake) do
            r = ready("o/P", 2)
            @test notready(r, "`CI.yml`, run 2: `test-cpu-github / test (1.10)` did not pass")
            @test !first(merge_release("o/P", 2; confirm=true)) && isempty(merged)
        end
        # a job whose label is on the PR was skipped in the run that counts
        jobs = good_jobs(); jobs[2] = [("test-cpu-github / test", "success"), ("test-gpu-kkt", "skipped"), ("smoke", "success")]
        fake, _ = fake_github(jobs=jobs)
        with_gh(() -> @test(notready(ready("o/P", 2), "`test-gpu-kkt` did not run")), fake)
        # GPU: occidata as the fallback is enough; no GPU label is not
        jobs = good_jobs(); jobs[2] = [("test-cpu-github / test", "success"), ("test-gpu-kkt", "skipped"),
                                       ("test-gpu-occidata / test", "success"), ("smoke", "success")]
        fake, _ = fake_github(labels=["run ci github-runner", "run ci occidata-runner", "run documentation", "run breakage"], jobs=jobs)
        with_gh(() -> @test(ready("o/P", 2).ready), fake)
        fake, _ = fake_github(labels=["run ci github-runner", "run documentation", "run breakage"])
        with_gh(() -> @test(notready(ready("o/P", 2), "no GPU label")), fake)
        # a workflow whose label is missing: no run executed its jobs
        runs = [r for r in good_runs() if r[2] != "Breakage.yml"]
        fake, _ = fake_github(labels=["run ci github-runner", "run ci kkt-runner", "run documentation"],
                              runs=vcat(runs, [(8, "Breakage.yml", "completed", "skipped")]))
        with_gh(() -> @test(notready(ready("o/P", 2), "`Breakage.yml`: no run executed its jobs")), fake)
        # a run in progress: wait
        fake, _ = fake_github(runs=vcat(good_runs(), [(9, "CI.yml", "in_progress", "")]))
        with_gh(fake) do
            r = ready("o/P", 2)
            @test notready(r, "`CI.yml`: a run is in progress")
            @test contains(ready_report("o/P", 2, r), "⏳ wait")
        end
        # the gate failed; a check outside the release failed too
        jobs = good_jobs(); jobs[5] = [("call / gate", "failure")]; jobs[6] = [("spell", "failure")]
        fake, _ = fake_github(runs=[(i, f, st, i in (5, 6) ? "failure" : c) for (i, f, st, c) in good_runs()], jobs=jobs)
        with_gh(fake) do
            r = ready("o/P", 2)
            @test notready(r, "`ReleaseGate.yml`") && notready(r, "`SpellCheck.yml`")
        end
        # no gate run at all
        fake, _ = fake_github(runs=[r for r in good_runs() if r[2] != "ReleaseGate.yml"])
        with_gh(() -> @test(notready(ready("o/P", 2), "`ReleaseGate.yml`: no run")), fake)
        # the PR itself
        for (kw, pattern) in ((; behind=2) => "2 commit(s) of `main` are missing", (; mergeable="CONFLICTING") => "conflicts",
                              (; mergeable="UNKNOWN") => "still computing", (; draft=true) => "draft", (; state="MERGED") => "merged")
            fake, _ = fake_github(; kw...)
            with_gh(() -> @test(notready(ready("o/P", 2), pattern)), fake)
        end
        # merge: release PRs only; the head changed between the check and the merge
        fake, merged = fake_github(branch="feature/x")
        with_gh(fake) do
            ok, msg = merge_release("o/P", 2; confirm=true)
            @test !ok && isempty(merged) && contains(msg, "release PRs only")
        end
        fake, merged = fake_github(merge_ok=false)
        with_gh(fake) do
            ok, msg = merge_release("o/P", 2; confirm=true)
            @test !ok && length(merged) == 1 && contains(msg, "refused")
        end
        # parsing
        @test gated_jobs(workflows["CI.yml"]) == [("test-cpu-github", ["run ci github-runner"]), ("test-gpu-kkt", ["run ci kkt-runner"]),
                                                  ("test-gpu-occidata", ["run ci occidata-runner"]), ("smoke", ["run ci github-runner"])]
        @test gated_jobs("on:\n  push:\njobs:\n  a:\n    runs-on: x\nenv:\n  b:\n    c: 1\n") == [("a", String[])]
        @test job_of("call / build", "call") && job_of("call (CTModels, stable) / break", "call") && job_of("smoke (ubuntu)", "smoke")
        @test job_of("smoke", "smoke") && !job_of("call-gpu / build", "call") && !job_of("smoker", "smoke")
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
        # `--labels-info` is a flag: the clone stays the only positional argument
        code, out = command("gate", "--base", "HEAD", "--labels", "", "--labels-info", dir)
        @test code == 0 && contains(out, "not a release")
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
