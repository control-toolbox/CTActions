#!/usr/bin/env bash
# Shallow clone of the default branch of every audited package.
#
# usage: checkout.sh <audit dir> <checkouts dir>
#
# Reads <audit dir>/index.toml; clones $COMPAT_PRUNE_GIT_BASE/<repo>.git (default
# https://github.com; tests point it at local repositories) into <checkouts dir>/<name>.
# Pushing later relies on git's credentials (`gh auth setup-git` in the publish job).
set -euo pipefail
audit=$1
checkouts=$2
mkdir -p "$checkouts"
julia --startup-file=no -e 'using TOML
    for (n, p) in sort(collect(TOML.parsefile(ARGS[1])["packages"]); by=first)
        println(n, " ", p["repo"], " ", p["default_branch"])
    end' "$audit/index.toml" |
while read -r name repo branch; do
    git clone --quiet --depth 1 --branch "$branch" "${COMPAT_PRUNE_GIT_BASE:-https://github.com}/$repo.git" "$checkouts/$name"
done
