# publish.jl: idempotent PRs and tracking issue, against a stateful fake GitHub and real git
# repositories (a local bare repository plays `origin` for each package).

include(joinpath(SCRIPTS, "publish.jl"))

"""
A fake GitHub keeping issues and PRs. `origins` maps a repo ("owner/name") to its bare
repository, where `pr close --delete-branch` deletes the branch.
"""
mutable struct FakeGitHub
    origins::Dict{String,String}
    issues::Vector{Dict{String,Any}}
    prs::Vector{Dict{String,Any}}
    calls::Vector{Vector{String}}
end
FakeGitHub(origins) = FakeGitHub(origins, Dict{String,Any}[], Dict{String,Any}[], Vector{String}[])

opt(args, name) = args[findfirst(==(name), args) + 1]

function (f::FakeGitHub)(args)
    push!(f.calls, args)
    cmd = args[1:2]
    if cmd == ["api", "--paginate"]
        repo = match(r"^repos/([^/]+/[^/]+)/issues", args[3])[1]
        hits = [i for i in f.issues if i["repo"] == repo && occursin(MARKER, i["body"])]
        return join(["$(i["number"]) $(i["state"])" for i in hits], "\n") * (isempty(hits) ? "" : "\n")
    elseif cmd == ["issue", "create"]
        repo = opt(args, "--repo")
        n = length(f.issues) + 100
        push!(f.issues, Dict("repo" => repo, "number" => n, "state" => "open", "title" => opt(args, "--title"),
                             "body" => opt(args, "--body"), "comments" => String[]))
        return "https://github.com/$repo/issues/$n\n"
    elseif cmd[1] == "issue"
        i = only(filter(i -> string(i["number"]) == args[3] && i["repo"] == opt(args, "--repo"), f.issues))
        cmd[2] == "edit" && (i["body"] = opt(args, "--body"))
        cmd[2] == "close" && (i["state"] = "closed"; push!(i["comments"], opt(args, "--comment")))
        cmd[2] == "reopen" && (i["state"] = "open")
        return ""
    elseif cmd == ["pr", "list"]
        repo, head = opt(args, "--repo"), opt(args, "--head")
        hits = [p for p in f.prs if p["repo"] == repo && p["head"] == head && p["state"] == "open"]
        return join(["$(p["number"]) $(p["url"])" for p in hits], "\n")
    elseif cmd == ["pr", "create"]
        repo = opt(args, "--repo")
        n = length(f.prs) + 1
        url = "https://github.com/$repo/pull/$n"
        push!(f.prs, Dict("repo" => repo, "number" => n, "url" => url, "state" => "open", "head" => opt(args, "--head"),
                          "base" => opt(args, "--base"), "title" => opt(args, "--title"), "body" => opt(args, "--body")))
        return url * "\n"
    elseif cmd[1] == "pr"
        p = only(filter(p -> string(p["number"]) == args[3] && p["repo"] == opt(args, "--repo"), f.prs))
        cmd[2] == "edit" && (p["body"] = opt(args, "--body"))
        if cmd[2] == "close"
            p["state"] = "closed"
            "--delete-branch" in args && run(`git -C $(f.origins[p["repo"]]) branch --quiet -D $(p["head"])`)
        end
        return ""
    end
    error("unexpected gh call: $args")
end

const GITC = `git -c user.name=test -c user.email=test@example.org -c init.defaultBranch=main`

"A bare origin for each fixture package, holding its default-branch files; returns repo => path."
function make_origins(dir)
    index = TOML.parsefile(joinpath(COLLECTED, "index.toml"))["packages"]
    origins = Dict{String,String}()
    for (name, p) in index
        bare = joinpath(dir, "origins", name * ".git")
        run(`$GITC init --quiet --bare -b $(p["default_branch"]) $bare`)
        work = joinpath(dir, "seed", name)
        run(`$GITC clone --quiet $bare $work`)
        src = joinpath(COLLECTED, "default", name)
        foreach(f -> cp(joinpath(src, f), joinpath(work, f)), readdir(src))
        run(`$GITC -C $work checkout --quiet -B $(p["default_branch"])`)
        run(`$GITC -C $work add --all`)
        run(`$GITC -C $work commit --quiet -m init`)
        run(`$GITC -C $work push --quiet origin $(p["default_branch"])`)
        origins[p["repo"]] = bare
    end
    return origins
end

