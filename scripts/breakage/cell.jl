# One cell of the breakage suite: a downstream package, at one version, tested (or its
# documentation built) against the package under test, and its result written as a file
# that report.jl reads.
#
# usage: julia cell.jl --name NAME --owner OWNER --break test|doc --version latest|stable|REF
#                      --source DIR --out DIR [--job URL]
#
# The package is cloned from github.com/OWNER/NAME.jl into a temporary directory and
# checked out at: its default branch (`latest`), its newest `v*` tag (`stable`), or REF.
# Then, in a Julia of its own, `Pkg.develop` puts the package under test (SOURCE) in its
# environment (`.` for `test`, `docs` for `doc`) and its tests run, or docs/make.jl. The
# cell file `OUT/NAME-BREAK-VERSION.toml` says `pass`, `fail` or `no_tag` (nothing to check
# out), with the ref tested and the version of the package under test that was resolved.
# A failure of the downstream package is a result, not an error: exit code 0; 1 when the
# clone fails (no cell is written, the report counts it as missing); 2 (usage). Stdlib only.

using TOML

# The command runner: a `Cmd` → `(ok, stdout)`. Tests replace it; a second include keeps it.
@isdefined(RUN) || global RUN = Ref{Any}(function (cmd)
    out = IOBuffer()
    ok = success(pipeline(cmd; stdout=out, stderr=stderr))
    return (ok, String(take!(out)))
end)

run_cmd(cmd) = RUN[](cmd)

"""
    pick_ref(version, branch, tags) -> Union{String,Nothing}

What to check out for `version`: the default `branch` for `latest`, the first of `tags`
(newest first) for `stable`, `version` itself otherwise; `nothing` when `stable` finds no tag.
"""
function pick_ref(version, branch, tags)
    version == "latest" && return branch
    version == "stable" && return isempty(tags) ? nothing : first(tags)
    return version
end

"The Julia program of a cell, run in the downstream package with SOURCE developed in it."
function program(brk)
    brk == "test" && return """
        using Pkg
        Pkg.activate("."); Pkg.instantiate(); Pkg.develop(path=ENV["SOURCE"]); Pkg.build(); Pkg.test()
        """
    brk == "doc" && return """
        using Pkg
        Pkg.activate("docs"); Pkg.instantiate(); Pkg.develop(path=ENV["SOURCE"]); Pkg.build(); include("docs/make.jl")
        """
    error("break must be test or doc, not $brk")
end

"The program printing the version of NAME resolved in the active environment, `v…` or nothing."
const COMPAT_PROGRAM = """
    using Pkg
    v = get(Dict(p.name => p.version for p in values(Pkg.dependencies())), ENV["SRC_NAME"], nothing)
    v === nothing || print("v", v)
    """

"""
    run_cell(; name, owner, brk, version, source, out, job="") -> Union{String,Nothing}

Run the cell and write its file; return the path of the file, or `nothing` when the clone
fails.
"""
function run_cell(; name, owner, brk, version, source, out, job="")
    program(brk)   # an unknown `brk` is an error before anything is cloned
    source = rstrip(abspath(source), '/')
    src_name = replace(basename(source), r"\.jl$" => "")
    dir = mktempdir()
    ok, _ = run_cmd(`git clone --quiet https://github.com/$owner/$name.jl $dir`)
    ok || return nothing
    ref = if version == "latest"
        strip(run_cmd(`git -C $dir rev-parse --abbrev-ref HEAD`)[2])
    else
        run_cmd(`git -C $dir fetch --quiet --tags`)
        tags = version == "stable" ?
            split(run_cmd(`git -C $dir tag -l "v*" --sort=-creatordate`)[2], '\n'; keepempty=false) : String[]
        pick_ref(version, nothing, tags)
    end
    if ref !== nothing && version != "latest"
        run_cmd(`git -C $dir checkout --quiet $ref`)[1] || (ref = nothing)
    end
    status = if ref === nothing
        "no_tag"
    else
        env = ("SOURCE" => source, "SRC_NAME" => src_name)
        run_cmd(Cmd(addenv(`julia --startup-file=no -e $(program(brk))`, env...); dir))[1] ? "pass" : "fail"
    end
    compat = ""
    if ref !== nothing
        project = brk == "doc" ? "docs" : "."
        ok, v = run_cmd(Cmd(addenv(`julia --startup-file=no --project=$project -e $COMPAT_PROGRAM`, "SRC_NAME" => src_name); dir))
        ok && (compat = strip(v))
    end
    mkpath(out)
    path = joinpath(out, "$name-$brk-$version.toml")
    cell = Dict("name" => name, "owner" => owner, "break" => brk, "version" => version,
                "tag" => something(ref, "none"), "compat" => compat, "status" => status, "job" => job)
    open(io -> TOML.print(io, cell), path, "w")
    println("$name ($brk, $version at $(something(ref, "no tag"))): $status")
    return path
end

"Parse the arguments, run the cell; return the exit code."
function cell_main(args)
    args = collect(String, args)
    opts = Dict{String,String}()
    while length(args) >= 2 && startswith(args[1], "--")
        opts[args[1][3:end]] = args[2]
        args = args[3:end]
    end
    required = ("name", "owner", "break", "version", "source", "out")
    if !isempty(args) || any(k -> !haskey(opts, k), required) || !(opts["break"] in ("test", "doc"))
        println(stderr, "usage: julia cell.jl --name NAME --owner OWNER --break test|doc --version latest|stable|REF --source DIR --out DIR [--job URL]")
        return 2
    end
    path = run_cell(; name=opts["name"], owner=opts["owner"], brk=opts["break"], version=opts["version"],
                    source=opts["source"], out=opts["out"], job=get(opts, "job", ""))
    path === nothing && (println(stderr, "cannot clone $(opts["owner"])/$(opts["name"]).jl"); return 1)
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(cell_main(ARGS))
end
