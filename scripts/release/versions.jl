# Version numbers: REL1-REL3 of ct-conventions. Pure functions, plus the versions a registry
# holds (read from its Versions.toml on GitHub, so always fresh). Stdlib only.

using Downloads, Pkg, TOML

"The `X.Y.Z` of `v`, without suffix."
triple(v::VersionNumber) = VersionNumber(v.major, v.minor, v.patch)

"Whether `v` is a beta (`X.Y.Z-beta`)."
isbeta(v::VersionNumber) = v.prerelease == ("beta",)

"Whether `v` is a stable version (no suffix)."
isstable(v::VersionNumber) = isempty(v.prerelease) && isempty(v.build)

"Whether `v` has a suffix allowed by REL2: none, or `-beta`."
allowed_suffix(v::VersionNumber) = isempty(v.build) && (isempty(v.prerelease) || isbeta(v))

"""
    is_breaking(old, new) -> Bool

Whether `new` is breaking with respect to `old`, as Pkg reads `[compat]` (REL1): `new` is
outside the range that `compat = "old"` allows.
"""
is_breaking(old::VersionNumber, new::VersionNumber) =
    triple(new) ∉ Pkg.Types.semver_spec(string(triple(old)))

"The next version of `v` that bumps the breaking component (REL1)."
function bump_breaking(v::VersionNumber)
    v.major > 0 && return VersionNumber(v.major + 1, 0, 0)
    v.minor > 0 && return VersionNumber(0, v.minor + 1, 0)
    return VersionNumber(0, 1, 0)   # no 0.0.Z releases: the first breaking one is 0.1.0
end

"The next version of `v` for a new feature (REL1): the minor for `X ≥ 1`, the patch in `0.Y.Z`."
bump_feature(v::VersionNumber) =
    v.major > 0 ? VersionNumber(v.major, v.minor + 1, 0) : VersionNumber(0, v.minor, v.patch + 1)

"The next version of `v` for a fix (REL1)."
bump_fix(v::VersionNumber) = VersionNumber(v.major, v.minor, v.patch + 1)

"""
    increments(v) -> Vector{VersionNumber}

The stable versions General accepts after `v` without a jump (REL3): the next patch, minor
and major.
"""
increments(v::VersionNumber) = [VersionNumber(v.major, v.minor, v.patch + 1),
                                VersionNumber(v.major, v.minor + 1, 0),
                                VersionNumber(v.major + 1, 0, 0)]

"""
    expected_version(kind, released; breaking, feature) -> Union{VersionNumber,Nothing}

The version REL1 and REL2 give to a new release of kind `:stable` or `:beta`, given every
version `released` in both registries, and whether the changes since the reference (the
last stable for a stable, the last release for a beta) are breaking or add a feature.
`nothing` when no number fits: a non-breaking stable after breaking betas (the betas took
the numbers of the next breaking series).
"""
function expected_version(kind::Symbol, released::AbstractVector{VersionNumber}; breaking::Bool, feature::Bool)
    kind in (:stable, :beta) || throw(ArgumentError("kind must be :stable or :beta, got $kind"))
    stables = filter(isstable, released)
    reference = kind === :stable ? (isempty(stables) ? nothing : maximum(stables)) :
                (isempty(released) ? nothing : maximum(triple, released))
    candidate = reference === nothing ? v"0.1.0" :
                breaking ? bump_breaking(triple(reference)) :
                feature ? bump_feature(triple(reference)) : bump_fix(triple(reference))
    # REL2: a new triple, above every one released; the betas may have taken the candidate,
    # then the next free one is just above them, and must stay breaking, or not, as decided
    top = isempty(released) ? v"0.0.0" : maximum(triple, released)
    if candidate <= top
        candidate = bump_fix(top)
        reference === nothing || is_breaking(reference, candidate) == breaking || return nothing
    end
    return kind === :stable ? candidate : VersionNumber(candidate.major, candidate.minor, candidate.patch, ("beta",))
end

"""
    jump(last_general, new, betas) -> Symbol

How the stable `new` follows `last_general`, the last version in General (REL3): `:none`
(a valid increment), `:betas` (a jump explained by the betas: `new` is a valid increment of
the highest beta above `last_general`), or `:unexplained`.
"""
function jump(last_general::Union{Nothing,VersionNumber}, new::VersionNumber, betas::AbstractVector{VersionNumber})
    last_general === nothing && return :none
    triple(new) in increments(last_general) && return :none
    above = filter(b -> triple(b) > last_general && triple(b) < triple(new), betas)
    isempty(above) && return :unexplained
    return triple(new) in increments(maximum(triple, above)) ? :betas : :unexplained
end

# The function that fetches a URL and returns its body, or `nothing` on a 404. Tests
# replace it; a second include keeps the replacement.
@isdefined(FETCH) || global FETCH = Ref{Any}(function (url)
    try
        return String(take!(Downloads.download(url, IOBuffer())))
    catch e
        e isa Downloads.RequestError && e.response.status == 404 && return nothing
        rethrow()
    end
end)

const REGISTRY_URLS = Dict(
    "General" => "https://raw.githubusercontent.com/JuliaRegistries/General/master",
    "ct-registry" => "https://raw.githubusercontent.com/control-toolbox/ct-registry/master")

"""
    registry_versions(registry, name) -> Dict{VersionNumber,String}

The versions of package `name` in `registry` ("General" or "ct-registry"), yanked ones
excluded, with their git tree hash; empty if the package is not registered there.
"""
function registry_versions(registry::AbstractString, name::AbstractString)
    body = FETCH[]("$(REGISTRY_URLS[registry])/$(uppercase(name[1]))/$name/Versions.toml")
    body === nothing && return Dict{VersionNumber,String}()
    return Dict(VersionNumber(v) => info["git-tree-sha1"]
                for (v, info) in TOML.parse(body) if !get(info, "yanked", false))
end
