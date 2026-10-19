# What the release-tag workflow tags, on `main`: the merge commit of a release PR, once
# (REL5). Stdlib only; needs `git` and the clone's history and tags.

include(joinpath(@__DIR__, "gate.jl"))

"The `version` of `Project.toml` at `rev`, or `nothing`."
function version_at(dir, rev)
    toml = show_file(dir, rev, "Project.toml")
    toml === nothing && return nothing
    v = get(TOML.parse(toml), "version", nothing)
    return v === nothing ? nothing : VersionNumber(v)
end

"""
    tag_plan(dir; rev="HEAD") -> NamedTuple

What to tag in the clone `dir`, on the first-parent history of `rev`: the version of
`Project.toml`, the commit that set it (its first parent has another version), the tag of
the previous release for the notes (the previous stable for a stable, REL5), and whether
it is a pre-release. `tag === nothing`, with the reason, when there is nothing to do: the
version is already tagged, or no commit sets it.
"""
function tag_plan(dir; rev="HEAD")
    v = version_at(dir, rev)
    v === nothing && return (; tag=nothing, reason="no version in Project.toml")
    tags = tagged_versions(dir)
    v in tags && return (; tag=nothing, reason="`v$v` is already tagged")
    allowed_suffix(v) || return (; tag=nothing, reason="`$v`: the only suffix allowed is `-beta` (REL2)")
    commits = split(something(git(dir, "log", "--first-parent", "--format=%H", rev, "--", "Project.toml"), ""))
    target = findfirst(c -> version_at(dir, c) == v && version_at(dir, "$c^1") != v, commits)
    target === nothing && return (; tag=nothing, reason="no commit on the first-parent history sets `$v`")
    below = filter(t -> t < v && (isbeta(v) || isstable(t)), tags)
    previous = isempty(below) ? nothing : "v$(maximum(below))"
    return (; tag="v$v", target=commits[target], previous, prerelease=isbeta(v), reason="")
end
