# Publish an audit: one PR per repository with edits, one tracking issue.
#
# usage: julia publish.jl <audit dir> <checkouts dir> <tracking repo>
#
# Run after edit.jl on fresh checkouts (<checkouts dir>/<name>, cloned with a token allowed
# to push and to open PRs and issues). Idempotent, so that a rerun changes nothing:
#   - the tracking issue of <tracking repo> is the one whose body carries MARKER, open or
#     closed: its body is rewritten, it is reopened when there is something to prune and
#     closed (with a comment) when there is nothing left; it is never created twice;
#   - each repository has one bot-owned branch, BRANCH, rebuilt from its default branch: it
#     is pushed only when its content would change; its open PR is updated, or created;
#     when the repository has nothing left to prune, the PR is closed and the branch deleted.
# Every GitHub call goes through `gh api` (GH runner, faked in tests), never through the
# `gh issue`/`gh pr` porcelain: with a GitHub App token, `gh issue edit` is refused
# ("Resource not accessible by integration") where the REST endpoint is not. git runs for real.

include("common.jl")
include("report.jl")

const BRANCH = "ct/compat-prune"
const ISSUE_TITLE = "[compat] prune report"
const PR_TITLE = "chore(compat): drop [compat] specifiers no supported Julia version selects"
# the GitHub App the publish job runs as (its bot user: id 343432246), see docs/github-app.md
const BOT = ("control-toolbox-bot[bot]", "343432246+control-toolbox-bot[bot]@users.noreply.github.com")

"Run git in `dir` and return its standard output."
git(dir, args...) = read(`git -C $dir $args`, String)

"Tree of `rev` in `dir`, or `nothing` when it does not exist."
function tree(dir, rev)
    t = readchomp(ignorestatus(`git -C $dir rev-parse --verify --quiet $("$rev^{tree}")`))
    return isempty(t) ? nothing : t
end

"""
    prepare_branch(dir, message) -> Bool

Commit the working-tree changes of checkout `dir` on BRANCH (from its current HEAD) and
tell whether the remote BRANCH differs, i.e. whether a push is needed.
"""
function prepare_branch(dir, message)
    git(dir, "checkout", "--quiet", "-B", BRANCH)
    git(dir, "add", "--all")
    git(dir, "-c", "user.name=$(BOT[1])", "-c", "user.email=$(BOT[2])", "commit", "--quiet", "-m", message)
    remote = remote_tree(dir)
    return remote != tree(dir, "HEAD")
end

"Tree of the remote BRANCH of checkout `dir`, or `nothing` when it does not exist."
function remote_tree(dir)
    isempty(strip(git(dir, "ls-remote", "--heads", "origin", BRANCH))) && return nothing
    git(dir, "fetch", "--quiet", "origin", "$BRANCH:refs/remotes/origin/$BRANCH")
    return tree(dir, "refs/remotes/origin/$BRANCH")
end

"Commit message of the edits of `owner`."
commit_message(owner, edits) = join(vcat("chore(compat): drop [compat] specifiers no supported Julia version selects", "",
    sort(["$(e["file"]): $(e["dep"]) = \"$(e["before"])\" → \"$(e["after"])\"" for e in edits if e["owner"] == owner && e["status"] == "edited"])), "\n")

"""
    api(method, path, fields...; jq=nothing) -> String

Call the REST API: `method` on `path`, with the string fields `key => value`, the output
filtered by `jq` when given.
"""
function api(method, path, fields::Pair...; jq=nothing)
    args = ["api", "--method", method, path]
    for (k, v) in fields
        push!(args, "-f", "$k=$v")
    end
    jq === nothing || push!(args, "--jq", jq)
    return gh(args...)
end

"Number and URL of the open PR from BRANCH in `repo`, or `nothing`."
function find_pr(repo)
    owner = first(split(repo, "/"))
    out = gh_jq("repos/$repo/pulls?head=$owner:$BRANCH&state=open", ".[] | \"\\(.number) \\(.html_url)\"")
    isempty(out) && return nothing
    number, url = split(first(split(out, '\n')))
    return (number, url)
end

