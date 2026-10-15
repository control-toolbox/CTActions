# edit.jl: textual edit of one [compat] line; outcome of each prune against a checkout.

const PROJECT = """
name = "Pkg"
uuid = "aaaaaaaa-0000-4000-8000-000000000001"
version = "0.6.1"

[deps]
CUDSS = "45b445bb-4962-46a0-9369-b4df9d0f772e"
JET = "c3a54625-cd67-489e-a8e7-0a5a0ff4e31b"
JETLS = "ffffffff-0000-4000-8000-00000000000f"

[compat]
CUDSS = "0.6, 0.7, 0.8"
JET = "0.9, 0.11, 0.12"
JETLS = "0.9, 0.11"
julia = "1.10"

[extras]
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
"""

"`text` with line `old` replaced by `new`, asserting it was there."
function swap(text, old, new)
    @assert occursin(old, text) old
    replace(text, old => new)
end

@testset "edit" begin
    @testset "edits the value and nothing else" begin
        out, status, detail = edit_compat(PROJECT, "JET", "0.9, 0.11, 0.12", "0.9, 0.12")
        @test status == "edited" && detail == ""
        @test out == swap(PROJECT, "JET = \"0.9, 0.11, 0.12\"", "JET = \"0.9, 0.12\"")
        # a key that only starts with the same name is not touched
        @test occursin("JETLS = \"0.9, 0.11\"", out)
    end

    @testset "layout is preserved" begin
        cases = [
            "JET = \"0.9, 0.11, 0.12\"  # kept for Julia 1.10" => "JET = \"0.9, 0.12\"  # kept for Julia 1.10",
            "JET   =   \"0.9, 0.11, 0.12\"" => "JET   =   \"0.9, 0.12\"",
            "  JET = \"0.9, 0.11, 0.12\"" => "  JET = \"0.9, 0.12\"",
            "JET = '0.9, 0.11, 0.12'" => "JET = '0.9, 0.12'",
            "\"JET\" = \"0.9, 0.11, 0.12\"" => "\"JET\" = \"0.9, 0.12\"",
        ]
        for (old, new) in cases
            text = swap(PROJECT, "JET = \"0.9, 0.11, 0.12\"", old)
            out, status, _ = edit_compat(text, "JET", "0.9, 0.11, 0.12", "0.9, 0.12")
            @test status == "edited"
            @test out == swap(text, old, new)
        end
    end

    @testset "CRLF line endings are kept" begin
        text = replace(PROJECT, "\n" => "\r\n")
        out, status, _ = edit_compat(text, "CUDSS", "0.6, 0.7, 0.8", "0.7, 0.8")
        @test status == "edited"
        @test out == replace(swap(PROJECT, "CUDSS = \"0.6, 0.7, 0.8\"", "CUDSS = \"0.7, 0.8\""), "\n" => "\r\n")
    end

    @testset "spacing inside the value does not matter" begin
        text = swap(PROJECT, "CUDSS = \"0.6, 0.7, 0.8\"", "CUDSS = \"0.6,0.7,  0.8\"")
        out, status, _ = edit_compat(text, "CUDSS", "0.6, 0.7, 0.8", "0.7, 0.8")
        @test status == "edited" && occursin("CUDSS = \"0.7, 0.8\"", out)
    end

    @testset "only the [compat] section is read" begin
        # same key in [deps] (a uuid) and in an [extras]-like section after [compat]
        text = PROJECT * "\n[sources]\nJET = {path = \"../JET\"}\n"
        out, status, _ = edit_compat(text, "JET", "0.9, 0.11, 0.12", "0.9, 0.12")
        @test status == "edited"
        @test occursin("JET = \"c3a54625-cd67-489e-a8e7-0a5a0ff4e31b\"", out)
        @test occursin("JET = {path = \"../JET\"}", out)
        # a [compat] entry declared only after a nested table header is not mistaken
        text = swap(PROJECT, "[compat]", "[compat.extra]")
        @test edit_compat(text, "JET", "0.9, 0.11, 0.12", "0.9, 0.12")[2] == "drift"
    end

    @testset "already, drift" begin
        text = swap(PROJECT, "JET = \"0.9, 0.11, 0.12\"", "JET = \"0.9, 0.12\"")
        out, status, detail = edit_compat(text, "JET", "0.9, 0.11, 0.12", "0.9, 0.12")
        @test status == "already" && out == text && occursin("0.9, 0.12", detail)
        # the branch moved the entry elsewhere
        text = swap(PROJECT, "JET = \"0.9, 0.11, 0.12\"", "JET = \"0.12\"")
        out, status, detail = edit_compat(text, "JET", "0.9, 0.11, 0.12", "0.9, 0.12")
        @test status == "drift" && out == text
        @test detail == "`0.12` on the default branch, `0.9, 0.11, 0.12` audited"
        # the entry is gone
        text = swap(PROJECT, "JET = \"0.9, 0.11, 0.12\"\n", "")
        out, status, detail = edit_compat(text, "JET", "0.9, 0.11, 0.12", "0.9, 0.12")
        @test status == "drift" && out == text && occursin("no `JET` entry", detail)
        # no [compat] at all
        @test edit_compat("name = \"X\"\n", "JET", "0.9", "0.12")[2] == "drift"
    end

    @testset "check_edit" begin
        edited = swap(PROJECT, "JET = \"0.9, 0.11, 0.12\"", "JET = \"0.9, 0.12\"")
        @test check_edit(PROJECT, edited, "JET", "0.9, 0.12") === nothing
        @test_throws ErrorException check_edit(PROJECT, swap(edited, "0.6.1", "0.6.0"), "JET", "0.9, 0.12")
        @test_throws ErrorException check_edit(PROJECT, edited, "JET", "0.12")
    end

    @testset "plan_edits" begin
        files = Dict(("Pkg", "Project.toml") => PROJECT,
                     ("Pkg", "docs/Project.toml") => "[compat]\nJET = \"0.12\"\n")
        read_file(owner, file) = get(files, (owner, file), nothing)
        audit = Dict("prune" => [
            prune("Pkg", "Project.toml", "JET", "0.9, 0.11, 0.12", "0.9, 0.12"),
            prune("Pkg", "Project.toml", "CUDSS", "0.6, 0.7, 0.8", "0.7, 0.8"),   # same file, accumulated
            prune("Pkg", "docs/Project.toml", "JET", "0.11, 0.12", "0.12"),        # already
            prune("Pkg", "test/Project.toml", "JET", "0.11, 0.12", "0.12"),        # no such file
            prune("Pkg", "Project.toml", "JETLS", "0.8, 0.9, 0.11", "0.11"),       # drift: the branch has "0.9, 0.11"
        ])
        records, texts = plan_edits(audit, read_file)
        status = Dict(entry_key(r) => r["status"] for r in records)
        @test status[("Pkg", "Project.toml", "JET")] == "edited"
        @test status[("Pkg", "Project.toml", "CUDSS")] == "edited"
        @test status[("Pkg", "docs/Project.toml", "JET")] == "already"
        @test status[("Pkg", "test/Project.toml", "JET")] == "drift"
        @test status[("Pkg", "Project.toml", "JETLS")] == "drift"
        @test collect(keys(texts)) == [("Pkg", "Project.toml")]
        out = texts[("Pkg", "Project.toml")]
        @test out == swap(swap(PROJECT, "JET = \"0.9, 0.11, 0.12\"", "JET = \"0.9, 0.12\""),
                          "CUDSS = \"0.6, 0.7, 0.8\"", "CUDSS = \"0.7, 0.8\"")
        # the version line is never touched (regression: copying a collected file reverted it)
        @test occursin("version = \"0.6.1\"", out)
    end

    @testset "against the fixture's default branches" begin
        audit = Dict("prune" => [
            prune("Alpha", "Project.toml", "Dep1", "0.5, 0.6, 0.7", "0.6, 0.7"),
            prune("Beta", "Project.toml", "Dep1", "0.6, 0.7", "0.7"),
            prune("Alpha", "docs/Project.toml", "Doc", "0.9, 1", "1"),
        ])
        records, texts = plan_edits(audit, read_checkout(joinpath(COLLECTED, "default")))
        status = Dict(entry_key(r) => r["status"] for r in records)
        # the default branch bumped the version and commented the line: still edited, both kept
        @test status[("Alpha", "Project.toml", "Dep1")] == "edited"
        out = texts[("Alpha", "Project.toml")]
        @test occursin("version = \"0.3.2\"", out)
        @test occursin("Dep1 = \"0.6, 0.7\"  # lanes kept by CompatHelper", out)
        # Beta's default branch already dropped 0.6
        @test status[("Beta", "Project.toml", "Dep1")] == "already"
        @test status[("Alpha", "docs/Project.toml", "Doc")] == "edited"
    end

    @testset "read_checkout" begin
        r = read_checkout(joinpath(COLLECTED, "default"))
        @test startswith(r("Alpha", "Project.toml"), "name = \"Alpha\"")
        @test r("Alpha", "test/Project.toml") === nothing
        @test r("Nope", "Project.toml") === nothing
    end
end
