# The registration comment of a stable release (REL6): built here, posted here, once, and
# only when `status` says the release is ready for it. Stdlib only; needs the `gh` CLI.

@isdefined(facts) || include(joinpath(@__DIR__, "status.jl"))
@isdefined(sections) || include(joinpath(@__DIR__, "changelog.jl"))

"""
    registration_body(changelog, version, repo, whats_changed) -> String

The registration comment: the bot's mention and command, then the entry of `version` in
`changelog` (its links made absolute at the tag), then the notes of the GitHub release.
"""
function registration_body(changelog::AbstractString, version::VersionNumber, repo::AbstractString,
                           whats_changed::AbstractString)
    secs = sections(changelog)
    i = findfirst(s -> label_version(first(s)) == version, secs)
    i === nothing && throw(ArgumentError("CHANGELOG.md has no `## [$version]` section"))
    entry = strip(join(split(last(secs[i]), '\n')[2:end], '\n'))
    # a link relative to the repository (BREAKING.md) points to the file at the tag
    entry = replace(entry, r"\]\((?!https?://|#|mailto:)([^)\s]+)\)" =>
                           SubstitutionString("](https://github.com/$repo/blob/v$version/\\1)"))
    return "$MENTION register\n\nRelease notes:\n\n$entry\n\n$(strip(whats_changed))\n"
end

"`text` with the bot's mention masked, so that what is shown can be pasted anywhere."
masked(text) = replace(text, MENTION => "<the registration bot's mention>")

"""
    register(repo, version; post=false) -> (Bool, String)

Post the registration comment of the stable `version` of `repo` on its tracking issue,
once: only when `status` says phase 7, todo (tag on the merge commit, GitHub release, `main`
still there, no mention yet, no General PR). Without `post`, a dry run: the comment is
returned with the mention masked. Returns whether it succeeded, and what to report.
"""
function register(repo::AbstractString, version; post::Bool=false)
    f = facts(repo; version)
    f.kind === :stable || return (false, "`$(f.version)` is a beta: it goes to ct-registry, never to the bot (REL6)")
    p = phase(f)
    (p.phase == 7 && p.state === :todo) ||
        return (false, "not ready: phase $(p.phase), $(p.state): $(p.next)" *
                       join(("\n- $b" for b in p.blockers)))
    changelog = gh("api", "repos/$repo/contents/CHANGELOG.md?ref=v$(f.version)", "-H", "Accept: application/vnd.github.raw")
    changelog === nothing && return (false, "cannot read CHANGELOG.md at `v$(f.version)`")
    notes = something(gh("release", "view", "v$(f.version)", "-R", repo, "--json", "body", "--jq", ".body"), "")
    body = registration_body(changelog, f.version, repo, notes)
    post || return (true, "Dry run: the comment that `--post` would put on #$(f.issue.number):\n\n" * masked(body))
    path, io = mktemp()
    write(io, body); close(io)
    out = gh("issue", "comment", string(f.issue.number), "-R", repo, "--body-file", path)
    rm(path; force=true)
    out === nothing && return (false, "posting the comment on #$(f.issue.number) failed: check the issue before anything else")
    after = facts(repo; version=f.version)
    after.mentions == 1 ||
        return (false, "posted, but the issue now holds $(after.mentions) mentions: a human checks it (REL6)")
    return (true, "posted on #$(f.issue.number) ($(strip(out))): rerun `status` in a minute for the bot's answer")
end
