#!/usr/bin/env bash
# Shallow clone of the default branch of every audited package.
#
# usage: checkout.sh <audit dir> <checkouts dir>
#
# Reads <audit dir>/index.toml; clones https://github.com/<repo> into <checkouts dir>/<name>.
# Pushing later relies on git's credentials (`gh auth setup-git` in the publish job).
set -euo pipefail
audit=$1
checkouts=$2
mkdir -p "$checkouts"
julia --startup-file=no -e 'using TOML
    for (n, p) in sort(collect(TOML.parsefile(ARGS[1])["packages"]))
        println(n, " ", p["repo"], " ", p["default_branch"])
    end' "$audit/index.toml" |
while read -r name repo branch; do
    git clone --quiet --depth 1 --branch "$branch" "https://github.com/$repo.git" "$checkouts/$name"
done
