# Shared by every test file: the scripts (their `main` blocks do not run when included),
# fixture paths, and small builders.

const SCRIPTS = joinpath(@__DIR__, "..")
for f in ("collect.jl", "envs.jl", "resolve.jl", "classify.jl", "validate.jl", "edit.jl", "report.jl", "audit.jl")
    include(joinpath(SCRIPTS, f))
end

const FIXTURES = joinpath(@__DIR__, "fixtures")
const COLLECTED = joinpath(FIXTURES, "collected")
const GOLDEN = joinpath(@__DIR__, "golden")
const UPDATE_GOLDEN = get(ENV, "COMPAT_PRUNE_UPDATE_GOLDEN", "") == "1"

"A resolved environment result with the given name => version pairs."
ok(versions...) = Dict("ok" => true, "versions" => Dict{String,Any}(versions...))

"A failed environment result."
failed(msg="unsatisfiable") = Dict("ok" => false, "error" => msg)

"A prune record."
prune(owner, file, dep, before, after) =
    Dict{String,Any}("owner" => owner, "file" => file, "dep" => dep, "before" => before, "after" => after,
                     "removed" => setdiff(specifiers(before), specifiers(after)), "status" => "prune",
                     "evidence" => Dict{String,Any}())

"Compare `text` with the golden file `name`, or rewrite it under COMPAT_PRUNE_UPDATE_GOLDEN=1."
function golden(name, text)
    path = joinpath(GOLDEN, name)
    if UPDATE_GOLDEN || !isfile(path)
        mkpath(dirname(path))
        write(path, text)
        @info "golden file written: $name"
    end
    return text == read(path, String)
end

"Run `f` with `GH` replaced by `fake`, restoring the real runner afterwards."
function with_gh(f, fake)
    real = GH[]
    GH[] = fake
    try
        f()
    finally
        GH[] = real
    end
end

# Captured from real runs (2026-10-15): DocStringExtensions restricted to its newest 0.10.
const CONFLICT_ON_DEP = """
Unsatisfiable requirements detected for package DocStringExtensions [ffbed154]:
 DocStringExtensions [ffbed154] log:
 ├─possible versions are: 0.9.3 - 0.10.0 or uninstalled
 ├─restricted to versions 0.10 by project [4e53ef5c], leaving only versions: 0.10.0
 │ └─project [4e53ef5c] log:
 │   ├─possible versions are: 0.0.0 or uninstalled
 │   └─project [4e53ef5c] is fixed to version 0.0.0
 └─restricted by compatibility requirements with SciMLBase [0bca4576] to versions: 0.9.5 — no versions left
   └─SciMLBase [0bca4576] log:
     ├─possible versions are: 2.77.2 - 3.58.0 or uninstalled
     └─restricted by compatibility requirements with Deeper [00000000] to versions: 3
"""
const CONFLICT_ON_OTHER = """
Unsatisfiable requirements detected for package DocumenterVitepress [4710194d]:
 DocumenterVitepress [4710194d] log:
 ├─possible versions are: 0.3.4 - 0.3.8 or uninstalled
 └─restricted by compatibility requirements with DocStringExtensions [ffbed154] to versions: uninstalled — no versions left
   └─DocStringExtensions [ffbed154] log:
     └─restricted to versions 0.10 by project [064cce67], leaving only versions: 0.10.0
"""

"Run `f(root)` on a temporary copy of the collected fixture, with its `envs.toml` built."
function with_collected(f)
    mktempdir() do dir
        root = joinpath(dir, "collected")
        cp(COLLECTED, root)
        open(io -> TOML.print(io, Dict("env" => build_envs(root))), joinpath(root, "envs.toml"), "w")
        f(root)
    end
end

"Baseline results of the collected fixture, keyed `<env>@<julia>`."
fixture_results() = Dict{String,Any}(
    "joint@1.10" => ok("Alpha" => "0.3.1", "Beta" => "1.2.0-beta", "Dep1" => "0.6.4"),
    "joint@1.12" => ok("Alpha" => "0.3.1", "Beta" => "1.2.0-beta", "Dep1" => "0.7.2"),
    "Alpha/test@1.12" => ok("Alpha" => "0.3.1", "Beta" => "1.2.0-beta", "Dep1" => "0.7.2", "Tool" => "2.0.0"),
    "Alpha/docs@1.12" => ok("Alpha" => "0.3.1", "Beta" => "1.2.0-beta", "Dep1" => "0.7.2", "Doc" => "0.9.3"),
    "Beta/test@1.12" => ok("Beta" => "1.2.0-beta", "Dep1" => "0.7.2", "Tool" => "2.1.0"),
)
