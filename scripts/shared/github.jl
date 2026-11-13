# GitHub through the `gh` CLI, for every tool of scripts/ (docs/principles.md, principle 2:
# shared code goes to a place every tool owns). Stdlib only.
#
# Two runners, both replaced by the tests; a second include keeps them:
# - `GH_RUN`: the argument vector → `(exit code, stdout, stderr)`, for a caller that tells
#   one failure from another (a 404 from a 502);
# - `GH`: the argument vector → stdout, or `nothing` when the command fails.
#
# `gh` and `gh_strip` answer `nothing` on a failure, for the callers to whom a missing
# release or a 404 is an answer; `gh!`, `gh_raw`, `gh_jq` and `gh_api` throw, with the
# command's stderr in the message.

# The stderr of the last failed command of `GH`, for the error messages of `gh!`.
@isdefined(GH_LAST_ERROR) || global GH_LAST_ERROR = Ref("")

@isdefined(GH_RUN) || global GH_RUN = Ref{Any}(function (args)
    out, err = IOBuffer(), IOBuffer()
    p = run(pipeline(ignorestatus(`gh $args`); stdout=out, stderr=err))
    return (p.exitcode, String(take!(out)), String(take!(err)))
end)

@isdefined(GH) || global GH = Ref{Any}(function (args)
    code, out, err = GH_RUN[](args)
    code == 0 && return out
    GH_LAST_ERROR[] = strip(err)
    return nothing
end)

"Run `gh` with `args`: its stdout, or `nothing` when it fails."
gh(args...) = GH[](collect(String, args))

"`gh(args...)` stripped, or `nothing`."
gh_strip(args...) = (out = gh(args...); out === nothing ? nothing : strip(out))

"Run `gh` with `args`: `(exit code, stdout, stderr)`."
gh_status(args...) = GH_RUN[](collect(String, args))

"Run `gh` with `args`: its stdout; an error when it fails."
function gh!(args...)
    GH_LAST_ERROR[] = ""
    out = gh(args...)
    out === nothing && error("gh $(join(args, ' ')) failed: $(GH_LAST_ERROR[])")
    return out
end

"`gh api` call returning the raw body (blobs, file contents)."
gh_raw(path) = gh!("api", path, "-H", "Accept: application/vnd.github.raw")

"`gh api` call returning one field extracted with `--jq`."
gh_jq(path, jq) = strip(gh!("api", path, "--jq", jq))

"""
    gh_api(method, path, fields...; jq=nothing) -> String

Call the REST API: `method` on `path`, with the string fields `key => value`, the output
filtered by `jq` when given.
"""
function gh_api(method, path, fields::Pair...; jq=nothing)
    args = ["api", "--method", method, path]
    for (k, v) in fields
        push!(args, "-f", "$k=$v")
    end
    jq === nothing || push!(args, "--jq", jq)
    return gh!(args...)
end
