@testitem "verified_trait" setup = [TCFixtures] begin
    using Test
    using TypeContracts
    using .TCFixtures

    @testset "unverified type stays NotImplemented even though it satisfies the contract" begin
        # TGoodMeasurable/TBadMeasurable are never @verify'd anywhere in the fixtures —
        # check_contract alone (called directly by return_types_test.jl) must not seal.
        @test interface_trait(AbstractMeasurable, TGoodMeasurable) isa Implemented{AbstractMeasurable}
        @test verified_trait(AbstractMeasurable, TGoodMeasurable) isa NotImplemented{AbstractMeasurable}
        @test verified_trait(AbstractMeasurable, TBadMeasurable) isa NotImplemented{AbstractMeasurable}
    end

    @testset "types already @verify'd at fixture load time are sealed" begin
        @test verified_trait(AbstractCounter, TCounter) isa Implemented{AbstractCounter}
        @test verified_trait(AbstractSerializer, TJSONSerializer) isa Implemented{AbstractSerializer}
    end

    @testset "@verify seals Implemented, in front of interface_trait's existence-only check" begin
        abstract type AbstractGauge end
        function greading end
        @contract AbstractGauge begin
            greading(::Self)::Float64
        end
        struct GoodGauge <: AbstractGauge end
        greading(::GoodGauge) = 1.0

        @test verified_trait(AbstractGauge, GoodGauge) isa NotImplemented{AbstractGauge}
        @verify GoodGauge
        @test verified_trait(AbstractGauge, GoodGauge) isa Implemented{AbstractGauge}
    end

    @testset "wrong return type: @verify throws and never seals" begin
        abstract type AbstractGauge2 end
        function greading2 end
        @contract AbstractGauge2 begin
            greading2(::Self)::Float64
        end
        struct BadGauge2 <: AbstractGauge2 end
        greading2(::BadGauge2) = "not a float"

        @test_throws InterfaceError @verify BadGauge2
        @test verified_trait(AbstractGauge2, BadGauge2) isa NotImplemented{AbstractGauge2}
    end

    @testset "@verify_all seals every type it checks" begin
        @test TypeContracts.verified_trait(VerifyAllPass.AbstractWidget, VerifyAllPass.Button) isa
            Implemented{VerifyAllPass.AbstractWidget}
        @test TypeContracts.verified_trait(VerifyAllPass.AbstractWidget, VerifyAllPass.Label) isa
            Implemented{VerifyAllPass.AbstractWidget}
    end

    @testset "@verify subtypes=true seals every concrete subtype" begin
        abstract type AbstractDial end
        function dval end
        @contract AbstractDial begin
            dval(::Self)::Int
        end
        struct DialA <: AbstractDial end
        dval(::DialA) = 1
        struct DialB <: AbstractDial end
        dval(::DialB) = 2

        @verify AbstractDial subtypes = true
        @test verified_trait(AbstractDial, DialA) isa Implemented{AbstractDial}
        @test verified_trait(AbstractDial, DialB) isa Implemented{AbstractDial}
    end

    @testset "for_contract= seals the structural (non-subtyping) check" begin
        abstract type AbstractHolyProc end
        function holycall end
        @contract AbstractHolyProc begin
            holycall(::Self)::Int
        end
        struct HolyImpl end   # does not subtype AbstractHolyProc
        holycall(::HolyImpl) = 1

        @verify HolyImpl for_contract = AbstractHolyProc
        @test verified_trait(AbstractHolyProc, HolyImpl) isa Implemented{AbstractHolyProc}
    end

    @testset "@delegate seals the wrapper" begin
        @test verified_trait(DelegateStore, LoggedBox) isa Implemented{DelegateStore}
    end

    @testset "seal resolves Self return type via the concrete implementer" begin
        @verify TCloneGood
        @test verified_trait(AbstractCloneable, TCloneGood) isa Implemented{AbstractCloneable}
        # TCloneBad's tclone returns a String, not a TCloneBad — never verified, never sealed.
        @test verified_trait(AbstractCloneable, TCloneBad) isa NotImplemented{AbstractCloneable}
    end

    @testset "seal resolves parametric TypeParamRef return type" begin
        @verify IntBucket
        @test verified_trait(AbstractBucket, IntBucket) isa Implemented{AbstractBucket}
    end

    @testset "sealed dispatch is zero-allocation and constant-folds" begin
        @verify TCircle
        f(x::T) where {T} = verified_trait(AbstractShape, T)
        f(TCircle(1.0))  # warm up
        @test (@allocated f(TCircle(1.0))) == 0
    end
end