"Number and state (`open`/`closed`) of the tracking issue of `repo`, or `nothing`."
function find_issue(repo)
    jq = ".[] | select(.pull_request == null) | select((.body // \"\") | contains(\"$MARKER\")) | \"\\(.number) \\(.state)\""
    out = strip(gh("api", "--paginate", "repos/$repo/issues?state=all&per_page=100", "--jq", jq))
    isempty(out) && return nothing
    number, state = split(first(split(out, '\n')))
    return (number, state)
end

"""
    publish(root, checkouts, tracking; run_url="") -> Dict

Publish the audit of `root`, whose edits.toml was produced by edit.jl on `checkouts`.
Returns what was done: `prs` (owner => URL), `pushed`, `closed` (owners), `issue`.
"""
function publish(root, checkouts, tracking; run_url="")
    audit = TOML.parsefile(joinpath(root, "audit.toml"))
    edits = TOML.parsefile(joinpath(root, "edits.toml"))["edit"]
    index = audit["packages"]
    done = Dict{String,Any}("prs" => Dict{String,String}(), "pushed" => String[], "closed" => String[])
    with_edits = Set(e["owner"] for e in edits if e["status"] == "edited")

    # The issue first: the PRs link to it.
    issue = find_issue(tracking)
    if issue === nothing && !isempty(with_edits)
        number = strip(api("POST", "repos/$tracking/issues", "title" => ISSUE_TITLE,
                           "body" => render_report(audit, edits; run_url); jq=".number"))
        issue = (number, "open")
    end
    issue_url = issue === nothing ? "" : "https://github.com/$tracking/issues/$(issue[1])"

    for owner in sort(collect(keys(index)))
        repo, base = index[owner]["repo"], index[owner]["default_branch"]
        pr = find_pr(repo)
        if !(owner in with_edits)
            if pr !== nothing
                api("POST", "repos/$repo/issues/$(pr[1])/comments",
                    "body" => "Nothing left to prune in this repository$(isempty(issue_url) ? "" : " (see $issue_url)").")
                api("PATCH", "repos/$repo/pulls/$(pr[1])", "state" => "closed")
                api("DELETE", "repos/$repo/git/refs/heads/$BRANCH")
                push!(done["closed"], owner)
            end
            continue
        end
        dir = joinpath(checkouts, owner)
        if prepare_branch(dir, commit_message(owner, edits))
            git(dir, "push", "--quiet", "--force", "origin", BRANCH)
            push!(done["pushed"], owner)
        end
        body = render_pr_body(owner, edits; issue_url, run_url)
        if pr === nothing
            url = strip(api("POST", "repos/$repo/pulls", "title" => PR_TITLE, "head" => BRANCH, "base" => base,
                            "body" => body; jq=".html_url"))
        else
            api("PATCH", "repos/$repo/pulls/$(pr[1])", "body" => body)
            url = pr[2]
        end
        done["prs"][owner] = url
    end

    if issue !== nothing
        path = "repos/$tracking/issues/$(issue[1])"
        body = "body" => render_report(audit, edits; prs=done["prs"], run_url)
        if isempty(with_edits) && issue[2] == "open"
            api("POST", "$path/comments", "body" => "Nothing left to prune.")
            api("PATCH", path, body, "state" => "closed")
        elseif !isempty(with_edits) && issue[2] == "closed"
            api("PATCH", path, body, "state" => "open")
        else
            api("PATCH", path, body)
        end
    end
    done["issue"] = issue_url
    return done
end

if abspath(PROGRAM_FILE) == @__FILE__
    root, checkouts, tracking = ARGS
    done = publish(root, checkouts, tracking; run_url=get(ENV, "RUN_URL", ""))
    open(io -> TOML.print(io, done), joinpath(root, "published.toml"), "w")
    println("issue: ", isempty(done["issue"]) ? "none" : done["issue"])
    for (owner, url) in sort(collect(done["prs"])); println("PR ", rpad(owner, 16), url, owner in done["pushed"] ? " (pushed)" : ""); end
    for owner in done["closed"]; println("PR ", rpad(owner, 16), "closed"); end
end
