# The README of a package: its template with the organization's shared texts and a badge
# table (docs/workflows/update-readme.md). Stdlib only.
#
# usage:
#   julia render.jl --template FILE --output FILE --package NAME --repo OWNER/REPO
#                   --doc-url URL [--citation MARKDOWN] [--about FILE] [--install FILE]
#                   [--contributing FILE]
#
# The shared texts default to ABOUT.md, INSTALL.md and CONTRIBUTING.md in the current
# directory. `{{PACKAGE}}` is replaced in INSTALL.md and `{{REPO}}` in CONTRIBUTING.md, and
# the substituted CONTRIBUTING.md is written back, since it is committed when it changed.

"Replace the line holding `marker` by `text`; the template unchanged when there is none."
function replace_line(template::AbstractString, marker::AbstractString, text::AbstractString)
    out = String[]
    for line in eachline(IOBuffer(template))
        if occursin(marker, line)
            push!(out, rstrip(text, '\n'))
        else
            push!(out, line)
        end
    end
    return join(out, "\n") * "\n"
end

"The badge row of one category, or `nothing` when there is none to show."
function badge_row(name, package, repo, doc_url, citation)
    name == "Documentation" && return "| **Documentation** | [![Stable Docs](https://img.shields.io/badge/docs-stable-blue.svg)]($doc_url/stable/) [![Dev Docs](https://img.shields.io/badge/docs-dev-8A2BE2.svg)]($doc_url/dev/) [![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/$repo) |"
    name == "CI" && return "| **CI / Build** | [![Build Status](https://github.com/$repo/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/$repo/actions/workflows/CI.yml?query=branch%3Amain) |"
    name == "Coverage" && return "| **Test Coverage** | [![Coverage](https://codecov.io/gh/$repo/branch/main/graph/badge.svg)](https://codecov.io/gh/$repo) |"
    name == "PackageEvaluation" && return "| **Package Evaluation** | [![PkgEval](https://img.shields.io/badge/Julia-package-purple)](https://juliahub.com/ui/Packages/General/$package) [![Dependencies](https://juliahub.com/docs/General/$package/stable/deps.svg)](https://juliahub.com/ui/Packages/General/$package?t=2) |"
    name == "Release" && return "| **Release / Version** | [![Release](https://img.shields.io/github/v/release/$repo.svg)](https://github.com/$repo/releases) |"
    name == "Citation" && return isempty(citation) ? nothing : "| **Citation** | $citation |"
    name == "License" && return "| **License** | [![License](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/$repo/blob/master/LICENSE) |"
    name == "CodeStyle" && return "| **Code Style / Quality** | [![Code Style: Blue](https://img.shields.io/badge/code%20style-blue-4495d1.svg)](https://github.com/JuliaDiff/BlueStyle) [![Aqua.jl](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl) |"
    name == "Downloads" && return "| **Downloads** | [![Monthly](https://img.shields.io/badge/dynamic/json?url=http%3A%2F%2Fjuliapkgstats.com%2Fapi%2Fv1%2Fmonthly_downloads/$package&query=total_requests&suffix=%2Fmonth&label=Monthly%20Downloads)](https://juliapkgstats.com/pkg/$package) [![Total](https://img.shields.io/badge/dynamic/json?url=http%3A%2F%2Fjuliapkgstats.com%2Fapi%2Fv1%2Ftotal_downloads/$package&query=total_requests&label=Total%20Downloads)](https://juliapkgstats.com/pkg/$package) |"
    return nothing   # an unknown category is ignored
end

"The badge table for the categories named in `<!-- INCLUDE_BADGES: A,B -->`."
function badge_table(list, package, repo, doc_url, citation)
    rows = ["| **Category** | **Badge** |", "|-----------------------|-----------|"]
    for name in split(list, r"[,\s]+"; keepempty=false)
        row = badge_row(name, package, repo, doc_url, citation)
        row === nothing || push!(rows, row)
    end
    return join(rows, "\n")
end

"""
    render(template, about, install, contributing; package, repo, doc_url, citation="")

Return `(readme, contributing)`: the README text and the CONTRIBUTING.md text with `{{REPO}}`
replaced.
"""
function render(template, about, install, contributing; package, repo, doc_url, citation="")
    install = replace(install, "{{PACKAGE}}" => package)
    contributing = replace(contributing, "{{REPO}}" => repo)
    text = replace_line(template, "<!-- INCLUDE_ABOUT -->", about)
    text = replace_line(text, "<!-- INCLUDE_INSTALL -->", install)
    text = replace_line(text, "<!-- INCLUDE_CONTRIBUTING -->", contributing)
    m = match(r"<!-- INCLUDE_BADGES:\s*(.*?)\s*-->", text)
    if m !== nothing
        text = replace_line(text, "<!-- INCLUDE_BADGES:", badge_table(m.captures[1], package, repo, doc_url, citation))
    end
    return text, contributing
end

function main(args)
    opts = Dict{String,String}("about" => "ABOUT.md", "install" => "INSTALL.md",
                               "contributing" => "CONTRIBUTING.md", "citation" => "")
    i = 1
    while i <= length(args)
        startswith(args[i], "--") && i < length(args) || error("bad arguments near ", args[i])
        opts[replace(replace(args[i], r"^--" => ""), "-" => "_")] = args[i+1]
        i += 2
    end
    for k in ("template", "output", "package", "repo", "doc_url")
        haskey(opts, k) || error("missing --", replace(k, "_" => "-"))
    end
    readme, contributing = render(read(opts["template"], String), read(opts["about"], String),
                                  read(opts["install"], String), read(opts["contributing"], String);
                                  package=opts["package"], repo=opts["repo"],
                                  doc_url=opts["doc_url"], citation=opts["citation"])
    write(opts["output"], readme)
    write(opts["contributing"], contributing)
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)
