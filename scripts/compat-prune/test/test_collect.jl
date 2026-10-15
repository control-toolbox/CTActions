# collect.jl: files fetched from the registered tree and the default branch (fake `gh`).

"""
A fake GitHub: `repos` maps "owner/repo" to (default branch, Dict(treeish => Dict(path => text))).
Returns the runner and the vector of the calls it received.
"""
function fake_github(repos)
    calls = Vector{Vector{String}}()
    blobs = Dict{String,String}()
    function runner(args)
        push!(calls, args)
        @assert args[1] == "api"
        path = args[2]
        m = match(r"^repos/([^/]+/[^/]+)$", path)
        m === nothing || return repos[m[1]][1] * "\n"                       # --jq .default_branch
        m = match(r"^repos/([^/]+/[^/]+)/git/trees/([^?]+)\?recursive=1$", path)
        if m !== nothing
            files = repos[m[1]][2][m[2]]
            lines = String[]
            for (p, text) in sort(collect(files))
                sha = string(hash((m[1], m[2], p)); base=16)
                blobs[sha] = text
                push!(lines, "$p $sha")
            end
            return join(lines, "\n") * "\n"
        end
        m = match(r"^repos/[^/]+/[^/]+/git/blobs/(\w+)$", path)
        m === nothing || return blobs[m[1]]
        error("unexpected gh call: $args")
    end
    return runner, calls
end

@testset "collect" begin
    repos = Dict(
        "org/Alpha.jl" => ("main", Dict(
            "t-alpha" => Dict("Project.toml" => "name = \"Alpha\"\n", "test/Project.toml" => "[deps]\n",
                              "src/Alpha.jl" => "module Alpha end\n", "docs/make.jl" => ""),
            "main" => Dict("Project.toml" => "name = \"Alpha\"\nversion = \"0.3.2\"\n"),
        )),
        "org/Beta.jl" => ("dev", Dict(
            "t-beta" => Dict("Project.toml" => "name = \"Beta\"\n", "docs/Project.toml" => "[deps]\n"),
            "dev" => Dict("Project.toml" => "name = \"Beta\"\n", "docs/Project.toml" => "[deps]\n"),
        )),
    )
    runner, calls = fake_github(repos)
    mktempdir() do out
        index = with_gh(runner) do
            collect_files(out, Dict("Alpha" => ("u-a", "org/Alpha.jl"), "Beta" => ("u-b", "org/Beta.jl")),
                          Dict("Alpha" => "0.3.1", "Beta" => "1.2.0-beta"),
                          Dict("Alpha" => "t-alpha", "Beta" => "t-beta"))
        end
        @testset "index" begin
            @test index["Alpha"]["version"] == "0.3.1"
            @test index["Alpha"]["tree"] == "t-alpha"
            @test index["Alpha"]["default_branch"] == "main"
            @test index["Alpha"]["files"] == ["Project.toml", "test/Project.toml"]
            @test index["Alpha"]["default_files"] == ["Project.toml"]
            @test index["Beta"]["files"] == ["Project.toml", "docs/Project.toml"]
            @test index["Beta"]["default_branch"] == "dev"
            @test TOML.parsefile(joinpath(out, "index.toml"))["packages"] == index
        end
        @testset "files" begin
            # the registered tree and the default branch are kept apart
            @test read(joinpath(out, "registered", "Alpha", "Project.toml"), String) == "name = \"Alpha\"\n"
            @test read(joinpath(out, "default", "Alpha", "Project.toml"), String) ==
                  "name = \"Alpha\"\nversion = \"0.3.2\"\n"
            @test isfile(joinpath(out, "registered", "Alpha", "test", "Project.toml"))
            @test !isfile(joinpath(out, "default", "Alpha", "test", "Project.toml"))
            @test isfile(joinpath(out, "default", "Beta", "docs", "Project.toml"))
        end
        @testset "calls" begin
            # only the audited files are downloaded; the tree is read by its registered sha
            fetched = [c[2] for c in calls if occursin("/git/blobs/", c[2])]
            @test length(fetched) == 2 + 1 + 2 + 2
            @test any(c -> c[2] == "repos/org/Alpha.jl/git/trees/t-alpha?recursive=1", calls)
            @test any(c -> c[2] == "repos/org/Beta.jl/git/trees/dev?recursive=1", calls)
            # blobs are fetched raw
            @test all(c -> c[3:4] == ["-H", "Accept: application/vnd.github.raw"],
                      [c for c in calls if occursin("/git/blobs/", c[2])])
        end
    end

    @testset "fetch_files with no audited file" begin
        runner, _ = fake_github(Dict("org/Empty.jl" => ("main", Dict("t" => Dict("README.md" => "")))))
        mktempdir() do out
            @test with_gh(() -> fetch_files("org/Empty.jl", "t", out), runner) == String[]
            @test isempty(readdir(out))
        end
    end
end
