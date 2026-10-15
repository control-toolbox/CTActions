# envs.jl: environments built from the synthetic collected fixture.

@testset "envs" begin
    envs = build_envs(COLLECTED)

    @testset "names" begin
        # Beta has no docs/Project.toml
        @test sort(collect(keys(envs))) == ["Alpha/docs", "Alpha/test", "Beta/test", "joint"]
        @test envs["Alpha/test"]["owner"] == "Alpha" && envs["Alpha/test"]["kind"] == "test"
        @test envs["joint"]["owner"] == "" && envs["joint"]["kind"] == "joint"
    end

    @testset "joint" begin
        e = envs["joint"]
        @test sort(collect(keys(e["deps"]))) == ["Alpha", "Beta"]
        # every package is pinned; a prerelease is pinned without its suffix
        @test e["compat"] == Dict("Alpha" => "=0.3.1", "Beta" => "=1.2.0")
        @test e["pins"] == Dict("Alpha" => "0.3.1", "Beta" => "1.2.0-beta")
    end

    @testset "test env from test/Project.toml" begin
        e = envs["Alpha/test"]
        @test sort(collect(keys(e["deps"]))) == ["Alpha", "Test", "Tool"]
        # compat of a dep the file does not list is dropped; only the owner is pinned
        @test e["compat"] == Dict("Tool" => "1, 2", "Alpha" => "=0.3.1")
        @test e["pins"] == Dict("Alpha" => "0.3.1")
    end

    @testset "test env from [targets]" begin
        e = envs["Beta/test"]
        # [targets] test, not every [extras]: Unused is left out, the weak dep is in
        @test sort(collect(keys(e["deps"]))) == ["Beta", "Test", "Tool", "Weak"]
        @test e["deps"]["Weak"] == "44444444-0000-4000-8000-000000000004"
        # the package's own compat, restricted to those deps, plus julia
        @test e["compat"] == Dict("Tool" => "2", "Weak" => "0.1, 0.2", "julia" => "1.10", "Beta" => "=1.2.0")
        @test e["pins"] == Dict("Beta" => "1.2.0-beta")
    end

    @testset "docs env" begin
        e = envs["Alpha/docs"]
        # the package itself is added: docs/make.jl develops it
        @test sort(collect(keys(e["deps"]))) == ["Alpha", "Doc"]
        @test e["compat"] == Dict("Doc" => "0.9, 1", "Alpha" => "=0.3.1")
    end

    @testset "test env without [targets]" begin
        mktempdir() do dir
            write(joinpath(dir, "Project.toml"), """
                name = "Gamma"
                [extras]
                Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
                Aqua = "4c88cf16-eb10-579e-8560-4a9242c79595"
                [compat]
                Aqua = "0.8"
                """)
            deps, compat = test_env("Gamma", "u-g", dir)
            @test sort(collect(keys(deps))) == ["Aqua", "Gamma", "Test"]
            @test compat == Dict("Aqua" => "0.8")
        end
    end

    @testset "envs.toml round trip" begin
        mktempdir() do dir
            path = joinpath(dir, "envs.toml")
            open(io -> TOML.print(io, Dict("env" => envs)), path, "w")
            @test TOML.parsefile(path)["env"] == envs
        end
    end
end
