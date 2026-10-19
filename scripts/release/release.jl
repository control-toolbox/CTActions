# The release tool of control-toolbox: one entry point for the agent, the human and the
# workflows, so that every step of a release is checked the same way wherever it runs.
#
# usage:
#   julia release.jl status --repo OWNER/REPO [--version V]
#       where the release stands, from the facts (GitHub, the registries); read only
#   julia release.jl gate --base SHA [--labels "a,b"] [--text-file FILE] [DIR]
#       the gate of a release PR (REL1-REL7) on the clone DIR (default: .); FILE holds the
#       PR's title and description (REL6 on every PR)
#   julia release.jl registrable [--base BASE_PROJECT] PROJECT
#       REL4 alone: the package resolves from General alone
#   julia release.jl tag-plan [DIR]
#       what the release-tag workflow tags, as key=value lines
#   julia release.jl register --repo OWNER/REPO --version V [--post] [--on-commit]
#       the registration comment of a stable (REL6): a dry run, the mention masked, unless
#       --post; refused unless `status` says phase 7, todo; on the merge commit instead of
#       the issue (--on-commit) only when `main` has moved past it
#
# The Markdown report goes to standard output, and to $GITHUB_STEP_SUMMARY when set. Exit
# code: 0 ready (or nothing to do), 1 blocked, 2 usage error; `status` exits 1 when the
# release is blocked, 0 otherwise. Stdlib only. See docs/workflows/release-gate.md.

include(joinpath(@__DIR__, "tag.jl"))
include(joinpath(@__DIR__, "status.jl"))
include(joinpath(@__DIR__, "register.jl"))

"The value of the option `--name` in `args`, removed from it, or `default`."
function option!(args, name, default=nothing)
    i = findfirst(==("--$name"), args)
    i === nothing && return default
    i == length(args) && throw(ArgumentError("--$name needs a value"))
    value = args[i + 1]
    deleteat!(args, i:i+1)
    return value
end

"Print `text`, and append it to the job summary when there is one."
function emit(text)
    print(text)
    summary = get(ENV, "GITHUB_STEP_SUMMARY", "")
    isempty(summary) || open(io -> print(io, text), summary, "a")
end

const USAGE = """
    usage: julia release.jl status --repo OWNER/REPO [--version V]
           julia release.jl gate --base SHA [--labels "a,b"] [--text-file FILE] [DIR]
           julia release.jl registrable [--base BASE_PROJECT] PROJECT
           julia release.jl tag-plan [DIR]
           julia release.jl register --repo OWNER/REPO --version V [--post] [--on-commit]"""

function release_main(args)
    isempty(args) && (println(stderr, USAGE); return 2)
    command, args = args[1], collect(String, args[2:end])
    try
        if command == "status"
            repo = option!(args, "repo")
            repo === nothing && throw(ArgumentError("--repo is required"))
            f = facts(repo; version=option!(args, "version"))
            p = phase(f)
            emit(status_report(f, p))
            return p.state === :blocked ? 1 : 0
        elseif command == "gate"
            base = option!(args, "base")
            base === nothing && throw(ArgumentError("--base is required"))
            labels = filter(!isempty, strip.(split(option!(args, "labels", ""), ',')))
            text_file = option!(args, "text-file")
            text = text_file === nothing ? "" : read(text_file, String)
            dir = isempty(args) ? "." : only(args)
            results = gate(dir, base; labels, text)
            name = get(TOML.parsefile(joinpath(dir, "Project.toml")), "name", basename(abspath(dir)))
            emit(gate_report(name, results))
            return any(r -> r.status === :fail, results) ? 1 : 0
        elseif command == "registrable"
            return main(args)
        elseif command == "register"
            repo = option!(args, "repo")
            version = option!(args, "version")
            (repo === nothing || version === nothing) && throw(ArgumentError("--repo and --version are required"))
            post = "--post" in args
            on_commit = "--on-commit" in args
            ok, message = register(repo, VersionNumber(version); post, on_commit)
            println(message)
            return ok ? 0 : 1
        elseif command == "tag-plan"
            p = tag_plan(isempty(args) ? "." : only(args))
            if p.tag === nothing
                println("tag=\nreason=", p.reason)
            else
                println("tag=", p.tag, "\ntarget=", p.target, "\nprevious=", something(p.previous, ""),
                        "\nprerelease=", p.prerelease)
            end
            return 0
        end
    catch e
        e isa ArgumentError || rethrow()
        println(stderr, e.msg, "\n", USAGE)
        return 2
    end
    println(stderr, "unknown command `$command`\n", USAGE)
    return 2
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(release_main(ARGS))
end
