# Apply the accepted prunes to checkouts of the default branches, textually.
#
# usage: julia edit.jl <audit dir> <checkouts dir>
#
# <checkouts dir>/<name> is a fresh checkout of the default branch of package <name>. The
# prunes of <audit dir>/audit.toml are applied in place, line by line, to the files as they
# are *now*: never by copying a collected file, which would revert whatever the branch
# received since the audit read it. The outcome of every prune goes to
# <audit dir>/edits.toml:
#   edited    the line on the default branch is the audited one: it is rewritten;
#   already   the default branch already carries the pruned value (merged, awaiting release);
#   drift     the line differs, or the entry, the file or the checkout is missing: untouched.
# Only the value of the one `[compat]` line changes: order, quoting, spacing and comments of
# the file are kept, and the result is re-parsed to check that nothing else moved.

include("common.jl")

"Specifiers of a compat string, normalised for comparison."
normalised(s) = sort(String.(strip.(split(s, ","))))

const SECTION = r"^\s*\[\s*([^\[\]]+?)\s*\]\s*(#.*)?$"

"""
    edit_compat(text, dep, before, after) -> (text, status, detail)

Rewrite the `[compat]` entry of `dep` from `before` to `after` in the TOML source `text`.
`status` is `"edited"`, `"already"` or `"drift"`; `text` is unchanged unless `"edited"`.
"""
function edit_compat(text, dep, before, after)
    lines = split(text, '\n'; keepempty=true)
    name = replace(dep, r"[^A-Za-z0-9_]" => s"\\\0")
    entry = Regex("^(\\s*\"?$name\"?\\s*=\\s*)([\"'])(.*?)\\2(.*)\$")
    section = ""
    for (i, l) in enumerate(lines)
        m = match(SECTION, l)
        m === nothing || (section = m[1]; continue)
        section == "compat" || continue
        m = match(entry, l)
        m === nothing && continue
        value = m[3]
        normalised(value) == normalised(after) && return (text, "already", "already `$value`")
        normalised(value) == normalised(before) ||
            return (text, "drift", "`$value` on the default branch, `$before` audited")
        lines[i] = m[1] * m[2] * after * m[2] * m[4]
        edited = join(lines, '\n')
        check_edit(text, edited, dep, after)
        return (edited, "edited", "")
    end
    return (text, "drift", "no `$dep` entry in `[compat]` on the default branch")
end

"Assert that `edited` differs from `original` by the compat entry of `dep` only."
function check_edit(original, edited, dep, after)
    a, b = TOML.parse(original), TOML.parse(edited)
    b["compat"][dep] == after || error("edit of $dep did not produce `$after`")
    a["compat"][dep] = after
    a == b || error("editing $dep changed more than its compat entry")
    return nothing
end

"""
    plan_edits(audit, read_file) -> (records, texts)

Apply every accepted prune of `audit` to the files returned by `read_file(owner, file)`
(`nothing` when absent). `records` are the prunes with their `status` and `detail`; `texts`
maps `(owner, file)` to the edited text of every file with at least one edit.
"""
function plan_edits(audit, read_file)
    texts = Dict{Tuple{String,String},String}()
    records = Dict{String,Any}[]
    for p in sort(audit["prune"]; by=entry_key)
        k = (p["owner"], p["file"])
        text = haskey(texts, k) ? texts[k] : read_file(k...)
        if text === nothing
            push!(records, merge(p, Dict("status" => "drift", "detail" => "file not on the default branch")))
            continue
        end
        edited, status, detail = edit_compat(text, p["dep"], p["before"], p["after"])
        status == "edited" && (texts[k] = edited)
        push!(records, merge(p, Dict("status" => status, "detail" => detail)))
    end
    return records, texts
end

"Read `<dir>/<owner>/<file>`, or `nothing` when absent."
read_checkout(dir) = (owner, file) -> (path = joinpath(dir, owner, file); isfile(path) ? read(path, String) : nothing)

if abspath(PROGRAM_FILE) == @__FILE__
    root, checkouts = ARGS[1], ARGS[2]
    records, texts = plan_edits(TOML.parsefile(joinpath(root, "audit.toml")), read_checkout(checkouts))
    for ((owner, file), text) in texts
        write(joinpath(checkouts, owner, file), text)
    end
    open(io -> TOML.print(io, Dict("edit" => records)), joinpath(root, "edits.toml"), "w")
    for s in ("edited", "already", "drift")
        println(rpad(s, 8), count(r -> r["status"] == s, records))
    end
end
