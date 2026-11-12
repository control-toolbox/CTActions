# The registration of a beta in ct-registry (a beta never goes to General, REL6): done
# here, once, from the merge commit of the release PR, with LocalRegistry, and checked
# afterwards — ct-registry must hold the version at the tree of the tag (REL5). Stdlib only
# itself: LocalRegistry is installed in a throwaway environment of a child process. Needs
# `gh` and `git`, and push access to ct-registry (the release-finish workflow sets up git
# with the App's token).

@isdefined(facts) || include(joinpath(@__DIR__, "status.jl"))

"The clone URL of ct-registry, the registry of the betas."
const CT_REGISTRY_GIT = "https://github.com/control-toolbox/ct-registry.git"

# The command runner of the registration: a function of a `Cmd`, returning whether it
# succeeded. Tests replace it.
@isdefined(RUN) || global RUN = Ref{Any}(cmd -> success(pipeline(cmd; stdout=stderr, stderr=stderr)))

"Run by a child Julia: register the package clone `ARGS[1]` in the registry clone `ARGS[2]`, and push."
const LOCALREGISTRY_SCRIPT = """
    using Pkg
    Pkg.activate(; temp=true)
    Pkg.add("LocalRegistry")
    using LocalRegistry
    register(ARGS[1]; registry=ARGS[2], repo=ARGS[3], commit=true, push=true)
    """

"""
    register_beta(repo, version; confirm=false, tries=12, pause=30) -> (Bool, String)

Register the beta `version` of `repo` in ct-registry, from the merge commit of its release
PR: only when `status` says phase 7, todo (tagged on the merge commit, pre-release, not
registered yet); nothing to do when ct-registry already holds it at the tree of the tag.
Then read ct-registry again until it shows the version (`tries` times, `pause` seconds
apart: its raw files are cached for a few minutes) and check the tree. Without `confirm`, a
dry run. Returns whether it succeeded, and what to report.
"""
function register_beta(repo::AbstractString, version; confirm::Bool=false, tries::Integer=12, pause::Real=30)
    f = facts(repo; version)
    f.kind === :beta || return (false, "`$(f.version)` is a stable: it goes to General, with `release.jl register` (REL6)")
    p = phase(f)
    f.registered !== nothing && f.registered == f.tag_tree &&
        return (true, "ct-registry already holds `$(f.version)` at the tree of the tag: nothing to do")
    (p.phase == 7 && p.state === :todo) ||
        return (false, "not ready: phase $(p.phase), $(p.state): $(p.next)" * join(("\n- $b" for b in p.blockers)))
    confirm || return (true, "Dry run: `--confirm` registers $(f.pr.merge) of $repo in ct-registry with LocalRegistry, then checks the registered tree")
    dir = mktempdir()
    pkg, reg = joinpath(dir, "package"), joinpath(dir, "ct-registry")
    steps = [`git clone --quiet https://github.com/$repo.git $pkg`,
             `git -C $pkg checkout --quiet --detach $(f.pr.merge)`,
             `git clone --quiet $CT_REGISTRY_GIT $reg`,
             `$(Base.julia_cmd()) --startup-file=no -e $LOCALREGISTRY_SCRIPT $pkg $reg https://github.com/$repo.git`]
    for c in steps
        RUN[](c) || return (false, "failed: `$(join(c.exec, ' '))`; check ct-registry before anything else")
    end
    for i in 1:tries
        after = facts(repo; version=f.version)
        if after.registered !== nothing
            after.registered == after.tag_tree ||
                return (false, "registered, but ct-registry holds the tree $(after.registered), not the tree of `v$(f.version)` ($(after.tag_tree)): a human checks")
            return (true, "registered `$(f.version)` in ct-registry, from $(f.pr.merge), at the tree of the tag")
        end
        i < tries && sleep(pause)
    end
    return (false, "pushed to ct-registry, but it does not show `$(f.version)` after $(tries) reads: check it, then rerun `status`")
end
