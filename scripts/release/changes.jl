# What a release PR may touch, what makes a release (REL7), and the run labels it needs.
# Stdlib only.

using TOML

"The files a release PR changes, and nothing else."
const RELEASE_FILES = ("Project.toml", "CHANGELOG.md", "BREAKING.md")

"The paths whose change reaches a user of the package (REL7). `Project.toml` is judged apart."
const SHIPPED = (r"^src/", r"^ext/", r"^docs/")

"`project` without its `version`: what a change of `Project.toml` other than the version shows."
without_version(project::AbstractDict) = Dict(k => v for (k, v) in project if k != "version")

"""
    user_facing(project) -> Dict

The part of a parsed `Project.toml` that reaches a user (REL7): the dependencies, weak
dependencies and extensions, and the `[compat]` of those and of `julia`. Test-only
entries (`[extras]`, `[targets]`, their `[compat]`) and the version are left out.
"""
function user_facing(project::AbstractDict)
    deps = merge(Dict(get(project, "deps", Dict())), Dict(get(project, "weakdeps", Dict())))
    compat = Dict(k => v for (k, v) in get(project, "compat", Dict()) if k == "julia" || haskey(deps, k))
    return Dict("deps" => get(project, "deps", Dict()), "weakdeps" => get(project, "weakdeps", Dict()),
                "extensions" => get(project, "extensions", Dict()), "compat" => compat)
end

"""
    shipped(files, old_project, new_project) -> Vector{String}

The changes, among `files` and between the two parsed `Project.toml`, that reach a user
(REL7): the files under `src/`, `ext/` or `docs/`, and `Project.toml` when its
[`user_facing`](@ref) part changed. Empty: nothing to release.
"""
function shipped(files, old_project::AbstractDict, new_project::AbstractDict)
    out = [f for f in files if any(r -> occursin(r, f), SHIPPED)]
    user_facing(old_project) == user_facing(new_project) || push!(out, "Project.toml")
    return out
end

"Map of dispatch.yml output names to the run labels they represent."
const DISPATCH_OUTPUT_LABELS = Dict(
    "run_ci_github" => "run ci github-runner",
    "run_ci_occidata" => "run ci occidata-runner",
    "run_ci_kkt" => "run ci kkt-runner",
    "run_documentation" => "run documentation",
    "run_breakage_packages" => "run breakage",
    "run_breakage_applications" => "run breakage applications",
)

"The run labels a package's workflows react to (`contains(… .labels.*.name, '<label>')` or `.github/ci.toml`)."
function run_labels(workflows::AbstractString)
    labels = Set{String}()
    ci_toml = joinpath(dirname(workflows), "ci.toml")
    if isfile(ci_toml)
        cfg = TOML.parsefile(ci_toml)
        # ci.github (default enabled)
        gh = get(get(cfg, "ci", Dict()), "github", Dict())
        get(gh, "enabled", true) && push!(labels, get(gh, "label", "run ci github-runner"))

        # ci.occidata (default disabled)
        occi = get(get(cfg, "ci", Dict()), "occidata", Dict())
        get(occi, "enabled", false) && push!(labels, get(occi, "label", "run ci occidata-runner"))

        # ci.kkt (default disabled)
        kkt = get(get(cfg, "ci", Dict()), "kkt", Dict())
        get(kkt, "enabled", false) && push!(labels, get(kkt, "label", "run ci kkt-runner"))

        # documentation (default enabled)
        doc = get(cfg, "documentation", Dict())
        get(doc, "enabled", true) && push!(labels, get(doc, "label", "run documentation"))

        # breakage.packages (default enabled)
        brk_pkg = get(get(cfg, "breakage", Dict()), "packages", Dict())
        get(brk_pkg, "enabled", true) && push!(labels, get(brk_pkg, "label", "run breakage"))

        # breakage.applications (default disabled)
        brk_app = get(get(cfg, "breakage", Dict()), "applications", Dict())
        get(brk_app, "enabled", false) && push!(labels, get(brk_app, "label", "run breakage applications"))

        return labels
    end
    isdir(workflows) || return labels
    for f in readdir(workflows; join=true)
        endswith(f, ".yml") || endswith(f, ".yaml") || continue
        for line in eachline(f)
            startswith(lstrip(line), "#") && continue   # a commented-out guard requires nothing
            for m in eachmatch(r"labels\.\*\.name, '([^']+)'", line)
                push!(labels, m[1])
            end
            for m in eachmatch(r"outputs\.(run_[a-z_]+)", line)
                haskey(DISPATCH_OUTPUT_LABELS, m[1]) && push!(labels, DISPATCH_OUTPUT_LABELS[m[1]])
            end
        end
    end
    return labels
end

"The GPU runner labels: a release needs one of them (`kkt` first, `occidata` as fallback)."
const GPU_LABELS = ("run ci kkt-runner", "run ci occidata-runner")

"The run labels a release does not need: diagnostics that gate nothing."
const OPTIONAL_LABELS = ("run probe",)

"The label that makes the documentation workflow deploy a preview of the PR."
const PREVIEW_LABEL = "documentation push preview"

"""
    missing_labels(expected, present) -> Vector{String}

The labels a release PR lacks: every run label of the workflows, except the optional ones;
of the GPU labels, any one is enough.
"""
function missing_labels(expected, present)
    present = Set(present)
    out = sort!([l for l in expected if !(l in OPTIONAL_LABELS) && !(l in GPU_LABELS) && !(l in present)])
    gpu = [l for l in GPU_LABELS if l in expected]
    if !isempty(gpu) && !any(in(present), gpu)
        push!(out, "one of " * join(("`$l`" for l in gpu), ", "))
    end
    return out
end
