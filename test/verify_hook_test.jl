@testitem "verify hook" begin
    using Test
    using TypeContracts

    # Each fixture restricts its hook method to its own types, so other test items
    # are unaffected.
    @eval module VHOwner
    using TypeContracts
    abstract type AbstractHooked end
    @contract AbstractHooked begin
        hk(::Self)::Int
    end
    end
    using .VHOwner: AbstractHooked

    @eval module VH
    using TypeContracts, ..VHOwner
    const CALLS = Any[]
    record(mod, T, result) = (push!(CALLS, (mod, T, result)); nothing)

    struct HookT <: VHOwner.AbstractHooked end
    struct HookF end
    abstract type SubFam <: VHOwner.AbstractHooked end
    struct HookS <: SubFam end
    struct Inner <: VHOwner.AbstractHooked end
    mutable struct Wrapper <: VHOwner.AbstractHooked
        inner::Inner
    end
    VHOwner.hk(::Union{HookT, HookF, HookS, Inner}) = 1
    TypeContracts._verify_hook(
        ::TypeContracts._VerifyHook, mod::Module, T::Type{<:Union{HookT, HookF, HookS, Wrapper}}, result
    ) = record(mod, T, result)

    @verify HookT
    @verify HookF for_contract = VHOwner.AbstractHooked
    @verify SubFam subtypes = true
    @delegate Wrapper :inner VHOwner.AbstractHooked
    end

    calls(T) = filter(c -> c[2] === T, VH.CALLS)

    @testset "called once per verified type, with module and result" begin
        for T in (VH.HookT, VH.HookF, VH.HookS, VH.Wrapper)
            c = only(calls(T))
            @test c[1] === VH
            @test c[3].type === T
            @test c[3].passed
            @test c[3].contracts == [AbstractHooked]
        end
    end

    @testset "@verify_all calls the hook for each type" begin
        @eval module VHAll
        using TypeContracts, ..VHOwner
        const CALLS = Any[]
        struct AllA <: VHOwner.AbstractHooked end
        struct AllB <: VHOwner.AbstractHooked end
        VHOwner.hk(::Union{AllA, AllB}) = 1
        TypeContracts._verify_hook(::TypeContracts._VerifyHook, mod::Module, T::Type{<:Union{AllA, AllB}}, result) =
            (push!(CALLS, (mod, T)); nothing)
        @verify_all
        end
        @test Set(VHAll.CALLS) == Set([(VHAll, VHAll.AllA), (VHAll, VHAll.AllB)])
    end

    @testset "a throwing hook fails verification and leaves the type unsealed" begin
        @test_throws "gate" @eval module VHBad
        using TypeContracts, ..VHOwner
        struct HookBad <: VHOwner.AbstractHooked end
        VHOwner.hk(::HookBad) = 1
        TypeContracts._verify_hook(::TypeContracts._VerifyHook, ::Module, ::Type{HookBad}, result) = error("gate")
        @verify HookBad
        end
        @test verified_trait(AbstractHooked, VHBad.HookBad) === NotImplemented{AbstractHooked}()
    end

    @testset "@verify_all: a throwing hook on one type does not unseal another" begin
        @test_throws "gate" @eval module VHMixed
        using TypeContracts, ..VHOwner
        struct MixGood <: VHOwner.AbstractHooked end
        struct MixBad <: VHOwner.AbstractHooked end
        VHOwner.hk(::Union{MixGood, MixBad}) = 1
        TypeContracts._verify_hook(::TypeContracts._VerifyHook, ::Module, ::Type{MixBad}, result) = error("gate")
        @verify MixGood
        @verify_all
        end
        @test verified_trait(AbstractHooked, VHMixed.MixGood) === Implemented{AbstractHooked}()
        @test verified_trait(AbstractHooked, VHMixed.MixBad) === NotImplemented{AbstractHooked}()
    end

    @testset "@verify_all: a type it sealed stays sealed when a later hook throws" begin
        @test_throws "gate" @eval module VHOrder
        using TypeContracts, ..VHOwner
        struct AAGood <: VHOwner.AbstractHooked end
        struct ZZBad <: VHOwner.AbstractHooked end
        VHOwner.hk(::Union{AAGood, ZZBad}) = 1
        TypeContracts._verify_hook(::TypeContracts._VerifyHook, ::Module, ::Type{ZZBad}, result) = error("gate")
        @verify_all
        end
        # `@verify_all` visits types in `names` order; this test relies on AAGood first.
        ns = names(VHOrder; all = true)
        @test findfirst(==(:AAGood), ns) < findfirst(==(:ZZBad), ns)
        @test verified_trait(AbstractHooked, VHOrder.AAGood) === Implemented{AbstractHooked}()
        @test verified_trait(AbstractHooked, VHOrder.ZZBad) === NotImplemented{AbstractHooked}()
    end

    @testset "the Revise re-check reports a hook exception as a warning" begin
        @eval module VHRevise
        using TypeContracts, ..VHOwner
        struct HookBad2 <: VHOwner.AbstractHooked end
        VHOwner.hk(::HookBad2) = 1
        TypeContracts._verify_hook(::TypeContracts._VerifyHook, ::Module, ::Type{HookBad2}, result) = error("gate")
        end
        @test_logs (:warn, "Contract re-check failed") match_mode = :any TypeContracts._check_contract_warn(VHRevise, VHRevise.HookBad2)
    end
end
