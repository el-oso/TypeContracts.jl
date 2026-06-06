# Trim / juliac compatibility tests.
#
# JET.@test_opt verifies no runtime dispatch in TypeContracts' own code.
# TrimCheck.@validate runs juliac's static-trim verifier in a fresh process and
# asserts zero trim errors for interface_trait — which is a @generated function
# precisely so the contract is resolved at code-generation time and the body
# emitted as concrete hasmethod(f, Tuple{…}) calls (no runtime registry lookup,
# no abstract Function, no dynamic signature).
#
# JET and TrimCheck are imported at the top of runtests.jl.

# ── JET: no runtime dispatch in our code ──────────────────────────────────────

@testset "JET.@test_opt — no runtime dispatch in TypeContracts" begin
    # AbstractRT / RTGood / RTBad are module-scope fixtures defined in
    # runtests.jl; this file is included from inside that top @testset.
    @testset "non-parametric contract (RTGood satisfies)" begin
        @test_opt target_modules = (TypeContracts,) interface_trait(AbstractRT, RTGood)
    end

    @testset "non-parametric contract (RTBad does not satisfy)" begin
        @test_opt target_modules = (TypeContracts,) interface_trait(AbstractRT, RTBad)
    end
end

# ── TrimCheck: interface_trait passes juliac --trim verification ──────────────
#
# `init` runs in a fresh worker process. It is a self-contained module so its
# body is evaluated incrementally — `using TypeContracts` takes effect before the
# `@contract` macro on the next line expands. The validated calls reach the
# fixture's types and function through that module.
TrimCheck.@validate(
    TCTrimFixture.interface_trait(Type{TCTrimFixture.TCShape}, Type{TCTrimFixture.TCCircle}),
    TCTrimFixture.interface_trait(Type{TCTrimFixture.TCShape}, Type{Int}),
    errors_limit = Inf,
    warnings_limit = Inf,
    init = module TCTrimFixture
        using TypeContracts
        abstract type TCShape end
        function tc_area end
        @contract TCShape begin
            tc_area(::Self) :: Float64
        end
        struct TCCircle <: TCShape
            r::Float64
        end
        tc_area(c::TCCircle)::Float64 = π * c.r^2
    end,
)
