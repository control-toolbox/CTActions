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

using Test, TOML, Base64, Dates

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
        # nothing in progress, `main` kept an older number than the last release: the release is the registry's
        with_registries(Dict("General" => Dict("P" => ["0.4.2"]), "ct-registry" => Dict("P" => ["0.5.0-beta", "0.5.1-beta"]))) do
            with_gh(function (args)
                    a = join(args, " ")
                    contains(a, "contents/Project.toml") && return "name = \"P\"\nversion = \"0.4.2\"\n"
                    contains(a, "commits/main") && return "M\n"
                    contains(a, "issue list") && return ""
                    contains(a, "pr list -R o/P") && return ""
                    return nothing
                end) do
                @test facts("o/P").version == v"0.5.1-beta"
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

    @testset "audit" begin
        marker(n; v="0.4.3", kind="stable", state="done") =
            "<!-- ct-release phase=$n kind=$kind version=$v mode=autonomous pr=2 merge=M state=$state -->"
        comment(n; kw...) = (; author="a", time="2026-10-19T1$(n)", body="**Phase $n.**\n\n$(marker(n; kw...))")
        register_body = MENTION * " register\n\nRelease notes:\n\n### fix\n"
        "A stable release that went by the book: its facts and its trail."
        function done(; kind=:stable)
            v = kind === :stable ? v"0.4.3" : v"0.4.3-beta"
            f = (; repo="o/P", name="P", version=v, kind, main_version=v, main_sha="M",
                 issue=(; number=7, state="CLOSED"), issues=1, mentions=kind === :stable ? 1 : 0, bot_error=nothing,
                 pr=(; number=2, state="MERGED", merge="M", auto=false), tag="M", tag_tree="T",
                 release=kind === :beta, registry=kind === :stable ? "General" : "ct-registry", registered="T",
                 general_pr=kind === :stable ? (; number=9, state="MERGED") : nothing, jump=:none)
            vs = string(v)
            cs = Any[comment(2; v=vs, kind=string(kind)), comment(3; v=vs, kind=string(kind)), comment(4; v=vs, kind=string(kind)),
                     comment(5; v=vs, kind=string(kind)), comment(6; v=vs, kind=string(kind))]
            kind === :stable && push!(cs, (; author="a", time="x", body=register_body))
            push!(cs, comment(7; v=vs, kind=string(kind)))
            push!(cs, (; author="a", time="z", body="**Phase 8.**\n\n- ✅ Issue closed\n$(marker(8; v=vs, kind=string(kind)))"))
            t = (; issue_body="Release of P.", comments=cs, commit_comments=NamedTuple[],
                 pr=(; title="chore: prepare P release", body="Refs #7", files=["Project.toml", "CHANGELOG.md", "BREAKING.md"],
                     project_changes=["-version = \"0.4.2\"", "+version = \"0.4.3\""], auto_merge=false),
                 runs=Dict("ReleaseGate.yml" => "success", "CI.yml" => "success"),
                 release_body="## What's Changed", docs="success", branch_exists=false)
            return f, t
        end
        failed(f, t) = [(r.area, r.message) for r in audit_checks(f, t) if r.status === :fail]
        areas(f, t) = unique(first.(failed(f, t)))
        withfield(x, k, v) = merge(x, NamedTuple{(k,)}((v,)))
        # the comment kept, the mention comment removed, etc.
        without(t, pred) = withfield(t, :comments, [c for c in t.comments if !pred(c)])

        @testset "markers" begin
            ms = markers([(; author="a", time="t1", body="x\n<!-- ct-release phase=4 kind=stable version=0.4.3 mode=autonomous pr=2 merge=- state=done -->"),
                          (; author="a", time="t2", body="no marker"),
                          (; author="a", time="t3", body="<!-- ct-release kind=stable -->"),            # no phase: ignored
                          (; author="a", time="t4", body="<!-- ct-release phase=x kind=stable -->")])   # not a number: ignored
            @test length(ms) == 1 && ms[1].phase == 4 && ms[1].kind == "stable" && ms[1].version == "0.4.3" && ms[1].state == "done"
            @test built_by_the_tool(register_body)
            @test !built_by_the_tool(MENTION * " register")
            @test !built_by_the_tool("see " * register_body)
        end

        @testset "a release by the book" begin
            for kind in (:stable, :beta)
                f, t = done(; kind)
                @test isempty(failed(f, t))
                @test audit_report(f, audit_checks(f, t)) |> x -> contains(x, "✅ the trail is complete")
            end
        end

        @testset "state and issue" begin
            f, t = done()
            @test "state" in areas(withfield(f, :registered, nothing), t)               # not registered: not complete
            @test "state" in areas(withfield(f, :issue, (; number=7, state="OPEN")), t)
            @test "issue" in areas(withfield(f, :issue, (; number=7, state="OPEN")), t)
            @test "issue" in areas(withfield(f, :issues, 2), t)
            @test "issue" in areas(f, withfield(t, :issue_body, " \n"))
            @test "issue" in areas(f, withfield(t, :issue_body, "ask $MENTION"))
            @test ("issue", "no tracking issue `[RELEASE] v0.4.3`") in failed(withfield(f, :issue, nothing), t)
        end

        @testset "the trace" begin
            f, t = done()
            for n in 3:8                                                                 # a phase without a comment
                @test any(x -> x[1] == "trace" && contains(x[2], "no comment for phase $n"), failed(f, without(t, c -> contains(c.body, "phase=$n "))))
            end
            @test any(x -> contains(x[2], "no comment for phase 2"), failed(f, without(t, c -> contains(c.body, "phase=2 "))))
            @test isempty(failed(f, withfield(t, :comments, [comment(1; v="0.4.3"); t.comments[2:end]])))   # the proposal may be phase 1
            @test any(x -> contains(x[2], "out of order"), failed(f, withfield(t, :comments, t.comments[[2, 1, 3, 4, 5, 6, 7, 8]])))
            @test any(x -> contains(x[2], "another release"), failed(f, withfield(t, :comments, [comment(2; v="0.4.9"); t.comments[2:end]])))
            @test any(x -> contains(x[2], "another release"), failed(f, withfield(t, :comments, [comment(2; kind="beta"); t.comments[2:end]])))
            @test any(x -> contains(x[2], "not the final comment"), failed(f, withfield(t, :comments, [c for c in t.comments if !contains(c.body, "phase=8 ")])))
            @test any(x -> contains(x[2], "not the final comment"), failed(f, withfield(t, :comments, [t.comments[1:end-1]; comment(8; state="stopped")])))
            @test any(x -> contains(x[2], "❌"), failed(f, withfield(t, :comments, [t.comments[1:end-1]; (; author="a", time="z", body="- ❌ Checks\n$(marker(8))")])))
            @test isempty(failed(f, withfield(t, :comments, [t.comments[1:end-1]; comment(8)])))              # no list: only informs
            @test any(r -> r.status === :info && r.area == "trace", audit_checks(f, withfield(t, :comments, [t.comments[1:end-1]; comment(8)])))
            @test any(x -> contains(x[2], "no comment of the tracking issue"), failed(f, withfield(t, :comments, NamedTuple[])))
        end

        @testset "the registration" begin
            f, t = done()
            @test "registration" in areas(withfield(f, :mentions, 0), t)
            @test "registration" in areas(withfield(f, :mentions, 2), t)
            by_hand = withfield(t, :comments, [c.body == register_body ? (; author="a", time="x", body=MENTION * " register") : c for c in t.comments])
            @test any(x -> contains(x[2], "posted by hand"), failed(f, by_hand))
            # on the merge commit instead of the issue (main moved): the same form is required
            on_commit = withfield(without(t, c -> c.body == register_body), :commit_comments, [(; author="a", time="x", body=register_body)])
            @test isempty(failed(f, on_commit))
            @test any(x -> contains(x[2], "posted by hand"), failed(f, withfield(on_commit, :commit_comments, [(; author="a", time="x", body=MENTION * " register")])))
            # two comments with the mention: the count refuses, the form check does not crash
            two = withfield(t, :comments, [t.comments; (; author="a", time="y", body=MENTION * " register")])
            @test "registration" in areas(withfield(f, :mentions, 2), two) && !any(x -> contains(x[2], "posted by hand"), failed(withfield(f, :mentions, 2), two))
            @test !any(x -> contains(x[2], "posted by hand"), failed(f, two))
            # a bot's comment is not a mention of it: the one by hand is still seen
            botsaid = withfield(by_hand, :comments, [by_hand.comments; (; author="JuliaRegistrator", time="y", body="hello $MENTION")])
            @test any(x -> contains(x[2], "posted by hand"), failed(f, botsaid))
            # the bot's own answers are not mentions of it
            @test isempty(failed(f, withfield(t, :comments, [t.comments; (; author="JuliaRegistrator", time="y", body="hello $MENTION")])))
            @test "registration" in areas(f, withfield(t, :release_body, "register $MENTION"))
            @test "registration" in areas(f, withfield(t, :pr, withfield(t.pr, :body, "$MENTION")))
            @test "registration" in areas(f, withfield(t, :pr, withfield(t.pr, :title, "$MENTION")))
            fb, tb = done(; kind=:beta)                                                  # a beta never goes to the bot
            @test "registration" in areas(withfield(fb, :mentions, 1), tb)
            @test "registration" in areas(fb, withfield(tb, :comments, [tb.comments; (; author="a", time="x", body=register_body)]))
        end

        @testset "the release PR" begin
            f, t = done()
            @test "pr" in areas(withfield(f, :pr, withfield(f.pr, :state, "CLOSED")), t)
            @test "pr" in areas(f, withfield(t, :pr, withfield(t.pr, :auto_merge, true)))
            @test any(x -> contains(x[2], "src/A.jl"), failed(f, withfield(t, :pr, withfield(t.pr, :files, ["Project.toml", "src/A.jl"]))))
            @test isempty(failed(f, withfield(t, :pr, withfield(t.pr, :files, ["CHANGELOG.md", "BREAKING.md"]))))      # Project.toml may be absent
            @test "pr" in areas(f, withfield(t, :pr, withfield(t.pr, :project_changes, ["-version = \"0.4.2\"", "+version = \"0.4.3\"", "+Foo = \"1\""])))
            @test "pr" in areas(f, withfield(t, :pr, withfield(t.pr, :project_changes, ["-[compat]", "+version = \"0.4.3\""])))
            @test any(x -> contains(x[2], "cannot read"), failed(f, withfield(t, :pr, withfield(t.pr, :project_changes, String[]))))
            @test isempty(failed(f, withfield(t, :pr, merge(t.pr, (; files=["CHANGELOG.md"], project_changes=String[])))))
            @test any(x -> contains(x[2], "did not succeed"), failed(f, withfield(t, :runs, Dict("ReleaseGate.yml" => "success", "CI.yml" => "failure"))))
            @test any(x -> contains(x[2], "did not succeed"), failed(f, withfield(t, :runs, Dict("ReleaseGate.yml" => "cancelled"))))
            @test any(x -> contains(x[2], "did not run"), failed(f, withfield(t, :runs, Dict("CI.yml" => "success"))))
            @test any(x -> contains(x[2], "no workflow ran"), failed(f, withfield(t, :runs, Dict{String,String}())))
            @test ("pr", "no release PR `release/v0.4.3`") in failed(withfield(f, :pr, nothing), withfield(t, :pr, nothing))
        end

        @testset "the tag, the release and the registry" begin
            f, t = done()
            @test "tag" in areas(withfield(f, :tag, "X"), t)
            @test "tag" in areas(withfield(f, :release, nothing), t)
            @test "tag" in areas(withfield(f, :release, true), t)                          # a stable that is a pre-release
            @test "tag" in areas(f, withfield(t, :release_body, " "))
            @test isempty(failed(f, withfield(t, :docs, nothing)))                          # documentation: informs only
            @test isempty(failed(f, withfield(t, :docs, "failure")))
            @test count(r -> r.status === :info, audit_checks(f, withfield(t, :docs, "failure"))) == 1
            @test "registry" in areas(withfield(f, :registered, "OTHER"), t)
            @test "registry" in areas(withfield(f, :general_pr, nothing), t)
            @test "registry" in areas(withfield(f, :general_pr, (; number=9, state="OPEN")), t)
            fj = withfield(f, :jump, :betas)
            @test isempty(failed(fj, t)) && any(r -> r.status === :info && contains(r.message, "[merge approved]"), audit_checks(fj, t))
            @test any(r -> r.status === :info && contains(r.message, "no beta explains"), audit_checks(withfield(f, :jump, :unexplained), t))
        end

        @testset "the clean-up" begin
            f, t = done()
            @test "cleanup" in areas(f, withfield(t, :branch_exists, true))
        end

        @testset "trail, on a fake GitHub" begin
            b64(s) = join(String(c) for c in [base64encode(s)])
            gate_run = ".github/workflows/ReleaseGate.yml@refs/pull/2/merge\t11\t.github/workflows/ReleaseGate.yml@refs/pull/2/merge\tsuccess\n"
            fake = function (args)
                a = join(args, " ")
                contains(a, "issue view 7") && contains(a, "json body") && return b64("Release of P.") * "\n"
                contains(a, "issue view 7") && contains(a, "comments") && return "bob\t2026-10-19T11:00:00Z\t$(b64("hello\nworld"))\n"
                contains(a, "commits/M/comments") && return "bob\t2026-10-19T12:00:00Z\t$(b64("on the commit"))\n"
                contains(a, "headRefOid") && return "H\n"
                contains(a, "headRefName") && return "release/v0.4.3\n"
                contains(a, "title,body") && return "$(b64("a title"))\t$(b64("a body\nover lines"))\n"
                contains(a, "json files") && contains(a, ".files[].path") && return "Project.toml\nCHANGELOG.md\n"
                contains(a, "pulls/2/files") && return "@@ -1 +1 @@\n-version = \"0.4.2\"\n+version = \"0.4.3\"\n context\n"
                contains(a, "issues/2/events") && return events[]
                contains(a, "actions/runs?head_sha=H") && return gate_run * join((".github/workflows/CI.yml\t$x" for x in ("12\t.github/workflows/CI.yml\tfailure\n", "13\t.github/workflows/CI.yml\tsuccess\n", "14\t.github/workflows/CI.yml\tskipped\n"))) *
                    ".github/workflows/Release.yml\t15\t.github/workflows/Release.yml\tfailure\n"     # the release workflow: not a check
                contains(a, "release view") && return "notes\n"
                contains(a, "actions/runs?branch=v0.4.3") && return "success\n"
                contains(a, "git/ref/heads/release/v0.4.3") && return nothing
                return nothing
            end
            events = Ref("labeled\nauto_merge_enabled\n")
            f, _ = done()
            t = with_gh(() -> trail("o/P", f), fake)
            @test t.issue_body == "Release of P."
            @test t.comments == [(; author="bob", time="2026-10-19T11:00:00Z", body="hello\nworld")]
            @test t.commit_comments == [(; author="bob", time="2026-10-19T12:00:00Z", body="on the commit")]
            @test t.pr.title == "a title" && t.pr.body == "a body\nover lines"
            @test t.pr.files == ["Project.toml", "CHANGELOG.md"]
            @test t.pr.project_changes == ["-version = \"0.4.2\"", "+version = \"0.4.3\""]   # the lines that changed, not the context
            @test t.pr.auto_merge
            events[] = "labeled\nunlabeled\n"
            @test !with_gh(() -> trail("o/P", f), fake).pr.auto_merge
            @test t.runs == Dict("ReleaseGate.yml" => "success", "CI.yml" => "success")        # the latest real run of each
            @test t.release_body == "notes\n" && t.docs == "success" && !t.branch_exists
            # nothing found: empty values, not an error
            t = with_gh(() -> trail("o/P", f), _ -> nothing)
            @test t.issue_body == "" && isempty(t.comments) && isempty(t.commit_comments) && isempty(t.runs)
            @test t.pr.title == "" && isempty(t.pr.files) && !t.pr.auto_merge && t.release_body === nothing && t.docs === nothing
            # a branch that exists
            t = with_gh(() -> trail("o/P", f), a -> contains(join(a, " "), "git/ref/heads") ? "refs/heads/release/v0.4.3\n" : nothing)
            @test t.branch_exists
            # no issue, no PR
            fn = withfield(withfield(f, :issue, nothing), :pr, nothing)
            t = with_gh(() -> trail("o/P", fn), fake)
            @test t.issue_body == "" && isempty(t.comments) && t.pr === nothing && isempty(t.runs)
        end

        @testset "command line" begin
            @test command("audit")[1] == 2
            @test command("audit", "--repo", "o/P")[1] == 2
        end
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
                    return join((".github/workflows/$f\t$id\t.github/workflows/$f\t$st\t$c" for (id, f, st, c) in runs), "\n") * "\n"
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
        # the callers dispatched by label-dispatch.yml: the targets stand for the labels
        dispatched = "on:\n  workflow_dispatch:\n    inputs:\n      pr:\n      target:\njobs:\n" *
                     "  test-cpu-github:\n    if: github.event_name == 'push' || inputs.target == 'github'\n" *
                     "  test-gpu-kkt:\n    if: inputs.target == 'kkt'\n" *
                     "  call:\n    if: inputs.pr == '' || inputs.target == 'packages'\n"
        @test gated_jobs(dispatched) == [("test-cpu-github", ["run ci github-runner"]), ("test-gpu-kkt", ["run ci kkt-runner"]),
                                         ("call", ["run breakage"])]
        @test line_labels("if: inputs.target == 'unknown'") == String[]
        # its documentation has no guard: the input `preview` says what it is
        docs = "on:\n  workflow_dispatch:\n    inputs:\n      pr:\n      preview:\njobs:\n  call:\n    uses: x\n"
        @test gated_jobs(docs) == [("call", ["run documentation"])]
        @test gated_jobs("on:\n  push:\njobs:\n  call:\n    uses: x\n") == [("call", String[])]
        mktempdir() do d
            write(joinpath(d, "CI.yml"), dispatched)
            write(joinpath(d, "Documentation.yml"), docs)
            @test run_labels(d) == Set(["run ci github-runner", "run ci kkt-runner", "run breakage", "run documentation"])
        end
        # the runs of a pull request: its own events and the ones dispatched on its branch
        seen = String[]
        with_gh(a -> (push!(seen, join(a, " ")); "")) do
            pr_runs("o/P", "H", "release/v0.4.3", (".id", ".path"))
        end
        @test length(seen) == 1 && contains(seen[1], "actions/runs?head_sha=H") &&
              contains(seen[1], "workflow_dispatch") && contains(seen[1], "release/v0.4.3")
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

    @testset "finish: the plan" begin
        zero = repeat('0', 40)
        base = (; repo="o/P", name="P", version=v"0.4.3", kind=:stable, main_version=v"0.4.3", main_sha="M",
                issue=(; number=1, state="OPEN"), issues=1, mentions=0, bot_error=nothing,
                pr=(; number=2, state="OPEN", merge=nothing, auto=false), tag=nothing, tag_tree=nothing,
                release=nothing, registry="General", registered=nothing, general_pr=nothing, jump=:none)
        at(; kw...) = merge(base, (; kw...))
        merged = (; number=2, state="MERGED", merge="M", auto=false)
        green = (; ready=true, head="H", branch="release/v0.4.3", lines=[(; status=:pass, message="`CI.yml`, run 1: 3 job(s) passed")])
        waiting = (; ready=false, head="H", branch="release/v0.4.3", lines=[(; status=:wait, message="`CI.yml`: a run is in progress")])
        red = (; ready=false, head="H", branch="release/v0.4.3", lines=[(; status=:fail, message="`CI.yml`, run 1: `test` did not pass")])
        plan(f, r=nothing; ms=NamedTuple[], mode=:supervised) = finish_plan(f, phase(f), ms, r; mode)
        "The markers the comments of `p` leave, after `ms`."
        after(p, ms=NamedTuple[]) = vcat(ms, markers([(; author="b", time="t", body=c.body) for c in p.comments]))
        phases(p) = [c.phase for c in p.comments]

        # phase 4: ready → the phase comment, then the merge; supervised says where to approve
        p = plan(at(), green)
        @test p.action === :merge && phases(p) == [4]
        @test contains(only(p.comments).body, "Review deployments") && contains(only(p.comments).body, "phase=4 kind=stable version=0.4.3 mode=supervised pr=2 merge=- state=done")
        @test !contains(plan(at(), green; mode=:autonomous).comments[1].body, "Review deployments")
        # posted once: the next wake-up only merges
        p2 = plan(at(), green; ms=after(p))
        @test p2.action === :merge && isempty(p2.comments)
        # a run in progress: nothing, said nowhere
        p = plan(at(), waiting)
        @test p.action === :none && isempty(p.comments)
        # red: one stop comment, not repeated for the same reason, repeated for another
        p = plan(at(), red)
        @test p.action === :none && phases(p) == [4] && p.comments[1].state == "stopped"
        @test contains(p.comments[1].body, "❌ Checks green") && contains(p.comments[1].body, "`test` did not pass")
        @test isempty(plan(at(), red; ms=after(p)).comments)
        red2 = merge(red, (; head="H2"))
        @test phases(plan(at(), red2; ms=after(p))) == [4]
        # once green after a stop, the phase comment comes
        @test phases(plan(at(), green; ms=after(p))) == [4]
        # merged by a human, not tagged yet: the comments of 4 and 5, then wait for the tag
        p = plan(at(pr=merged))
        @test p.action === :none && phases(p) == [4, 5] && contains(p.comments[1].body, "merged before the workflow saw")
        # tagged and released: 4 to 6, then the registration comment (stable)
        f7 = at(pr=merged, tag="M", tag_tree=zero, release=false)
        p = plan(f7)
        @test p.action === :register && phases(p) == [4, 5, 6]
        @test isempty(plan(f7; ms=after(p)).comments)
        # `main` moved: never automatic, a person is asked, once
        p = plan(at(pr=merged, tag="M", tag_tree=zero, release=false, main_sha="N"))
        @test p.action === :none && phases(p) == [4, 5, 6, 7] && p.comments[end].state == "waiting"
        @test contains(p.comments[end].body, "--on-commit")
        @test isempty(plan(at(pr=merged, tag="M", tag_tree=zero, release=false, main_sha="N"); ms=after(p)).comments)
        # posted, waiting for the bot or General: nothing
        p = plan(at(pr=merged, tag="M", tag_tree=zero, release=false, mentions=1); ms=after(plan(f7)))
        @test p.action === :none && isempty(p.comments)
        # a jump over betas: `[merge approved]` is asked of a person, never posted
        p = plan(at(pr=merged, tag="M", tag_tree=zero, release=false, mentions=1, general_pr=(; number=9, state="OPEN"), jump=:betas))
        @test p.action === :none && p.comments[end].state == "waiting" && contains(p.comments[end].body, "[merge approved]")
        # a beta: ct-registry
        b = at(version=v"0.4.3-beta", kind=:beta, registry="ct-registry", pr=merged, tag="M", tag_tree=zero, release=true)
        p = plan(b)
        @test p.action === :register_beta && phases(p) == [4, 5, 6] && !contains(p.comments[1].body, "REL4")
        # registered: 4 to 7, the final comment, the close; the markers in the order the audit checks
        f8 = at(pr=merged, tag="M", tag_tree=zero, release=false, mentions=1, registered=zero,
                general_pr=(; number=9, state="MERGED"))
        p = plan(f8; mode=:autonomous)
        @test p.action === :close && phases(p) == [4, 5, 6, 7, 8]
        ms = after(p)
        @test [m.phase for m in ms] == [4, 5, 6, 7, 8] && last(ms).state == "done"
        final = p.comments[end].body
        @test !contains(final, "❌") && count("✅", final) == 8 && contains(final, "JuliaRegistries/General#9, merged")
        @test !contains(final, MENTION)
        # the final comment posted, the close failed: the next wake-up closes, without a second comment
        p = plan(f8; ms)
        @test p.action === :close && isempty(p.comments)
        @test plan(at(pr=merged, tag="M", tag_tree=zero, release=false, registered=zero, issue=(; number=1, state="CLOSED"))).action === :none
        # blocked: a stop, at the phase status names
        p = plan(at(pr=merged, tag="M", tag_tree=zero, release=false, registered="U"))
        @test p.action === :none && p.comments[end].state == "stopped" && p.comments[end].phase == 8
        @test plan(at(pr=(; number=2, state="CLOSED", merge=nothing, auto=false))).comments[end].phase == 3
        # phases 0 to 3 are not the workflow's
        @test plan(at(pr=nothing)).action === :none && isempty(plan(at(pr=nothing)).comments)
        # REL6: no text of the workflow mentions the bot
        for f in (at(), f7, b, f8), r in (green, red, nothing), mode in (:supervised, :autonomous)
            @test all(c -> !contains(c.body, MENTION), plan(f, f.pr.state == "OPEN" ? r : nothing; mode).comments)
        end
    end

    @testset "finish: the opt-in" begin
        function fake(; cross=false, branch="release/v0.4.3", labels="run ci github-runner,release: supervised", actor="ocots", role="admin")
            return function (args)
                a = join(args, " ")
                contains(a, "pr view 2") && return "$cross\t$branch\t$labels\n"
                contains(a, "issues/2/events") && return actor === nothing ? "" : "someone\n$actor\n"
                contains(a, "collaborators/") && return role === nothing ? nothing : "$role\n"
                return nothing
            end
        end
        opt(managers="ocots"; kw...) = with_gh(() -> optin("o/P", 2, managers), fake(; kw...))
        @test opt() == (; mode=:supervised, actor="ocots", reason="")
        @test opt(labels="release: autonomous").mode === :autonomous
        @test opt("alice, OCots").mode === :supervised                # several managers, case-insensitive
        @test opt(role="maintain").mode === :supervised
        @test contains(opt(cross=true).reason, "fork")
        @test contains(opt(branch="feat/x").reason, "release/v")
        @test contains(opt(labels="run ci github-runner").reason, "no label")
        @test contains(opt(labels="release: supervised,release: autonomous").reason, "both")
        @test contains(opt(actor="mallory").reason, "not a release manager")
        @test contains(opt(actor=nothing).reason, "cannot tell")
        @test contains(opt(role="write").reason, "not admin or maintain")
        @test contains(opt(role=nothing).reason, "unknown")
        @test contains(opt("").reason, "CT_RELEASE_MANAGERS")
        @test managers_list(" a,B  c ") == ["a", "b", "c"]
    end

    @testset "finish: a wake-up, on a fake GitHub" begin
        zero = repeat('0', 40)
        "A GitHub where P v0.4.3 is registered in General, its issue #7 still open: the close is left."
        function github(; labels="release: autonomous", pr_state="MERGED")
            st = Dict{Symbol,Any}(:comments => String[], :open => true, :deleted => false)
            fake = function (args)
                a = join(args, " ")
                contains(a, "contents/Project.toml") && return "name = \"P\"\nversion = \"0.4.3\"\n"
                contains(a, "commits/main") && return "M\n"
                contains(a, "issue list") && contains(a, "--state open") && return st[:open] ? "[RELEASE] v0.4.3\n" : ""
                contains(a, "issue list") && return st[:open] ? "7 OPEN\n" : "7 CLOSED\n"
                contains(a, "issue view") && contains(a, "body,comments") && return "1\n"
                contains(a, "issue view") && contains(a, "JuliaRegistrator") &&
                    return "Registration pull request created: [JuliaRegistries/General/9](https://github.com/JuliaRegistries/General/pull/9)\n"
                contains(a, "pr list -R o/P") && return "2 $pr_state M false\n"
                contains(a, "pr view 9 -R JuliaRegistries/General") && return "MERGED\n"
                contains(a, "pr view 2") && contains(a, "isCrossRepository") && return "false\trelease/v0.4.3\t$labels\n"
                contains(a, "issues/2/events") && return "ocots\n"
                contains(a, "collaborators/ocots/permission") && return "admin\n"
                contains(a, "commits/v") && contains(a, "tree") && return "$zero\n"
                contains(a, "commits/v") && return "M\n"
                contains(a, "release view") && contains(a, "isPrerelease") && return "false\n"
                if contains(a, "issues/7/comments")
                    if "-F" in args
                        push!(st[:comments], read(replace(args[findfirst(==("-F"), args) + 1], "body=@" => ""), String))
                        return "https://github.com/o/P/issues/7#issuecomment-$(length(st[:comments]))\n"
                    end
                    return join(("b\tt\t$(base64encode(c))\n" for c in st[:comments]))
                end
                contains(a, "--method DELETE") && contains(a, "heads/release/v0.4.3") && (st[:deleted] = true; return "")
                contains(a, "--method PATCH") && contains(a, "issues/7") && (st[:open] = false; return "closed\n")
                return nothing
            end
            return fake, st
        end
        with_registries(Dict("General" => Dict("P" => ["0.4.2", "0.4.3"]))) do
            fake, st = github()
            with_gh(fake) do
                # the job of the environment does nothing that is not the next action
                r = finish("o/P"; managers="ocots", act=:merge)
                @test r.ok && r.action === :none && isempty(st[:comments]) && contains(r.report, "now `close`")
                r = finish("o/P"; managers="ocots")
                @test r.mode === :autonomous && r.action === :none && !st[:open] && st[:deleted]
                ms = markers([(; author="b", time="t", body=c) for c in st[:comments]])
                @test [m.phase for m in ms] == [4, 5, 6, 7, 8]
                # the phases 2 and 3 were not the workflow's, and this fake shows the audit no trail: it fails, said on the issue
                @test !r.ok && contains(r.report, "Release audit") && contains(last(st[:comments]), "## Release audit")
                @test !contains(last(st[:comments]), "<!-- ct-release")         # not a phase comment: the final one stays the last
                n = length(st[:comments])
                # closed: the next wake-up does nothing
                r = finish("o/P"; managers="ocots")
                @test r.ok && r.action === :none && length(st[:comments]) == n && contains(r.report, "no release in progress")
            end
            # no opt-in, or by someone else: nothing, nothing posted
            for (labels, managers) in (("run ci github-runner", "ocots"), ("release: supervised", "alice"))
                fake, st = github(; labels)
                with_gh(fake) do
                    r = finish("o/P"; managers)
                    @test r.ok && r.action === :none && isempty(st[:comments]) && st[:open]
                end
            end
        end
    end

    @testset "register-beta, on a fake GitHub" begin
        zero = repeat('0', 40)
        regs = Dict("ct-registry" => Dict("P" => ["0.4.2-beta"]))
        fake = function (args)
            a = join(args, " ")
            contains(a, "contents/Project.toml") && return "name = \"P\"\nversion = \"0.4.3-beta\"\n"
            contains(a, "commits/main") && return "M\n"
            contains(a, "issue list") && return "7 OPEN\n"
            contains(a, "issue view") && contains(a, "body,comments") && return "0\n"
            contains(a, "issue view") && return ""
            contains(a, "pr list -R o/P") && return "2 MERGED M false\n"
            contains(a, "commits/v") && contains(a, "tree") && return "$zero\n"
            contains(a, "commits/v") && return "M\n"
            contains(a, "release view") && contains(a, "isPrerelease") && return "true\n"
            contains(a, "commits/M/comments") && return contains(a, "length") ? "0\n" : ""
            return nothing
        end
        ran = Cmd[]
        real = RUN[]
        RUN[] = function (cmd)
            push!(ran, cmd)
            # LocalRegistry pushed: ct-registry now holds the beta, at the tree of the tag
            "--startup-file=no" in cmd.exec && push!(regs["ct-registry"]["P"], "0.4.3-beta")
            return true
        end
        try
            with_registries(regs) do
                with_gh(fake) do
                    ok, msg = register_beta("o/P", v"0.4.3")
                    @test !ok && contains(msg, "stable")
                    ok, msg = register_beta("o/P", v"0.4.3-beta")                   # dry run
                    @test ok && isempty(ran) && contains(msg, "Dry run")
                    ok, msg = register_beta("o/P", v"0.4.3-beta"; confirm=true, pause=0)
                    @test ok && length(ran) == 4 && contains(msg, "at the tree of the tag")
                    @test "M" in ran[2].exec && any(contains("ct-registry"), ran[3].exec)
                    @test any(contains("LocalRegistry"), ran[4].exec)
                    # ensure: registered, nothing is run again
                    ok, msg = register_beta("o/P", v"0.4.3-beta"; confirm=true, pause=0)
                    @test ok && length(ran) == 4 && contains(msg, "nothing to do")
                end
            end
            # a step fails: reported, nothing checked
            empty!(ran); regs["ct-registry"]["P"] = ["0.4.2-beta"]
            RUN[] = cmd -> (push!(ran, cmd); length(ran) < 3)
            with_registries(regs) do
                with_gh(fake) do
                    ok, msg = register_beta("o/P", v"0.4.3-beta"; confirm=true, pause=0)
                    @test !ok && length(ran) == 3 && contains(msg, "failed")
                end
            end
            # pushed, but the registry never shows it
            RUN[] = cmd -> true
            with_registries(regs) do
                with_gh(fake) do
                    ok, msg = register_beta("o/P", v"0.4.3-beta"; confirm=true, tries=2, pause=0)
                    @test !ok && contains(msg, "after 2 reads")
                end
            end
        finally
            RUN[] = real
        end
    end

    @testset "facts and the request (phases 0 and 1)" begin
        "A package `Pkg` 0.4.2, tagged, then merged PRs on `main`: what `candidates` must find."
        function history()
            dir = mktempdir()
            g = "git -c user.name=t -c user.email=t@t"
            project(deps, compat) = "name = \"Pkg\"\nuuid = \"$PKG_UUID\"\nversion = \"0.4.2\"\n\n[deps]\n$deps\n[compat]\n$compat"
            write(joinpath(dir, "Project.toml"), project("", "julia = \"1.10\"\n"))
            write(joinpath(dir, "CHANGELOG.md"), changelog("0.4.2" => "- first."))
            write(joinpath(dir, "BREAKING.md"), "# Breaking\n\n## Non-breaking note (0.4.2)\n\n- none.\n")
            mkpath(joinpath(dir, "src")); write(joinpath(dir, "src", "Pkg.jl"), "module Pkg\nexport foo, bar\npublic baz\nend\n")
            sh(dir, "git init -q -b main && $g add -A && $g commit -qm init && git tag v0.4.2")
            pr(n, title, cmd) = sh(dir, "git checkout -q -b b$n && $cmd && $g add -A && $g commit -qm '$title' && git checkout -q main && " *
                                        "$g merge -q --no-ff b$n -m 'Merge pull request #$n from o/b$n' -m '$title'")
            pr(10, "fix: cited by number", "echo '# a' >> src/a.jl")
            pr(11, "fix: closes an issue", "echo '# b' >> src/b.jl")
            pr(12, "feat: not cited (#7)", "echo '# c' >> src/c.jl")
            pr(13, "ci: nothing shipped", "mkdir -p .github && echo x > .github/x.yml")
            pr(14, "chore: bar is gone", "printf 'module Pkg\\nexport foo\\npublic baz\\nend\\n' > src/Pkg.jl")
            write(joinpath(dir, "Project.toml"), project("Example = \"$EXAMPLE\"\n", "Example = \"0.5\"\njulia = \"1.10, 1.11\"\n"))
            sh(dir, "$g commit -qam 'deps: Example (#15)'")
            write(joinpath(dir, "BREAKING.md"), "# Breaking\n\n## Non-breaking note (Unreleased)\n\n- none.\n\n## Non-breaking note (0.4.2)\n\n- none.\n")
            write(joinpath(dir, "CHANGELOG.md"), "# Changelog\n\n## [Unreleased]\n\n### 🐛 Bug Fixes\n\n- a fix ([#10](https://x/pull/10)); another (#5).\n\n### ✅ Compatibility\n\n- No breaking changes.\n\n" *
                  split(read(joinpath(dir, "CHANGELOG.md"), String), "## [Unreleased]\n\n")[2])
            sh(dir, "$g commit -qam 'docs: changelog'")
            return dir
        end
        dir = history()
        changelog_text = read(joinpath(dir, "CHANGELOG.md"), String)
        c = candidates(dir, "v0.4.2", "main", changelog_text; closing=n -> n == 11 ? [5] : Int[])
        ids = [x.id for x in c.review]
        @test "pr-12" in ids && !("pr-10" in ids) && !("pr-11" in ids)        # cited by number, by the issue it closes
        @test "pr-14" in ids && "pr-15" in ids                                # a squash `… (#15)` is a PR too
        @test [x.id for x in c.unshipped] == ["pr-13"]                        # CI only: for information, no verdict
        @test "export-bar" in ids && !("export-foo" in ids) && !("export-baz" in ids)
        @test "dep-Example" in ids && "compat-Example" in ids && "compat-julia" in ids
        @test contains(only(x for x in c.review if x.id == "pr-12").what, "touches src")
        # the same history gives the same list: every agent reviews the same candidates
        @test c == candidates(dir, "v0.4.2", "main", changelog_text; closing=n -> n == 11 ? [5] : Int[])

        @test gpu_choice(["a", "run ci kkt-runner", "run ci occidata-runner"], r -> r == "kkt") == ["a", "run ci kkt-runner"]
        @test gpu_choice(["a", "run ci kkt-runner", "run ci occidata-runner"], r -> r == "occidata") == ["a", "run ci occidata-runner"]
        @test gpu_choice(["a", "run ci kkt-runner", "run ci occidata-runner"], r -> false) == ["a", "run ci kkt-runner"]
        @test gpu_choice(["a", "run ci occidata-runner"], r -> false) == ["a", "run ci occidata-runner"]

        # the facts, the skeleton, the request: the version is the gate's, every candidate needs a verdict
        with_registries(Dict("General" => Dict("Pkg" => ["0.4.2"]))) do
            with_gh(args -> nothing) do
                f = release_facts(dir, "o/Pkg"; kind=:stable, base="main", resolution=false)
                @test f.expected == v"0.4.3" && f.reference == v"0.4.2" && !f.breaking && !isempty(f.rel7)
                @test Set(x.id for x in f.candidates) == union(Set(ids), Set(["pr-11"]))   # gh gives no closing issue here
                toml, md = request_paths(f.expected)
                mkpath(joinpath(dir, ".releases"))
                write(joinpath(dir, toml), request_skeleton(f))
                r = TOML.parsefile(joinpath(dir, toml))
                @test r["release"]["version"] == "0.4.3" && r["facts"]["expected_version"] == "0.4.3"
                @test length(r["review"]) == length(f.candidates) && all(x -> x["verdict"] == "", r["review"])
                problems = check_request(dir, toml; repo="o/Pkg", base="main")
                @test any(contains("mode"), problems) && any(contains("requested_by"), problems)
                @test any(contains("proposal"), problems) && any(contains("no verdict"), problems) == false
                @test count(contains("the verdict is ``"), problems) == length(f.candidates)
                # completed: nothing left
                s = read(joinpath(dir, toml), String)
                s = replace(s, "mode = \"\"" => "mode = \"supervised\"", "requested_by = \"\"" => "requested_by = \"ocots\"",
                            r"verdict = \"\"[^\n]*" => "verdict = \"covered\"", "note = \"\"" => "note = \"see the changelog\"")
                write(joinpath(dir, toml), s)
                write(joinpath(dir, md), "## Release proposal — Pkg v0.4.3 (stable)\n")
                @test isempty(check_request(dir, toml; repo="o/Pkg", base="main"))
                # the format of [Unreleased] broken: the request is refused until it is fixed
                cl = read(joinpath(dir, "CHANGELOG.md"), String)
                write(joinpath(dir, "CHANGELOG.md"), replace(cl, "### 🐛 Bug Fixes" => "### Fixed"; count=1))
                @test any(contains("format of `[Unreleased]`: `### Fixed`"), check_request(dir, toml; repo="o/Pkg", base="main"))
                write(joinpath(dir, "CHANGELOG.md"), cl)
                # a candidate left without a note, another version, the bot mentioned: refused
                write(joinpath(dir, toml), replace(s, "note = \"see the changelog\"" => "note = \"\""; count=1))
                @test any(contains("has no note"), check_request(dir, toml; repo="o/Pkg", base="main"))
                write(joinpath(dir, toml), replace(s, "version = \"0.4.3\"" => "version = \"0.5.0\""; count=1))
                @test !isempty(check_request(dir, toml; repo="o/Pkg", base="main"))
                write(joinpath(dir, toml), s)
                write(joinpath(dir, md), "ask $MENTION\n")
                @test any(contains("REL6"), check_request(dir, toml; repo="o/Pkg", base="main"))
                # `main` moved after the request
                write(joinpath(dir, md), "proposal\n")
                sh(dir, "echo '# d' >> src/d.jl && git -c user.name=t -c user.email=t@t add src && git -c user.name=t -c user.email=t@t commit -qm 'fix: d (#16)'")
                @test any(contains("`main` moved"), check_request(dir, toml; repo="o/Pkg", base="main"))
            end
        end
    end

    @testset "the release commit and the CI of main (phase 3)" begin
        dir = mktempdir()
        write(joinpath(dir, "Project.toml"), "name = \"P\"\nversion = \"0.8.17-beta\"\n\n[compat]\nversion = \"1\"\n")
        write(joinpath(dir, "CHANGELOG.md"), "# Changelog\n\n## [Unreleased]\n\n### 🐛 Bug Fixes\n\n- x.\n\n## [0.9.5-beta] - 2026-08-31\n\n- y.\n")
        write(joinpath(dir, "BREAKING.md"), "# Breaking\n\n## Unreleased\n\n- z.\n\n## Non-breaking note (Unreleased)\n\n- w.\n")
        @test sort(apply_release!(dir, v"0.9.6", Date(2026, 11, 12))) == ["BREAKING.md", "CHANGELOG.md", "Project.toml"]
        p = read(joinpath(dir, "Project.toml"), String)
        @test contains(p, "version = \"0.9.6\"") && contains(p, "[compat]\nversion = \"1\"")      # the first line only
        c = read(joinpath(dir, "CHANGELOG.md"), String)
        @test contains(c, "## [Unreleased]\n\n## [0.9.6] - 2026-11-12\n\n### 🐛 Bug Fixes")
        @test !any(contains("Unreleased"), check_changelog(c, v"0.9.6"))       # an empty `[Unreleased]` on top
        b = read(joinpath(dir, "BREAKING.md"), String)
        @test contains(b, "## [0.9.6] - 2026-11-12") && contains(b, "Non-breaking note (0.9.6)") && names_version(b, v"0.9.6")
        @test isempty(apply_release!(dir, v"0.9.6", Date(2026, 11, 13)))                        # done once: nothing again

        runs(lines...) = args -> (a = join(args, " "); contains(a, "actions/runs?head_sha=S") ? join(lines, "\n") : nothing)
        @test with_gh(() -> main_state("o/P", "S"), runs("1\t.github/workflows/CI.yml\tcompleted\tsuccess",
                      "2\t.github/workflows/Documentation.yml\tcompleted\tskipped")).state === :green
        @test with_gh(() -> main_state("o/P", "S"), runs("1\t.github/workflows/CI.yml\tin_progress\tnull")).state === :waiting
        m = with_gh(() -> main_state("o/P", "S"), runs("1\t.github/workflows/CI.yml\tcompleted\tfailure",
                    "3\t.github/workflows/Coverage.yml\tcompleted\tfailure", "4\t.github/workflows/Coverage.yml\tcompleted\tsuccess"))
        @test m.state === :red && m.failed == ["CI.yml"]                      # the latest run of each workflow counts
    end

    @testset "finish: phase 3, a release the workflow started" begin
        base = (; repo="o/P", name="P", version=v"0.9.6", kind=:stable, main_version=v"0.8.17-beta", main_sha="M",
                issue=(; number=1, state="OPEN"), issues=1, mentions=0, bot_error=nothing, pr=nothing, tag=nothing,
                tag_tree=nothing, release=nothing, registry="General", registered=nothing, general_pr=nothing, jump=:betas)
        two = markers([(; author="b", time="t", body="**Phase 2.**\n<!-- ct-release phase=2 kind=stable version=0.9.6 mode=supervised pr=- merge=- state=done by=ocots base=B -->")])
        @test only(two).by == "ocots" && only(two).base == "B" && only(two).mode == "supervised"
        plan(main; ms=two, requester=nothing) = finish_plan(base, phase(base), ms, nothing; mode=:supervised, main, requester)
        @test plan((; state=:green, failed=String[])).action === :start
        p = plan((; state=:waiting, failed=String[]))
        @test p.action === :none && isempty(p.comments)
        p = plan((; state=:red, failed=["CI.yml"]))
        @test p.action === :none && p.comments[end].phase == 3 && contains(p.comments[end].body, "`CI.yml`")
        @test isempty(plan((; state=:red, failed=["CI.yml"]); ms=vcat(two, markers([(; author="b", time="t", body=p.comments[end].body)]))).comments)
        p = plan((; state=:green, failed=String[]); requester="@x is not a release manager")
        @test p.action === :none && contains(p.comments[end].body, "not a release manager")
        # a release PR the workflow did not start: phases 0 to 3 stay the agent's
        @test plan((; state=:green, failed=String[]); ms=NamedTuple[]).action === :none
        # the label of the App is an opt-in
        fake(args) = (a = join(args, " "); contains(a, "pr view 2") ? "false\trelease/v0.9.6\trelease: supervised\n" :
                      contains(a, "issues/2/events") ? "$RELEASE_BOT\n" : nothing)
        @test with_gh(() -> optin("o/P", 2, "ocots"), fake) == (; mode=:supervised, actor=RELEASE_BOT, reason="")
    end

    @testset "safety: what was found wrong once" begin
        # `ready` without the list of the workflows required nothing: it said ready
        fake(args) = (a = join(args, " ");
            contains(a, "pr view") ? "OPEN\tfalse\tH\trelease/v0.4.3\tMERGEABLE\tbug\n" :
            contains(a, "compare/main...H") ? "0\n" : contains(a, "actions/runs?head_sha=H") ? "" : nothing)
        r = with_gh(() -> ready("o/P", 2), fake)
        @test !r.ready && any(l -> contains(l.message, "cannot read the workflows"), r.lines)
        # the gate is required even when the listing does not show it
        fake2(args) = (a = join(args, " "); contains(a, "contents/.github/workflows?ref=H") ? "SpellCheck.yml\n" : fake(args))
        r = with_gh(() -> ready("o/P", 2), fake2)
        @test !r.ready && any(l -> contains(l.message, "`ReleaseGate.yml`: no run"), r.lines)
        # the release workflow's own run is not a check: in progress, it does not keep `ready` waiting
        lines(rs) = join(("$p\t$i\t$p\t$s\t$c" for (i, p, s, c) in rs), "\n") * "\n"
        fake3(args) = (a = join(args, " ");
            contains(a, "contents/.github/workflows?ref=H") ? "ReleaseGate.yml\nRelease.yml\n" :
            contains(a, "contents/.github/workflows/") ? "jobs:\n  call:\n    uses: x\n" :
            contains(a, "actions/runs?head_sha=H") ? lines([(1, ".github/workflows/ReleaseGate.yml", "completed", "success"),
                                                            (2, ".github/workflows/Release.yml", "in_progress", "")]) :
            contains(a, "runs/1/jobs") ? "call / gate\tsuccess\n" : fake(args))
        r = with_gh(() -> ready("o/P", 2), fake3)
        @test r.ready && !any(l -> contains(l.message, "Release.yml"), r.lines)
        @test is_release_workflow(".github/workflows/Release.yml@refs/heads/main") && !is_release_workflow(".github/workflows/ReleaseGate.yml")
        # no run on `main` yet (seconds after a push) is not green
        @test with_gh(() -> main_state("o/P", "S"), args -> "").state === :waiting
        # the base of the CI of `main` is the request's, not the phase-2 comment's: a request
        # updated after `main` moved has a new base whose CI may still run (CTParser 0.9.6)
        req(body) = args -> (a = join(args, " "); contains(a, "contents/.releases/v0.9.6.toml?ref=release/v0.9.6") ? body : nothing)
        @test with_gh(() -> request_base("o/P", v"0.9.6"), req("[release]\nbase = \"S2\"\n")) == "S2"
        @test with_gh(() -> request_base("o/P", v"0.9.6"), req("[release]\nversion = \"0.9.6\"\n")) === nothing
        @test with_gh(() -> request_base("o/P", v"0.9.6"), req("not = toml = at all")) === nothing
        @test with_gh(() -> request_base("o/P", v"0.9.6"), args -> nothing) === nothing
        # a stable after breaking betas: the triple after the betas, never a bump of the last beta (CTParser 0.9.6, not 0.10.0)
        released = [v"0.8.15", v"0.9.0-beta", v"0.9.1-beta", v"0.9.5-beta"]
        @test expected_version(:stable, released; breaking=true, feature=true) == v"0.9.6"
        @test expected_version(:beta, released; breaking=true, feature=false) == v"0.10.0-beta"
    end

    @testset "finish_plan: properties over every combination of facts" begin
        zero = repeat('0', 40)
        prs = [nothing, (; number=2, state="OPEN", merge=nothing, auto=false), (; number=2, state="MERGED", merge="M", auto=false),
               (; number=2, state="CLOSED", merge=nothing, auto=false)]
        readies = [nothing, (; ready=true, head="H", branch="b", lines=[(; status=:pass, message="ok")]),
                   (; ready=false, head="H", branch="b", lines=[(; status=:wait, message="running")]),
                   (; ready=false, head="H", branch="b", lines=[(; status=:fail, message="red")])]
        mains = [nothing, (; state=:green, failed=String[]), (; state=:waiting, failed=String[]), (; state=:red, failed=["CI.yml"])]
        two = markers([(; author="b", time="t", body="<!-- ct-release phase=2 kind=stable version=0.4.3 mode=supervised pr=- merge=- state=done by=ocots base=B -->")])
        n = 0
        for kind in (:stable, :beta), pr in prs, tag in (nothing, "M", "X"), release in (nothing, true, false),
            registered in (nothing, zero, "U"), mentions in (0, 1, 2), main_sha in ("M", "N"),
            general in (nothing, (; number=9, state="OPEN"), (; number=9, state="MERGED")), jump in (:none, :betas),
            mode in (:supervised, :autonomous), ms0 in (NamedTuple[], two)
            kind === :beta && (general !== nothing || mentions > 0 || jump !== :none) && continue
            f = (; repo="o/P", name="P", version=kind === :beta ? v"0.4.3-beta" : v"0.4.3", kind, main_version=v"0.4.3", main_sha,
                 issue=(; number=1, state="OPEN"), issues=1, mentions, bot_error=nothing, pr, tag, tag_tree=tag === nothing ? nothing : zero,
                 release, registry=kind === :beta ? "ct-registry" : "General", registered, general_pr=general, jump)
            p = phase(f)
            for r in (pr !== nothing && pr.state == "OPEN" ? readies : [nothing]), main in mains, requester in (nothing, "no")
                plan = finish_plan(f, p, ms0, r; mode, main, requester)
                n += 1
                # REL6: no text of the workflow mentions the bot
                @test all(c -> !contains(c.body, MENTION), plan.comments)
                # a privileged action only when the facts call for it
                plan.action === :merge && @test(p.phase == 4 && r !== nothing && r.ready)
                plan.action === :start && @test(p.phase == 3 && pr === nothing && requester === nothing && main.state === :green)
                plan.action === :register && @test(kind === :stable && p.phase == 7 && p.state === :todo && !get(p, :on_commit, false))
                plan.action === :register_beta && @test(kind === :beta && p.phase == 7 && p.state === :todo)
                plan.action === :close && @test(p.phase == 8 && p.state === :todo)
                p.state === :blocked && @test(plan.action === :none)
                # ensure: the same facts with the comments posted post nothing again, and decide the same
                again = finish_plan(f, p, vcat(ms0, markers([(; author="b", time="t", body=c.body) for c in plan.comments])), r; mode, main, requester)
                @test isempty(again.comments) && again.action === plan.action
                # the markers stay in the order the audit checks
                ph = [m.phase for m in markers([(; author="b", time="t", body=c.body) for c in plan.comments])]
                @test issorted(ph)
            end
        end
        @test n > 10_000
    end

    @testset "the workflow: who holds the powers" begin
        wf = read(joinpath(@__DIR__, "..", "..", "..", ".github", "workflows", "release.yml"), String)
        # the jobs, as blocks of text
        body = split(wf, r"^jobs:\n"m)[2]
        jobs = Dict(m[1] => m[2] for m in eachmatch(r"^  ([a-z-]+):\n((?:(?!^  [a-z-]+:\n)[\s\S])*)"m, body))
        @test Set(keys(jobs)) == Set(["step", "start", "merge", "register"])
        for (name, text) in jobs
            app = contains(text, "create-github-app-token") || contains(text, "secrets.")
            # the App's key, or any secret, only in a job of an environment; never in `step`
            app && @test(contains(text, "    environment: "))
            name == "step" && @test(!app && !contains(text, "environment:"))
            # the queues: never cancelled
            @test contains(text, "cancel-in-progress: false")
            # a privileged job runs only for its action
            name != "step" && @test(contains(text, "needs.step.outputs.action == '$(name == "register" ? "register" : name)'"))
        end
        @test !contains(wf, "pull_request_target")
        # the caller documented inherits the secrets: the environments' secrets reach the jobs only so
        doc = read(joinpath(@__DIR__, "..", "..", "..", "docs", "workflows", "release.md"), String)
        caller = match(r"# \.github/workflows/Release\.yml\n([\s\S]*?)```", doc)
        @test caller !== nothing && contains(caller[1], "    secrets: inherit\n")
        @test contains(jobs["step"], "head.repo.full_name == github.repository")          # never from a fork
        # the environment follows the mode, with a reviewer by default
        @test count("inputs.autonomous_environment || inputs.environment", wf) == 3
        @test contains(wf, "default: release\n")
    end

    if any(r -> r.name == GENERAL, Pkg.Registry.reachable_registries())
    @testset "a release from its request to its checks, on a simulated GitHub" begin
        # a package released as 0.4.2, then a fix merged; its GitHub is a bare repository (the
        # pushes) and a fake with a state: issues, comments, PRs, labels and their events, runs
        root = mktempdir()
        dir = joinpath(root, "agent"); mkpath(dir)
        origin = joinpath(root, "origin.git")
        g = "git -c user.name=t -c user.email=t@t"
        write(joinpath(dir, "Project.toml"), "name = \"Pkg\"\nuuid = \"$PKG_UUID\"\nversion = \"0.4.2\"\n\n[compat]\njulia = \"1.10\"\n")
        write(joinpath(dir, "CHANGELOG.md"), changelog("0.4.2" => "- first."))
        write(joinpath(dir, "BREAKING.md"), "# Breaking\n\n## Non-breaking note (0.4.2)\n\n- none.\n")
        mkpath(joinpath(dir, "src")); write(joinpath(dir, "src", "Pkg.jl"), "module Pkg end\n")
        mkpath(joinpath(dir, ".github", "workflows"))
        write(joinpath(dir, ".github", "workflows", "CI.yml"), "jobs:\n  test:\n    if: contains(github.event.pull_request.labels.*.name, 'run ci github-runner')\n")
        sh(dir, "git init -q -b main && $g add -A && $g commit -qm init && git tag v0.4.2")
        sh(dir, "git checkout -q -b fix && echo '# fix' >> src/Pkg.jl && $g commit -qam fix && git checkout -q main && $g merge -q --no-ff fix -m 'Merge pull request #10 from o/fix' -m 'fix: a fix'")
        write(joinpath(dir, "CHANGELOG.md"), replace(read(joinpath(dir, "CHANGELOG.md"), String), "## [Unreleased]\n\n" =>
              "## [Unreleased]\n\n### 🐛 Bug Fixes\n\n- a fix ([#10](https://x/pull/10)).\n\n### ✅ Compatibility\n\n- nothing to do.\n\n"))
        write(joinpath(dir, "BREAKING.md"), "# Breaking\n\n## Non-breaking note (Unreleased)\n\n- none.\n\n## Non-breaking note (0.4.2)\n\n- none.\n")
        sh(dir, "$g commit -qam 'docs: changelog'")
        sh(root, "git clone -q --bare agent origin.git")
        sh(dir, "git remote add origin $origin && git fetch -q origin")
        base = strip(read(`git -C $origin rev-parse main`, String))

        st = Dict{Symbol,Any}(:issues => Dict{Int,String}(), :comments => Dict{Int,Vector{String}}(), :prs => Dict{Int,Vector{String}}(),
                              :next => 7, :log => String[], :dispatched => String[], :main => "in_progress", :head_runs => "in_progress", :lag => 0)
        role(login) = login == "ocots" ? "admin\n" : login == "writer" ? "write\n" : nothing
        b64(s) = base64encode(s)
        file_arg(args, flag) = (i = findfirst(==(flag), args); read(replace(args[i + 1], r"^body=@" => ""), String))
        function fake(args)
            a = join(args, " ")
            if contains(a, "workflow run Release.yml")
                push!(st[:dispatched], a); return ""
            end
            contains(a, "contents/Project.toml?ref=main") && return read(`git -C $origin show main:Project.toml`, String)
            contains(a, "commits/main") && return strip(read(`git -C $origin rev-parse main`, String)) * "\n"
            contains(a, "commits/v") && return nothing                                  # no tag v0.4.3
            contains(a, "release view") && return nothing
            # the lists lag behind a new issue (seen on the first real run), the REST list does not
            contains(a, "issues?labels=release") && return join(("$n\t$t\n" for (n, t) in st[:issues]))
            if contains(a, "issue list")
                st[:lag] > 0 && (st[:lag] -= 1; return "")
                contains(a, "--state open") && return join(("$t\n" for (_, t) in st[:issues]))
                return join(("$n OPEN\n" for (n, _) in st[:issues]))
            end
            contains(a, "issue view") && contains(a, "body,comments") && return "0\n"
            contains(a, "issue view") && return ""
            contains(a, "pr list -R JuliaRegistries/General") && return ""
            if contains(a, "pr list -R o/Pkg")
                contains(a, "--head") && return join(("$n OPEN - false\n" for (n, _) in st[:prs]))
                return join(("release/v0.4.3\n" for _ in st[:prs]))
            end
            m = match(r"collaborators/([^/]+)/permission", a); m !== nothing && return role(m[1])
            contains(a, "closingIssuesReferences") && return ""
            contains(a, "actions/runners") && return "0\n"
            # issues
            if length(args) >= 2 && args[2] == "repos/o/Pkg/issues" && "-f" in args
                n = st[:next]; st[:next] += 1
                st[:issues][n] = replace(args[findfirst(startswith("title="), args)], "title=" => "")
                st[:comments][n] = String[]
                push!(st[:log], "issue $n"); return "$n\n"
            end
            m = match(r"repos/o/Pkg/issues/(\d+)/comments", a)
            if m !== nothing
                n = parse(Int, m[1])
                if "-F" in args
                    push!(st[:comments][n], file_arg(args, "-F")); return "https://x/issues/$n#c$(length(st[:comments][n]))\n"
                end
                return join(("b\tt\t$(b64(c))\n" for c in st[:comments][n]))
            end
            # pull requests
            if length(args) >= 2 && args[2] == "repos/o/Pkg/pulls"
                n = st[:next]; st[:next] += 1
                st[:prs][n] = String[]; push!(st[:log], "pr $n"); return "$n\n"
            end
            m = match(r"--method PATCH repos/o/Pkg/pulls/(\d+) -f state=(\w+)", a)
            m !== nothing && (push!(st[:log], "pr $(m[1]) $(m[2])"); return "")
            m = match(r"repos/o/Pkg/issues/(\d+)/labels", a)
            if m !== nothing
                ls = [replace(x, "labels[]=" => "") for x in args if startswith(x, "labels[]=")]
                append!(st[:prs][parse(Int, m[1])], ls); push!(st[:log], "labels $(join(ls, ","))"); return ""
            end
            m = match(r"pr view (\d+)", a)
            if m !== nothing
                ls = join(st[:prs][parse(Int, m[1])], ",")
                contains(a, "isCrossRepository") && return "false\trelease/v0.4.3\t$ls\n"
                contains(a, "state,isDraft") && return "OPEN\tfalse\tH\trelease/v0.4.3\tMERGEABLE\t$ls\n"
                contains(a, "--json labels") && return "$ls\n"
            end
            contains(a, "/events") && return "$RELEASE_BOT\n"
            # the request, on its branch: the base whose CI the release PR waits for
            contains(a, "contents/.releases/v0.4.3.toml?ref=release/v0.4.3") && return read(joinpath(dir, ".releases", "v0.4.3.toml"), String)
            # the CI of main, at the base of the request; the checks of the PR, at its head
            contains(a, "actions/runs?head_sha=$base") && return "1\t.github/workflows/CI.yml\t$(st[:main])\t$(st[:main] == "completed" ? "success" : "null")\n"
            contains(a, "compare/main...H") && return "0\n"
            contains(a, "contents/.github/workflows?ref=H") && return "CI.yml\nReleaseGate.yml\n"
            contains(a, "contents/.github/workflows/") && return "jobs:\n  call:\n    uses: x\n"
            contains(a, "actions/runs?head_sha=H") && return ".github/workflows/ReleaseGate.yml\t5\t.github/workflows/ReleaseGate.yml\t$(st[:head_runs])\tnull\n"
            return nothing
        end
        comments() = only(values(st[:comments]))
        phases() = [m.phase for m in markers([(; author="b", time="t", body=c) for c in comments()])]
        withenv("GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@t", "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@t") do
        with_registries(Dict("General" => Dict("Pkg" => ["0.4.2"]))) do
        with_gh(fake) do
            # phases 0 and 1, the agent: the facts, the review, the request
            f = release_facts(dir, "o/Pkg"; kind=:stable, resolution=false)
            @test f.expected == v"0.4.3" && isempty(f.candidates)
            toml, md = request_paths(f.expected)
            mkpath(joinpath(dir, ".releases"))
            write(joinpath(dir, toml), replace(request_skeleton(f), "mode = \"\"" => "mode = \"supervised\"", "requested_by = \"\"" => "requested_by = \"ocots\""))
            write(joinpath(dir, md), "## Release proposal — Pkg v0.4.3 (stable)\n")
            ok, msg = request_release(dir, toml; repo="o/Pkg")
            @test !ok && contains(msg, "`release/v0.4.3`")                                  # not on the release branch
            sh(dir, "git checkout -q -b release/v0.4.3")
            ok, msg = request_release(dir, toml; repo="o/Pkg")
            @test ok && only(st[:dispatched]) == "workflow run Release.yml -R o/Pkg --ref main -f version=0.4.3"
            pushed = strip(read(`git -C $origin rev-parse release/v0.4.3`, String))
            @test occursin(toml, read(`git -C $origin show --name-only --format= $pushed`, String))
            ok, _ = request_release(dir, toml; repo="o/Pkg")                                  # again: nothing new committed
            @test ok && strip(read(`git -C $origin rev-parse release/v0.4.3`, String)) == pushed

            # phase 2, the run started with the version: only a release manager starts a release
            wf = joinpath(root, "workflow")
            sh(root, "git clone -q $origin workflow && git -C workflow checkout -q release/v0.4.3")
            for who in ("mallory", "writer")
                r = finish("o/Pkg"; managers="ocots,writer", version="0.4.3", actor=who, dir=wf)
                @test !r.ok && r.action === :none && isempty(st[:issues])
            end
            r = finish("o/Pkg"; managers="ocots", version="0.4.3", actor="ocots", dir=wf)
            @test r.ok && length(st[:issues]) == 1 && only(values(st[:issues])) == "[RELEASE] v0.4.3"
            two = only(markers([(; author="b", time="t", body=c) for c in comments()]))
            @test two.phase == 2 && two.by == "ocots" && two.base == base && two.mode == "supervised"
            @test r.action === :none && contains(r.report, "waiting for the CI of `main`")     # main still running
            # started twice: no second issue, no second comment
            r = finish("o/Pkg"; managers="ocots", version="0.4.3", actor="ocots", dir=wf)
            @test r.ok && length(st[:issues]) == 1 && length(comments()) == 1
            # started again while the lists lag behind the issue: the REST list sees it, still one
            st[:lag] = 10
            r = finish("o/Pkg"; managers="ocots", version="0.4.3", actor="ocots", dir=wf)
            @test r.ok && length(st[:issues]) == 1 && length(comments()) == 1
            st[:lag] = 0

            # phase 3: once main is green, the job of the environment opens the PR
            st[:main] = "completed"
            r = finish("o/Pkg"; managers="ocots")
            @test r.action === :start && r.mode === :supervised && r.version == v"0.4.3"
            r = finish("o/Pkg"; managers="ocots", act=:start, dir=wf)
            @test r.ok
            head = strip(read(`git -C $origin rev-parse release/v0.4.3`, String))
            @test head != pushed && contains(read(`git -C $origin show $head:Project.toml`, String), "version = \"0.4.3\"")
            @test contains(read(`git -C $origin show $head:CHANGELOG.md`, String), "## [Unreleased]\n\n## [0.4.3] - ")
            pr = only(keys(st[:prs]))
            # the PR opened, closed, labelled, reopened: one run per workflow; then the label of the mode
            @test st[:log][2:end] == ["pr $pr", "pr $pr closed", "labels run ci github-runner", "pr $pr open", "labels release: supervised"]
            @test phases() == [2, 3] && !any(c -> contains(c, MENTION), comments())
            # again: nothing more — no commit, no PR, no comment, no label
            log = copy(st[:log])
            @test finish("o/Pkg"; managers="ocots", act=:start, dir=wf).action === :none
            @test first(start("o/Pkg", wf; version="0.4.3"))
            @test st[:log] == log && phases() == [2, 3] && strip(read(`git -C $origin rev-parse release/v0.4.3`, String)) == head

            # phase 4: the label of the App is the opt-in; the checks run, nothing to do yet
            r = finish("o/Pkg"; managers="ocots")
            @test r.ok && r.action === :none && contains(r.report, "waiting for the checks") && phases() == [2, 3]
            st[:head_runs] = "completed"
            r = finish("o/Pkg"; managers="ocots")
            # the checks green: the comment of phase 4, and the merge is the job of the environment's
            @test r.action === :merge && phases() == [2, 3, 4] && contains(last(comments()), "Review deployments")
            @test finish("o/Pkg"; managers="ocots").action === :merge && phases() == [2, 3, 4]   # asked again, posted once
        end
        end
        end
    end
    end

    @testset "the format of [Unreleased]: what the version is read from" begin
        cl(body; rest="## [0.4.2] - 2026-10-18\n\n### 🐛 Bug Fixes\n\n- old.\n") = "# Changelog\n\n## [Unreleased]\n\n$body\n$rest"
        good = cl("### 💥 Breaking Changes\n\n- `f` removed.\n\n### 🐛 Bug Fixes\n\n- x.\n\n### ✅ Compatibility\n\n- **Breaking**: see BREAKING.md.\n")
        breaking = "# Breaking\n\n## Unreleased\n\n- `f` removed.\n"
        @test isempty(unreleased_format(good, breaking))
        @test isempty(unreleased_format(cl("### 🐛 Bug Fixes\n\n- x.\n\n### ✅ Compatibility\n\n- No breaking changes.\n"),
                                        "# Breaking\n\n## Non-breaking note (Unreleased)\n\n- none.\n"))
        has(text, br, pattern) = any(contains(pattern), unreleased_format(text, br))
        # a breaking section not named as CHG2 says: the version would be read as not breaking
        bad = replace(good, "### 💥 Breaking Changes" => "### Breaking")
        @test has(bad, breaking, "`### Breaking` is not a section of CHG2")
        @test !changes_since(bad, v"0.4.2").breaking                    # what it would have cost
        @test has(replace(good, "## [Unreleased]" => "## Unreleased"), breaking, "`## [Unreleased]`")
        @test isempty(unreleased_format(cl(""), "# Breaking\n"))                 # empty, as after a release
        @test has(cl("- loose.\n"), breaking, "no `###` subsection")
        @test has(cl("### 🐛 Bug Fixes\n\n- x.\n\n### 💥 Breaking Changes\n\n- y.\n\n### ✅ Compatibility\n\n- b.\n"), breaking, "not in the order")
        @test has(cl("### 🐛 Bug Fixes\n\n- x.\n"), breaking, "`### ✅ Compatibility` is not the last")
        @test has(cl("- loose.\n\n### 🐛 Bug Fixes\n\n- x.\n\n### ✅ Compatibility\n\n- c.\n"), breaking, "text before the first `###`")
        @test has(cl("### 🐛 Bug Fixes\n\n- x.\n\n### 🐛 Bug Fixes\n\n- y.\n\n### ✅ Compatibility\n\n- c.\n"), breaking, "appears twice")
        @test has(replace(good, "- **Breaking**: see BREAKING.md." => "- No breaking changes."), breaking, "says no breaking change")
        @test has(good, "# Breaking\n\n## [0.4.2]\n", "no `## Unreleased` entry")       # CHG3
        @test has(good, nothing, "no `BREAKING.md`")
        @test has(cl("### 🐛 Bug Fixes\n\n- x.\n\n### ✅ Compatibility\n\n- c.\n"), "# Breaking\n", "neither `## Unreleased` nor")   # CHG4
        @test isempty(unreleased_format(good, replace(breaking, "## Unreleased" => "## [Unreleased]")))
        # an older entry is not checked (it is never edited), but a heading the tool cannot read
        # right below [Unreleased] would merge that entry into it: said, and only that
        p = unreleased_format(cl("### 🐛 Bug Fixes\n\n- x.\n\n### ✅ Compatibility\n\n- c.\n"; rest="## 0.4.2\n\n### Fixed\n\n- old.\n"),
                              "# Breaking\n\n## Non-breaking note (Unreleased)\n")
        @test only(p) == "the heading after `## [Unreleased]`, `## 0.4.2`, is not `## [X.Y.Z] - YYYY-MM-DD`: its entries would be read as unreleased"
        @test isempty(unreleased_format(cl("### 🐛 Bug Fixes\n\n- x.\n\n### ✅ Compatibility\n\n- c.\n"; rest="## [0.4.2]\n\n### Fixed\n\n- old.\n"),
                                        "# Breaking\n\n## Non-breaking note (Unreleased)\n"))
        # the linter, alone and in the gate of a PR that is not a release
        dir, base = package_repo()
        sh(dir, "git checkout -q main")
        @test isempty(changelog_lint(dir))
        write(joinpath(dir, "CHANGELOG.md"), replace(read(joinpath(dir, "CHANGELOG.md"), String), "## [Unreleased]\n\n" => "## [Unreleased]\n\n### Fixed\n\n- x.\n\n"))
        @test any(contains("`### Fixed`"), changelog_lint(dir))
        code, out = command("lint-changelog", dir)
        @test code == 1 && contains(out, "`### Fixed` is not a section of CHG2")
        sh(dir, "git -c user.name=t -c user.email=t@t commit -qam 'docs: an entry'")
        r = gate(dir, base; labels=String[], resolution=false)
        @test any(x -> x.status === :info && x.rule == "CHG2" && contains(x.message, "`### Fixed`"), r)
        @test !any(x -> x.status === :fail, r)                          # information only: not a release
        @test first(command("lint-changelog", mktempdir())) == 0          # no changelog: nothing to say
        # the words of a break, filed elsewhere: candidates, never under 💥, 🧪 or ✅
        w = wording_candidates(cl("### 💥 Breaking Changes\n\n- `f` removed.\n\n### 🐛 Bug Fixes\n\n- `g` is no longer exported.\n- fine.\n\n" *
                                  "### 🔄 Refactoring\n\n- `h` renamed `k`.\n\n### 🧪 Testing\n\n- a test removed.\n\n### ✅ Compatibility\n\n- breaking.\n"))
        @test length(w) == 2 && all(x -> occursin(r"^wording-[0-9a-f]{8}$", x.id), w)
        @test contains(w[1].what, "`### 🐛 Bug Fixes`, “no longer”") && contains(w[2].what, "“renamed”")
        # stable ids: an entry added elsewhere does not change them
        w2 = wording_candidates(cl("### 💥 Breaking Changes\n\n- `f` removed.\n\n### 🐛 Bug Fixes\n\n- new one.\n- `g` is no longer exported.\n- fine.\n\n" *
                                   "### 🔄 Refactoring\n\n- `h` renamed `k`.\n\n### ✅ Compatibility\n\n- breaking.\n"))
        @test [x.id for x in w2] == [x.id for x in w]
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
