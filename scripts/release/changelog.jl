# CHANGELOG.md and BREAKING.md of a release: CHG2-CHG4 of ct-conventions, as far as a
# release needs them. Strict on the entry the release adds, tolerant of older entries (their
# formats vary between packages). Stdlib only.

"""
    sections(changelog) -> Vector{Pair{String,String}}

The `## [label] …` sections of a changelog, in order, as label => text (the heading line
included). Labels are `Unreleased` or a version.
"""
function sections(changelog::AbstractString)
    out = Pair{String,String}[]
    for line in eachline(IOBuffer(changelog); keep=true)
        m = match(r"^## \[([^\]]+)\]", line)
        if m !== nothing
            push!(out, m[1] => line)
        elseif !isempty(out)
            out[end] = first(out[end]) => last(out[end]) * line
        end
    end
    return out
end

"The version of a section label, or `nothing` (`Unreleased`, or not a version)."
label_version(label) = tryparse(VersionNumber, label)

"""
    check_changelog(changelog, version) -> Vector{String}

The problems of the entry of `version`: it must be the first versioned section, dated,
right under an empty `[Unreleased]`, and end with its `### ✅ Compatibility` subsection.
"""
function check_changelog(changelog::AbstractString, version::VersionNumber)
    problems = String[]
    secs = sections(changelog)
    if isempty(secs) || first(secs[1]) != "Unreleased"
        push!(problems, "the first section is not `## [Unreleased]`")
    else
        body = strip(join(split(last(secs[1]), '\n')[2:end], '\n'))
        isempty(body) || push!(problems, "`## [Unreleased]` is not empty: its entries belong to `$version`")
        secs = secs[2:end]
    end
    if isempty(secs) || label_version(first(secs[1])) != version
        push!(problems, "the first versioned section is not `## [$version]`")
        return problems
    end
    text = last(secs[1])
    heading = first(split(text, '\n'))
    occursin(r"\d{4}-\d{2}-\d{2}", heading) || push!(problems, "the heading `$(strip(heading))` has no date `YYYY-MM-DD`")
    occursin(r"^### ✅ Compatibility"m, text) || push!(problems, "the entry of `$version` has no `### ✅ Compatibility` subsection (CHG2)")
    return problems
end

"""
    changes_since(changelog, reference) -> (; breaking, feature, versions)

What the sections above the release `reference` say (`reference === nothing`: every
section): whether one has a `### 💥` subsection (breaking, CHG3), or a `### ✨` one (new
feature), and which versions they are.
"""
function changes_since(changelog::AbstractString, reference::Union{Nothing,VersionNumber})
    breaking = feature = false
    versions = String[]
    for (label, text) in sections(changelog)
        v = label_version(label)
        reference !== nothing && v !== nothing && v <= reference && break
        push!(versions, label)
        breaking |= occursin(r"^### 💥"m, text)
        feature |= occursin(r"^### ✨"m, text)
    end
    return (; breaking, feature, versions)
end

"Whether `BREAKING.md` has a `##` heading that names `version` (any of the formats in use)."
function names_version(breaking::AbstractString, version::VersionNumber)
    v = replace(string(version), "." => "\\.")
    re = Regex("^##.*(?<![0-9.])v?$v(?![0-9.]|-[a-z])", "m")
    return occursin(re, breaking)
end
