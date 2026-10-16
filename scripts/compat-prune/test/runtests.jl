# Tests of compat-prune.
#
# usage: julia scripts/compat-prune/test/runtests.jl
#
#   COMPAT_PRUNE_INTEGRATION=1    also run the integration tests (real Pkg resolutions against
#                                 the local General registry, nothing downloaded; seconds)
#   COMPAT_PRUNE_UPDATE_GOLDEN=1  rewrite the golden files instead of comparing to them
#
# Unit tests run on fixtures and fakes (no network, no resolution): the `gh` runner (`GH`)
# and the resolver of `simulate` are replaced by functions recording their calls.

using Test

include("helpers.jl")

@testset "compat-prune" begin
    include("test_common.jl")
    include("test_collect.jl")
    include("test_envs.jl")
    include("test_classify.jl")
    include("test_validate.jl")
    include("test_audit.jl")
    include("test_edit.jl")
    include("test_report.jl")
    include("test_publish.jl")
    include("test_regression.jl")
    if get(ENV, "COMPAT_PRUNE_INTEGRATION", "") == "1"
        include("test_integration.jl")
    else
        @info "Integration tests skipped (set COMPAT_PRUNE_INTEGRATION=1)"
    end
end