"Fresh clones of every origin's default branch, then edit.jl's work: writes audit.toml, edits.toml."
function prepare_run(dir, origins, prunes; tag)
    index = TOML.parsefile(joinpath(COLLECTED, "index.toml"))["packages"]
    root = joinpath(dir, "run-$tag")
    checkouts = joinpath(root, "checkouts")
    for (name, p) in index
        run(`$GITC clone --quiet --branch $(p["default_branch"]) $(origins[p["repo"]]) $(joinpath(checkouts, name))`)
    end
    audit = Dict{String,Any}("date" => "2026-11-01 04:00 UTC", "julia" => ["1.10", "1.12"], "packages" => index,
                             "prune" => prunes, "rejected" => [], "blocked" => [], "other" => [])
    open(io -> TOML.print(io, audit), joinpath(root, "audit.toml"), "w")
    records, texts = plan_edits(audit, read_checkout(checkouts))
    for ((owner, file), text) in texts
        write(joinpath(checkouts, owner, file), text)
    end
    open(io -> TOML.print(io, Dict("edit" => records)), joinpath(root, "edits.toml"), "w")
    return root, checkouts
end

"Commit `text` as `file` on the default branch of `origin` (a maintainer merging the PR)."
function merge_on_origin(dir, origin, branch, file, text)
    work = joinpath(dir, "merge-" * string(hash((origin, file, text)); base=16))
    run(`$GITC clone --quiet --branch $branch $origin $work`)
    write(joinpath(work, file), text)
    run(`$GITC -C $work commit --quiet -am merged`)
    run(`$GITC -C $work push --quiet origin $branch`)
end

branch_exists(origin) = success(`git -C $origin rev-parse --verify --quiet refs/heads/$BRANCH`)

