@testitem "TrimCheck and JET" setup = [TCFixtures] tags = [:slow] begin
    using Test
    using TypeContracts
    using .TCFixtures
    using JET: @test_opt
    import TrimCheck

    @testset "JET.@test_opt — no runtime dispatch in TypeContracts" begin
        @testset "non-parametric contract (RTGood satisfies)" begin
            @test_opt target_modules = (TypeContracts,) interface_trait(AbstractRT, RTGood)
        end

        @testset "non-parametric contract (RTBad does not satisfy)" begin
            @test_opt target_modules = (TypeContracts,) interface_trait(AbstractRT, RTBad)
        end

        @testset "verified_trait — unsealed fallback" begin
            @test_opt target_modules = (TypeContracts,) verified_trait(AbstractRT, RTGood)
        end

        @testset "verified_trait — sealed by @verify" begin
            abstract type TCVShape end
            function tcv_area end
            @contract TCVShape begin
                tcv_area(::Self)::Float64
            end
            struct TCVCircle <: TCVShape
                r::Float64
            end
            tcv_area(c::TCVCircle) = π * c.r^2
            @verify TCVCircle

            @test_opt target_modules = (TypeContracts,) verified_trait(TCVShape, TCVCircle)
        end
    end

    TrimCheck.@validate(
        TCTrimFixture.interface_trait(Type{TCTrimFixture.TCShape}, Type{TCTrimFixture.TCCircle}),
        TCTrimFixture.interface_trait(Type{TCTrimFixture.TCShape}, Type{Int}),
        TCTrimFixture.verified_trait(Type{TCTrimFixture.TCShape}, Type{TCTrimFixture.TCCircle}),
        TCTrimFixture.verified_trait(Type{TCTrimFixture.TCShape}, Type{Int}),
        errors_limit = Inf,
        warnings_limit = Inf,
        init = module TCTrimFixture
        using TypeContracts
        abstract type TCShape end
        function tc_area end
        @contract TCShape begin
            tc_area(::Self)::Float64
        end
        struct TCCircle <: TCShape
            r::Float64
        end
        tc_area(c::TCCircle)::Float64 = π * c.r^2
        @verify TCCircle
        end,
    )
end
