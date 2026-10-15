# Render the audit as the Markdown body of the tracking issue.
#
# usage: julia report.jl <audit dir> [<prs.toml>]     (writes <audit dir>/report.md)
#
# <prs.toml>, written by the publishing step, maps a package name to the URL of its PR. The
# output is deterministic (everything sorted) so that an unchanged audit gives an unchanged
# body, and the hidden marker lets the publishing step find the issue again.

include("common.jl")

const MARKER = "<!-- ct-compat-prune -->"
const WORKFLOW_URL = "https://github.com/control-toolbox/CTActions/blob/main/.github/workflows/compat-prune.yml"

"Markdown table from a header and rows of strings."
table(header, rows) = join(["| " * join(header, " | ") * " |", "| " * join(fill("---", length(header)), " | ") * " |",
                            ("| " * join(r, " | ") * " |" for r in rows)...], "\n")

"`0.12.3 on 1.12, 1.13; 0.9.18 on 1.10`: the versions selected for the kept lanes, per Julia version."
function selected(evidence)
    on = Dict{String,Set{String}}()
    for list in values(evidence), e in list
        env_julia, v = split(e, "=")
        push!(get!(on, v, Set{String}()), last(split(env_julia, "@")))
    end
    vs = sort(collect(keys(on)); by=VersionNumber, rev=true)
    join(["$v on $(join(sort(collect(on[v])), ", "))" for v in vs], "; ")
end

code(s) = "`$s`"
entry(r) = "$(r["owner"]) $(code(r["file"])) $(code(r["dep"]))"

"""
    render_report(audit, edits; prs=Dict(), run_url="") -> String

Markdown body of the tracking issue: what can be pruned (per repository, with its PR), what
waits for a release, what drifted, what was rejected or withheld, and the blockers.
"""
function render_report(audit, edits; prs=Dict(), run_url="")
    by_status(s) = sort([e for e in edits if e["status"] == s]; by=entry_key)
    edited, already, drift = by_status("edited"), by_status("already"), by_status("drift")
    rejected = sort(get(audit, "rejected", []); by=entry_key)
    withheld = sort([r for r in get(audit, "other", []) if r["status"] == "withheld"]; by=entry_key)
    blocked = get(audit, "blocked", [])
    out = String[MARKER]

    run = isempty(run_url) ? "" : " ([run]($run_url))"
    push!(out, """
    Audit of the `[compat]` entries of the control-toolbox packages, by the
    [`compat-prune`]($WORKFLOW_URL) workflow on $(audit["date"])$run, for Julia \
    $(join(audit["julia"], ", ")). This body is rewritten by every run: do not edit it.

    A prune drops `[compat]` specifiers that no environment selects, on no Julia version, and
    leaves every resolved manifest (joint, tests and docs of every package) unchanged. PRs can
    therefore be merged in any order, and need no release of their own.""")

    push!(out, "## Summary\n\n" * table(["", "entries"], [
        ["to prune (open PRs)", string(length(edited))],
        ["merged, awaiting release", string(length(already))],
        ["drift (not edited)", string(length(drift))],
        ["rejected by validation", string(length(rejected))],
        ["withheld", string(length(withheld))],
        ["blocked (information)", string(length(unique(entry_key.(blocked))))],
    ]))

    if !isempty(edited)
        sections = String["## To prune"]
        for owner in sort(unique(e["owner"] for e in edited))
            pr = haskey(prs, owner) ? " — $(prs[owner])" : ""
            rows = [[code(e["file"]), code(e["dep"]), code(e["before"]), code(e["after"]), selected(e["evidence"])]
                    for e in edited if e["owner"] == owner]
            push!(sections, "### $owner$pr\n\n" * table(["file", "dependency", "before", "after", "selected"], rows))
        end
        push!(out, join(sections, "\n\n"))
    end
    isempty(already) || push!(out, "## Merged, awaiting release\n\n" *
        table(["entry", "after"], [[entry(e), code(e["after"])] for e in already]))
    isempty(drift) || push!(out, "## Drift\n\nThe default branch differs from the registered version: not edited.\n\n" *
        table(["entry", "audited", "detail"], [[entry(e), code(e["before"]), e["detail"]] for e in drift]))
    isempty(rejected) || push!(out, "## Rejected\n\n" *
        table(["entry", "where", "reason"], [[entry(r), r["where"], replace(r["reason"], "\n" => " ", "|" => "\\|")] for r in rejected]))
    isempty(withheld) || push!(out, "## Withheld\n\n$(uppercasefirst(first(withheld)["reason"])).\n\n" *
        table(["entry", "would drop"], [[entry(r), join(code.(r["removed"]), ", ")] for r in withheld]))
    if !isempty(blocked)
        rows = Vector{String}[]
        for k in sort(unique(entry_key.(blocked)))
            probes = [b for b in blocked if entry_key(b) == k]
            names = sort(unique(reduce(vcat, [b["blockers"] for b in probes])))
            b = first(probes)
            push!(rows, [entry(b), code(b["newest"]), isempty(names) ? "resolver preference" : join(names, ", ")])
        end
        push!(out, "## Blocked\n\nThe newest specifier is never selected: information only, nothing is edited.\n\n" *
            table(["entry", "newest", "capped by"], rows))
    end

    versions = [[n, p["version"], "[$(p["repo"])](https://github.com/$(p["repo"]))"] for (n, p) in sort(collect(audit["packages"]); by=first)]
    push!(out, "## Audited versions\n\n" * table(["package", "version", "repository"], versions))
    return join(out, "\n\n") * "\n"
end

"""
    render_pr_body(owner, edits; issue_url="", run_url="") -> String

Body of the PR of `owner`: its edited entries, why they can go, where the audit is.
"""
function render_pr_body(owner, edits; issue_url="", run_url="")
    mine = sort([e for e in edits if e["owner"] == owner && e["status"] == "edited"]; by=entry_key)
    rows = [[code(e["file"]), code(e["dep"]), code(e["before"]), code(e["after"]), selected(e["evidence"])] for e in mine]
    links = String[]
    isempty(issue_url) || push!(links, "tracking issue: $issue_url")
    isempty(run_url) || push!(links, "[audit run]($run_url)")
    return join([MARKER, """
        Drops the `[compat]` specifiers that no supported Julia version selects, in any
        environment of the control-toolbox packages (joint, tests and docs of every package).
        Without them every audited manifest is unchanged: this PR changes no version that
        these environments resolve, needs no release of its own, and can be merged in any
        order with the PRs of the other packages.""",
        table(["file", "dependency", "before", "after", "selected"], rows),
        "Opened by the [`compat-prune`]($WORKFLOW_URL) workflow" * (isempty(links) ? "" : " ($(join(links, ", ")))") *
        ". The branch is rewritten by every run: push nothing to it."], "\n\n") * "\n"
end

if abspath(PROGRAM_FILE) == @__FILE__
    root = ARGS[1]
    prs = length(ARGS) ≥ 2 ? TOML.parsefile(ARGS[2]) : Dict()
    audit = TOML.parsefile(joinpath(root, "audit.toml"))
    edits = TOML.parsefile(joinpath(root, "edits.toml"))["edit"]
    write(joinpath(root, "report.md"), render_report(audit, edits; prs, run_url=get(ENV, "RUN_URL", "")))
    println("report written to ", joinpath(root, "report.md"))
end
