@testitem "Parametric types in bulk verification" begin
    using Test
    using TypeContracts

    @eval module PSOwner
    using TypeContracts
    abstract type AbstractBucketP{T} end
    @contract AbstractBucketP{T} begin
        get1(::Self)::T
    end
    end
    using .PSOwner: AbstractBucketP

    @testset "@verify_all skips a parametric type with a warning" begin
        mod = @test_logs (:warn, r"@verify_all skipped Bad") match_mode = :any @eval module PSBad
        using TypeContracts, ..PSOwner
        struct Bad{T} <: PSOwner.AbstractBucketP{T} end
        PSOwner.get1(::Bad) = "nope"
        const _result = @verify_all
        end
        @test !(PSBad.Bad in PSBad._result.types)
        @test verified_trait(AbstractBucketP, PSBad.Bad) === NotImplemented{AbstractBucketP}()
        @test verified_trait(AbstractBucketP, PSBad.Bad{Int}) === NotImplemented{AbstractBucketP}()
    end

    @testset "a verified instance silences the warning" begin
        @test_logs @eval module PSGood
        using TypeContracts, ..PSOwner
        struct Good{T} <: PSOwner.AbstractBucketP{T}
            x::T
        end
        PSOwner.get1(g::Good) = g.x
        @verify Good{Int}
        @verify_all
        end
        @test verified_trait(AbstractBucketP, PSGood.Good{Int}) === Implemented{AbstractBucketP}()
    end

    @testset "a type parameter fixed by the subtype is still checked" begin
        @test_throws "String ⊄ Int64" @eval module PSFixed
        using TypeContracts, ..PSOwner
        struct IntBucket <: PSOwner.AbstractBucketP{Int} end
        PSOwner.get1(::IntBucket) = "x"
        @verify_all
        end
    end

    @testset "the example instance fills every type parameter" begin
        @test_logs (:warn, r"@verify Pair2\{Int, Int\}") match_mode = :any @eval module PSPair
        using TypeContracts, ..PSOwner
        struct Pair2{A, B} <: PSOwner.AbstractBucketP{A} end
        PSOwner.get1(::Pair2{A}) where {A} = zero(A)
        @verify_all
        end
    end

    @testset "a for_contract verification silences the warning" begin
        @test_logs @eval module PSFor
        using TypeContracts, ..PSOwner
        struct Good3{T} <: PSOwner.AbstractBucketP{T}
            x::T
        end
        PSOwner.get1(g::Good3) = g.x
        @verify Good3{Int} for_contract = PSOwner.AbstractBucketP
        @verify_all
        end
    end

    @testset "@verify subtypes=true skips a parametric type with a warning" begin
        @eval module PSSubOwner
        using TypeContracts
        abstract type AbstractBoxS{T} end
        @contract AbstractBoxS{T} begin
            get2(::Self)::T
        end
        struct BadBox{T} <: AbstractBoxS{T} end
        get2(::BadBox) = "nope"
        end
        @test_logs (:warn, r"@verify .*AbstractBoxS subtypes=true skipped BadBox") (:warn, r"no concrete subtypes found") match_mode = :any Core.eval(PSSubOwner, :(@verify AbstractBoxS subtypes = true))
        @test verified_trait(PSSubOwner.AbstractBoxS, PSSubOwner.BadBox) === NotImplemented{PSSubOwner.AbstractBoxS}()
    end

    @testset "a parametric @delegate wrapper silences the warning" begin
        @test_logs @eval module PSDel
        using TypeContracts, ..PSOwner
        struct Inner <: PSOwner.AbstractBucketP{Int} end
        PSOwner.get1(::Inner) = 1
        struct Wr{T} <: PSOwner.AbstractBucketP{T}
            inner::Inner
        end
        @delegate Wr :inner PSOwner.AbstractBucketP
        @verify_all
        end
    end

    @testset "a parametric type missing a method still fails" begin
        @test_throws "get1(::Self)" @eval module PSMissing
        using TypeContracts, ..PSOwner
        struct NoMethod{T} <: PSOwner.AbstractBucketP{T} end
        @verify_all
        end
        @test verified_trait(AbstractBucketP, PSMissing.NoMethod) === NotImplemented{AbstractBucketP}()
    end

    @testset "an alias warns once" begin
        logs = Test.collect_test_logs() do
            @eval module PSAlias
            using TypeContracts, ..PSOwner
            struct Al{T} <: PSOwner.AbstractBucketP{T} end
            PSOwner.get1(::Al) = 1
            const AlAlias = Al
            @verify_all
            end
        end[1]
        @test count(l -> occursin("skipped Al", l.message), logs) == 1
    end

    @testset "the example instance respects parameter bounds" begin
        @test_logs (:warn, r"@verify Fl\{Float64\}") match_mode = :any @eval module PSBound
        using TypeContracts, ..PSOwner
        struct Fl{T <: AbstractFloat} <: PSOwner.AbstractBucketP{T} end
        PSOwner.get1(::Fl{T}) where {T} = zero(T)
        @verify_all
        end
    end

    @testset "a Union alias in the module is ignored" begin
        @test_nowarn @eval module PSUnion
        using TypeContracts, ..PSOwner
        struct UA <: PSOwner.AbstractBucketP{Int} end
        struct UB <: PSOwner.AbstractBucketP{Int} end
        PSOwner.get1(::Union{UA, UB}) = 1
        const UAB = Union{UA, UB}
        @verify_all
        end
    end

    @testset "the Revise re-check does not repeat the skip warning" begin
        @test_logs TypeContracts._revise_check_module(PSBad)
    end

    @testset "the Revise re-check reports a parametric type missing a method" begin
        @test_logs (:warn, "Contract violation detected by Revise") match_mode = :any TypeContracts._revise_check_module(PSMissing)
    end
end
