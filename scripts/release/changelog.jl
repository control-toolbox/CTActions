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

using SHA

"""
    unreleased(changelog) -> Union{Nothing,NamedTuple}

The `## [Unreleased]` entry of `changelog` — its text, up to the next `##` heading whatever
its form, and that heading (`nothing` at the end) — or `nothing` when the first `##` heading
is not `## [Unreleased]`.
"""
function unreleased(changelog::AbstractString)
    lines = split(changelog, '\n')
    i = findfirst(l -> startswith(l, "## "), lines)
    (i === nothing || !startswith(lines[i], "## [Unreleased]")) && return nothing
    j = findnext(l -> startswith(l, "## "), lines, i + 1)
    return (; text=join(lines[i:something(j, length(lines) + 1) - 1], '\n'), next=j === nothing ? nothing : String(lines[j]))
end

"The subsections of a changelog entry, in their order (CHG2); `✅ Compatibility` always last."
const CHANGELOG_SECTIONS = ("💥 Breaking Changes", "✨ New Features", "🐛 Bug Fixes", "🛠 Enhancements",
                            "🔄 Refactoring", "🧪 Testing", "📚 Documentation", "📦 Dependencies", "✅ Compatibility")

"""
    unreleased_format(changelog, breaking) -> Vector{String}

What breaks the format of what the release will ship (CHG2-CHG4): the `## [Unreleased]`
entry of `changelog` and its counterpart in `breaking` (`BREAKING.md`, or `nothing`). The
facts read from the changelog — breaking or not, hence the version — are only as right as
its format: a `### Breaking` instead of `### 💥 Breaking Changes` is not seen. Older
entries are never checked (they are never edited).
"""
function unreleased_format(changelog::AbstractString, breaking)
    problems = String[]
    u = unreleased(changelog)
    u === nothing && return ["the first section is not `## [Unreleased]`: the release commit moves its entries"]
    text = u.text
    # a heading the tool cannot read would merge the entry below it into the unreleased one
    u.next === nothing || occursin(r"^## \[[^\]]+\]", u.next) ||
        push!(problems, "the heading after `## [Unreleased]`, `$(strip(u.next))`, is not `## [X.Y.Z] - YYYY-MM-DD`: its entries would be read as unreleased")
    heads = [String(strip(m[1])) for m in eachmatch(r"^### (.+)$"m, text)]
    body = strip(join(split(text, '\n')[2:end], '\n'))
    # empty, as after a release: nothing to say (what shipped without an entry is a `pr-N` candidate)
    isempty(body) && return problems
    isempty(heads) && return push!(problems, "`## [Unreleased]` has entries but no `###` subsection: they belong to the sections of CHG2")
    for h in heads
        h in CHANGELOG_SECTIONS ||
            push!(problems, "`### $h` is not a section of CHG2 (expected one of $(join(("`$s`" for s in CHANGELOG_SECTIONS), ", ")))")
    end
    known = [h for h in heads if h in CHANGELOG_SECTIONS]
    length(unique(known)) == length(known) || push!(problems, "a section appears twice in `## [Unreleased]`")
    order = [findfirst(==(h), CHANGELOG_SECTIONS) for h in known]
    issorted(order) || push!(problems, "the sections of `## [Unreleased]` are not in the order of CHG2: $(join(("`$h`" for h in known), ", "))")
    last(heads) == "✅ Compatibility" || push!(problems, "`### ✅ Compatibility` is not the last subsection of `## [Unreleased]`")
    # the entries before the first subsection belong to none
    before = strip(join(split(text, '\n')[2:end], '\n'))
    startswith(before, "###") || push!(problems, "text before the first `###` of `## [Unreleased]`: it belongs to a section")
    is_breaking = "💥 Breaking Changes" in heads
    compat = something(match(r"^### ✅ Compatibility\n([\s\S]*)"m, text), Some(nothing))
    if compat !== nothing && is_breaking && occursin(r"no breaking change"i, compat[1])
        push!(problems, "`### ✅ Compatibility` says no breaking change, but there is a `### 💥 Breaking Changes`")
    end
    if breaking === nothing
        push!(problems, "no `BREAKING.md` (CHG1)")
    else
        head = occursin(r"^## \[?Unreleased\]?[ \t]*$"m, breaking)
        note = occursin("Non-breaking note (Unreleased)", breaking)
        is_breaking && !head &&
            push!(problems, "`BREAKING.md` has no `## Unreleased` entry, with the migration of the breaking changes (CHG3)")
        !is_breaking && !head && !note &&
            push!(problems, "`BREAKING.md` has neither `## Unreleased` nor `## Non-breaking note (Unreleased)` (CHG4): the release names one after the version")
    end
    return problems
end

"""
    wording_candidates(changelog) -> Vector{NamedTuple}

The entries of `## [Unreleased]` outside `### 💥 Breaking Changes` (and outside the sections
a user does not see: `🧪 Testing`, `✅ Compatibility`) whose words often say a break —
removed, renamed, no longer, breaking, deprecated, must now — each one a candidate for the
agent: a breaking change filed elsewhere, or not.
"""
function wording_candidates(changelog::AbstractString)
    u = unreleased(changelog)
    u === nothing && return NamedTuple[]
    out = NamedTuple[]
    section = ""
    for line in split(u.text, '\n')
        m = match(r"^### (.+)$", line)
        m !== nothing && (section = strip(m[1]); continue)
        section in ("💥 Breaking Changes", "🧪 Testing", "✅ Compatibility") && continue
        startswith(line, "- ") || continue
        w = match(r"\b(removed|renamed|no longer|breaking|deprecated|must now)\b"i, line)
        w === nothing && continue
        entry = replace(line[3:end], r"\s+" => " ")
        # the id comes from the entry, not its position: the same after the agent's edits elsewhere
        push!(out, (; id="wording-" * bytes2hex(sha1(strip(line)))[1:8], what="under `### $section`, “$(w[1])”: $(first(entry, 160))$(length(entry) > 160 ? "…" : "")"))
    end
    return out
end
