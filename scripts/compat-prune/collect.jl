# Collect the audited files of every package.
#
# usage: julia collect.jl '<packages JSON list>' <out dir>
#
# The audited version of each package is the one the joint environment (all packages
# together) selects on the running Julia, i.e. what a user of the root package gets. Its
# files are read from the registered tree (manifest `git-tree-sha1`), not from a tag or a
# branch: default branches may have moved on, or a version may have been registered from
# another branch. The same files are also read from the default branch, to detect drift
# before editing anything.
#
# Output:
#   <out>/index.toml                  name => uuid, version, repo, tree, default_branch
#   <out>/registered/<name>/<file>    files of the registered tree
#   <out>/default/<name>/<file>       files of the default branch

include("common.jl")

const FILES = ("Project.toml", "test/Project.toml", "docs/Project.toml")

"Download the audited files present in tree `treeish` of `repo` into `dest`; return their paths."
function fetch_files(repo, treeish, dest)
    jq = ".tree[] | select(.type == \"blob\") | .path + \" \" + .sha"
    blobs = Dict(Tuple(split(l)) for l in split(gh_jq("repos/$repo/git/trees/$treeish?recursive=1", jq), '\n'))
    found = String[]
    for f in FILES
        haskey(blobs, f) || continue
        path = joinpath(dest, f)
        mkpath(dirname(path))
        write(path, gh_raw("repos/$repo/git/blobs/$(blobs[f])"))
        push!(found, f)
    end
    return found
end

packages = parse_list(ARGS[1])
out = ARGS[2]

lookup = Dict(n => registry_lookup(n) for n in packages)
joint = resolve_env(Dict(n => lookup[n][1] for n in packages), Dict())
joint["ok"] || error("The joint environment does not resolve on Julia $VERSION:\n$(joint["error"])")
versions = manifest_versions(joint["manifest"])
trees = manifest_trees(joint["manifest"])

index = Dict{String,Any}()
for n in packages
    uuid, repo = lookup[n]
    branch = gh_jq("repos/$repo", ".default_branch")
    registered = fetch_files(repo, trees[n], joinpath(out, "registered", n))
    default = fetch_files(repo, branch, joinpath(out, "default", n))
    index[n] = Dict("uuid" => uuid, "version" => versions[n], "repo" => repo, "tree" => trees[n],
                    "default_branch" => branch, "files" => registered, "default_files" => default)
    println(rpad(n, 16), rpad(versions[n], 14), repo, "  [", join(registered, ", "), "]")
end
open(io -> TOML.print(io, Dict("julia" => string(VERSION), "packages" => index)), joinpath(out, "index.toml"), "w")
