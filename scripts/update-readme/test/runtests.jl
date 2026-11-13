# Tests of the README generation (scripts/update-readme/render.jl).
#
# usage: julia scripts/update-readme/test/runtests.jl

using Test

include(joinpath(@__DIR__, "..", "render.jl"))

const KW = (package="Pkg", repo="org/Pkg.jl", doc_url="https://doc.example/Pkg.jl")

@testset "update-readme" begin
    @testset "shared texts replace their marker line" begin
        template = "# T\n<!-- INCLUDE_ABOUT -->\nmid\n<!-- INCLUDE_INSTALL -->\n<!-- INCLUDE_CONTRIBUTING -->\nend\n"
        readme, contributing = render(template, "about\n", "add {{PACKAGE}}\n", "see {{REPO}}\n"; KW...)
        @test readme == "# T\nabout\nmid\nadd Pkg\nsee org/Pkg.jl\nend\n"
        @test contributing == "see org/Pkg.jl\n"
    end

    @testset "a text without final newline does not glue the next line" begin
        readme, _ = render("<!-- INCLUDE_ABOUT -->\nnext\n", "about", "", ""; KW...)
        @test readme == "about\nnext\n"
    end

    @testset "no badge marker: no table" begin
        readme, _ = render("# T\n", "", "", ""; KW...)
        @test !occursin("Category", readme)
    end

    @testset "badge table follows the listed order, spaces or commas" begin
        readme, _ = render("<!-- INCLUDE_BADGES: Release, CI License -->\n", "", "", ""; KW...)
        rows = split(readme, "\n"; keepempty=false)
        @test rows[1] == "| **Category** | **Badge** |"
        @test length(rows) == 5
        @test startswith(rows[3], "| **Release / Version** |")
        @test startswith(rows[4], "| **CI / Build** |")
        @test startswith(rows[5], "| **License** |")
        @test occursin("https://github.com/org/Pkg.jl/actions/workflows/CI.yml", rows[4])
    end

    @testset "citation only when given; unknown category ignored" begin
        t = "<!-- INCLUDE_BADGES: Citation,Nonsense -->\n"
        readme, _ = render(t, "", "", ""; KW...)
        @test length(split(readme, "\n"; keepempty=false)) == 2
        readme, _ = render(t, "", "", ""; citation="[doi]", KW...)
        @test occursin("| **Citation** | [doi] |", readme)
    end

    @testset "values with sed metacharacters are kept as they are" begin
        readme, _ = render("<!-- INCLUDE_INSTALL -->\n", "", "{{PACKAGE}}\n", ""; KW..., package="A&B|C")
        @test readme == "A&B|C\n"
    end

    @testset "command line" begin
        mktempdir() do dir
            write(joinpath(dir, "t.md"), "<!-- INCLUDE_ABOUT -->\n<!-- INCLUDE_CONTRIBUTING -->\n")
            write(joinpath(dir, "ABOUT.md"), "about\n")
            write(joinpath(dir, "INSTALL.md"), "")
            write(joinpath(dir, "CONTRIBUTING.md"), "{{REPO}}\n")
            cd(dir) do
                main(["--template", "t.md", "--output", "R.md", "--package", "P", "--repo", "o/P.jl", "--doc-url", "u"])
            end
            @test read(joinpath(dir, "R.md"), String) == "about\no/P.jl\n"
            @test read(joinpath(dir, "CONTRIBUTING.md"), String) == "o/P.jl\n"
            @test_throws ErrorException main(["--template", "t.md"])
        end
    end
end