@testset "publish" begin
    @testset "helpers" begin
        evidence = Dict{String,Any}("0.6" => ["joint@1.10=0.6.4"], "0.7" => ["joint@1.12=0.7.2"])
        edits = [merge(prune("Alpha", "Project.toml", "Dep1", "0.5, 0.6, 0.7", "0.6, 0.7"), Dict("status" => "edited", "evidence" => evidence)),
                 merge(prune("Alpha", "docs/Project.toml", "Doc", "0.9, 1", "1"), Dict("status" => "edited")),
                 merge(prune("Beta", "Project.toml", "Dep1", "0.6, 0.7", "0.7"), Dict("status" => "already"))]
        @test commit_message("Alpha", edits) == """
            chore(compat): drop [compat] specifiers no supported Julia version selects

            Project.toml: Dep1 = "0.5, 0.6, 0.7" → "0.6, 0.7"
            docs/Project.toml: Doc = "0.9, 1" → "1\""""
        body = render_pr_body("Alpha", edits; issue_url="https://github.com/example-org/Root.jl/issues/100",
                              run_url="https://github.com/example-org/Root.jl/actions/runs/1")
        @test golden("pr-body.md", body)
        @test startswith(body, MARKER)
        @test !occursin("Beta", body)
    end

    mktempdir() do dir
        origins = make_origins(dir)
        alpha, beta = origins["example-org/Alpha.jl"], origins["example-org/Beta.jl"]
        fake = FakeGitHub(origins)
        prunes = [prune("Alpha", "Project.toml", "Dep1", "0.5, 0.6, 0.7", "0.6, 0.7"),
                  prune("Alpha", "docs/Project.toml", "Doc", "0.9, 1", "1"),
                  prune("Beta", "Project.toml", "Dep1", "0.6, 0.7", "0.7")]     # Beta's branch already has it

        @testset "first run: issue, branch, PR" begin
            root, checkouts = prepare_run(dir, origins, prunes; tag="1")
            done = with_gh(() -> publish(root, checkouts, "example-org/Root.jl"; run_url="https://run/1"), fake)
            @test length(fake.issues) == 1
            issue = only(fake.issues)
            @test issue["title"] == ISSUE_TITLE && issue["state"] == "open"
            @test done["issue"] == "https://github.com/example-org/Root.jl/issues/100"
            pr = only(fake.prs)
            @test pr["repo"] == "example-org/Alpha.jl" && pr["head"] == BRANCH && pr["base"] == "main"
            @test done["prs"] == Dict("Alpha" => pr["url"])
            @test done["pushed"] == ["Alpha"]
            # the PR links the issue, the issue links the PR
            @test occursin(done["issue"], pr["body"])
            @test occursin("### Alpha — $(pr["url"])", issue["body"])
            # the branch holds the edits on top of the default branch, nothing else
            @test branch_exists(alpha) && !branch_exists(beta)
            diff = read(`git -C $alpha diff main $BRANCH`, String)
            @test occursin("-Dep1 = \"0.5, 0.6, 0.7\"  # lanes kept by CompatHelper", diff)
            @test occursin("+Dep1 = \"0.6, 0.7\"  # lanes kept by CompatHelper", diff)
            @test occursin("+Doc = \"1\"", diff)
            @test count(l -> startswith(l, "+") && !startswith(l, "+++"), split(diff, '\n')) == 2
            @test strip(read(`git -C $alpha log -1 --format=%an $BRANCH`, String)) == BOT[1]
        end

        @testset "second run: nothing changes" begin
            before = read(`git -C $alpha rev-parse $BRANCH`, String)
            n_calls = length(fake.calls)
            root, checkouts = prepare_run(dir, origins, prunes; tag="2")
            done = with_gh(() -> publish(root, checkouts, "example-org/Root.jl"; run_url="https://run/2"), fake)
            @test length(fake.issues) == 1 && length(fake.prs) == 1
            @test isempty(done["pushed"])
            @test read(`git -C $alpha rev-parse $BRANCH`, String) == before
            calls = fake.calls[n_calls+1:end]
            @test !any(c -> c[1:2] in (["issue", "create"], ["pr", "create"]), calls)
            @test any(c -> c[1:2] == ["pr", "edit"], calls)
            # bodies refreshed with the new run
            @test occursin("https://run/2", only(fake.issues)["body"])
        end

        @testset "after the merge: PR closed, branch deleted, issue closed" begin
            # the maintainer merges: the default branch now carries the pruned values
            alpha_now = read(`git -C $alpha show main:Project.toml`, String)
            merge_on_origin(dir, alpha, "main", "Project.toml", replace(alpha_now, "Dep1 = \"0.5, 0.6, 0.7\"" => "Dep1 = \"0.6, 0.7\""))
            docs_now = read(`git -C $alpha show main:docs/Project.toml`, String)
            merge_on_origin(dir, alpha, "main", "docs/Project.toml", replace(docs_now, "Doc = \"0.9, 1\"" => "Doc = \"1\""))
            root, checkouts = prepare_run(dir, origins, prunes; tag="3")
            @test all(e -> e["status"] == "already", TOML.parsefile(joinpath(root, "edits.toml"))["edit"])
            done = with_gh(() -> publish(root, checkouts, "example-org/Root.jl"), fake)
            @test done["closed"] == ["Alpha"]
            @test only(fake.prs)["state"] == "closed"
            @test !branch_exists(alpha)
            issue = only(fake.issues)
            @test issue["state"] == "closed" && issue["comments"] == ["Nothing left to prune."]
            @test occursin("| merged, awaiting release | 3 |", issue["body"])
        end

        @testset "nothing to prune and no issue: nothing is created" begin
            f = FakeGitHub(origins)
            root, checkouts = prepare_run(dir, origins, prunes; tag="3b")
            done = with_gh(() -> publish(root, checkouts, "example-org/Other.jl"), f)
            @test isempty(f.issues) && isempty(f.prs) && done["issue"] == ""
        end

        @testset "a new prune: the same issue is reopened, a new PR opened" begin
            again = [prune("Beta", "Project.toml", "Tool", "1, 2", "2")]
            beta_now = read(`git -C $beta show dev:Project.toml`, String)
            merge_on_origin(dir, beta, "dev", "Project.toml", replace(beta_now, "Tool = \"2\"" => "Tool = \"1, 2\""))
            root, checkouts = prepare_run(dir, origins, again; tag="4")
            done = with_gh(() -> publish(root, checkouts, "example-org/Root.jl"), fake)
            @test length(fake.issues) == 1 && only(fake.issues)["state"] == "open"
            @test length(fake.prs) == 2
            pr = fake.prs[2]
            @test pr["repo"] == "example-org/Beta.jl" && pr["base"] == "dev" && pr["state"] == "open"
            @test done["prs"] == Dict("Beta" => pr["url"])
            @test branch_exists(beta)
        end

        @testset "find_issue ignores PRs and issues without the marker" begin
            f = FakeGitHub(origins)
            push!(f.issues, Dict("repo" => "a/b", "number" => 7, "state" => "open", "body" => "no marker", "comments" => String[]))
            @test with_gh(() -> find_issue("a/b"), f) === nothing
            push!(f.issues, Dict("repo" => "a/b", "number" => 8, "state" => "closed", "body" => MARKER * "\nold", "comments" => String[]))
            @test with_gh(() -> find_issue("a/b"), f) == ("8", "closed")
            # the jq filter excludes pull requests and empty bodies
            jq = f.calls[end][end]
            @test occursin("select(.pull_request == null)", jq) && occursin("(.body // \"\")", jq)
        end
    end
end
