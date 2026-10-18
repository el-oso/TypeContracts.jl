@testitem "repeated verification of a type keeps its first seal" begin
    using Test
    using TypeContracts

    @eval module RepSeal
    using TypeContracts
    abstract type AbstractRep end
    @contract AbstractRep begin
        rep(::Self)::Int
    end
    struct R <: AbstractRep end
    rep(::R) = 1
    @verify R
    const FIRST = which(TypeContracts.verified_trait, Tuple{Type{AbstractRep}, Type{R}})
    @verify R
    @verify R for_contract = AbstractRep
    @verify AbstractRep subtypes = true
    @verify_all
    end

    @test which(TypeContracts.verified_trait, Tuple{Type{RepSeal.AbstractRep}, Type{RepSeal.R}}) ===
        RepSeal.FIRST
    @test verified_trait(RepSeal.AbstractRep, RepSeal.R) isa Implemented
end

@testitem "@delegate when the function's module is not bound in the caller" begin
    using Test
    using TypeContracts

    # `Module` creates a module that is not bound under its own name anywhere.
    DA = Module(:DelegOwner)
    Core.eval(DA, :(using TypeContracts))
    Core.eval(
        DA, quote
            abstract type AbstractStore end
            @contract AbstractStore begin
                fetch_val(::Self)::Int
            end
        end
    )
    struct Inner <: DA.AbstractStore end
    Core.eval(DA, :(fetch_val(::$Inner) = 7))
    struct Wrap <: DA.AbstractStore
        inner::Inner
    end
    @eval @delegate Wrap :inner $(DA.AbstractStore)
    @test DA.fetch_val(Wrap(Inner())) == 7
    @test verified_trait(DA.AbstractStore, Wrap) isa Implemented
end

@testitem "test macros work when only the macros are imported" begin
    using Test
    using TypeContracts

    @eval module TIOwner
    using TypeContracts
    abstract type AbstractTI end
    @contract AbstractTI begin
        ti(::Self)::Int
    end
    @invariants AbstractTI begin
        "ti is positive" => x -> ti(x) > 0
    end
    struct T1 <: AbstractTI end
    ti(::T1) = 1
    end

    @eval module TIUser
    using Test
    using TypeContracts: @test_implements, @test_behavior_passes
    using ..TIOwner
    @testset "inner" begin
        @test_implements TIOwner.T1 TIOwner.AbstractTI
        @test_behavior_passes TIOwner.T1 [TIOwner.T1()]
    end
    end

    @test !isdefined(TIUser, :TypeContracts)
end

@testitem "interface_trait ignores a hasmethod defined by the registering module" begin
    using Test
    using TypeContracts

    @eval module OwnHasmethod
    using TypeContracts
    const CALLED = Ref(false)
    hasmethod(args...) = (CALLED[] = true; false)
    abstract type AbstractHM end
    @contract AbstractHM begin
        hm(::Self)
    end
    struct H <: AbstractHM end
    hm(::H) = 1
    end

    @test interface_trait(OwnHasmethod.AbstractHM, OwnHasmethod.H) isa Implemented
    @test !OwnHasmethod.CALLED[]
end

@testitem "Vararg arguments in a contract" begin
    using Test
    using TypeContracts

    @eval module VA
    using TypeContracts
    abstract type AbstractVA end
    @contract AbstractVA begin
        vsum(::Self, ::Vararg{Int})::Int
    end
    struct In <: AbstractVA end
    vsum(::In, xs::Int...) = sum(xs; init = 0)
    struct Out <: AbstractVA
        inner::In
    end
    @delegate Out :inner AbstractVA
    @verify In
    end

    @test interface_trait(VA.AbstractVA, VA.In) isa Implemented
    @test satisfies(VA.In, VA.AbstractVA).satisfied
    @test VA.vsum(VA.Out(VA.In()), 1, 2, 3) == 6
end

@testitem "Self and type parameters nested inside argument and return types" begin
    using Test
    using TypeContracts

    @eval module Nest
    using TypeContracts
    abstract type AbstractBlob end
    @contract AbstractBlob begin
        decode(::Type{Self}, ::Vector{UInt8})::Self
    end
    struct Blob <: AbstractBlob end
    decode(::Type{Blob}, ::Vector{UInt8}) = Blob()
    @verify Blob

    abstract type AbstractBag{T} end
    @contract AbstractBag{T} begin
        put(::Self, ::Vector{T})::Vector{T}
        pairs_of(::Self)::Vector{Pair{T, Self}}
    end
    struct Bag <: AbstractBag{Int} end
    put(::Bag, v::Vector{Int}) = v
    pairs_of(b::Bag) = [1 => b]
    @verify Bag

    struct BadBag <: AbstractBag{Int} end
    put(::BadBag, v::Vector{Int}) = Float64.(v)
    pairs_of(b::BadBag) = [1 => b]
    end

    @test interface_trait(Nest.AbstractBlob, Nest.Blob) isa Implemented
    @test verified_trait(Nest.AbstractBag, Nest.Bag) isa Implemented
    @test interface_trait(Nest.AbstractBag, Nest.Bag) isa Implemented
    @test_throws "return Vector{Float64} ⊄ Vector{Int64}" check_contract(Nest.BadBag)
end

@testitem "@delegate rejects an argument that nests Self" begin
    using Test
    using TypeContracts

    @eval module NestDel
    using TypeContracts
    abstract type AbstractND end
    @contract AbstractND begin
        build(::Type{Self})
    end
    struct I <: AbstractND end
    build(::Type{I}) = I()
    struct W <: AbstractND
        inner::I
    end
    end

    @test_throws "cannot forward an argument of type Type{Self}" @eval NestDel @delegate W :inner AbstractND
end

@testitem "@verify of a bare parametric name checks method existence only" begin
    using Test
    using TypeContracts

    @eval module BareV
    using TypeContracts
    abstract type AbstractSum{T} end
    @contract AbstractSum{T} begin
        hsum(::Self)::Real
    end
    struct Bucket{T} <: AbstractSum{T}
        data::Vector{T}
    end
    hsum(b::Bucket) = sum(b.data)
    @verify Bucket
    @verify Bucket{Int}
    end

    @test verified_trait(BareV.AbstractSum, BareV.Bucket{Int}) isa Implemented
end

@testitem "@invariants on a parameterized type runs for its subtypes" begin
    using Test
    using TypeContracts

    @eval module InvP
    using TypeContracts
    abstract type AbstractP{T} end
    @invariants AbstractP{Int} begin
        "value is positive" => x -> x.v > 0
    end
    struct P <: AbstractP{Int}
        v::Int
    end
    end

    r = test_behavior(InvP.P, [InvP.P(-1)])
    @test !r.passed
    @test only(r.results).description == "value is positive"
end

@testitem "@contract accepts a qualified type name" begin
    using Test
    using TypeContracts

    @eval module QOwner
    abstract type AbstractQ end
    abstract type AbstractQP{T} end
    end

    @eval module QUser
    using TypeContracts
    using ..QOwner
    @contract QOwner.AbstractQ begin
        qv(::Self)::Int
    end
    @contract QOwner.AbstractQP{T} begin
        qp(::Self)::T
    end
    struct Q <: QOwner.AbstractQ end
    qv(::Q) = 1
    struct QP <: QOwner.AbstractQP{Int} end
    qp(::QP) = 1
    @verify Q
    @verify QP
    end

    @test verified_trait(QOwner.AbstractQ, QUser.Q) isa Implemented
    @test verified_trait(QOwner.AbstractQP, QUser.QP) isa Implemented
end

@testitem "@verify options may be variables of the calling module" begin
    using Test
    using TypeContracts

    @eval module OptVar
    using TypeContracts
    abstract type AbstractOV end
    @contract AbstractOV begin
        ov(::Self)::Int
    end
    struct O <: AbstractOV end
    ov(::O) = 1
    const CHECK_TRIM = true
    @verify O trim_compat = CHECK_TRIM
    @verify_all trim_compat = CHECK_TRIM
    end

    @test verified_trait(OptVar.AbstractOV, OptVar.O) isa Implemented
end

@testitem "structural check against a parameterized interface" begin
    using Test
    using TypeContracts

    @eval module StructP
    using TypeContracts
    abstract type AbstractGet{T} end
    @contract AbstractGet{T} begin
        pget(::Self, ::T)::T
    end
    struct Impl end
    pget(::Impl, x::Int) = x
    @verify Impl for_contract = AbstractGet{Int}
    end

    @test satisfies(StructP.Impl, StructP.AbstractGet{Int}).satisfied
    @test !satisfies(StructP.Impl, StructP.AbstractGet{String}).satisfied
    @test verified_trait(StructP.AbstractGet, StructP.Impl) isa Implemented
end

@testitem "the Revise re-check of a structural type uses its interface" begin
    using Test
    using TypeContracts

    @eval module RevS
    using TypeContracts
    abstract type AbstractRS end
    @contract AbstractRS begin
        rs(::Self)::Int
    end
    struct S end
    rs(::S) = 1
    @verify S for_contract = AbstractRS
    end

    @test (RevS, RevS.S, RevS.AbstractRS) in TypeContracts._revise_tracked_types
    @test TypeContracts._check_contract_warn(RevS, RevS.S, RevS.AbstractRS).passed
    Core.eval(RevS, :(rs(::S) = "one"))
    @test_logs (:warn, "Contract violation detected by Revise") match_mode = :any TypeContracts._check_contract_warn(
        RevS, RevS.S, RevS.AbstractRS
    )
end

@testitem "list_contract of a parameterized type" begin
    using Test
    using TypeContracts

    @eval module LCP
    using TypeContracts
    abstract type AbstractLC{T} end
    @contract AbstractLC{T} begin
        lc(::Self)::T
    end
    end

    @test length(list_contract(LCP.AbstractLC{Int})) == 1
end

@testitem "packages using these forms precompile" begin
    using Test
    using TypeContracts

    # Packages in a `LOAD_PATH` directory, without project files, may load any package
    # in the environment.
    dir = mktempdir()
    function package(name, code)
        mkpath(joinpath(dir, name, "src"))
        write(joinpath(dir, name, "src", "$name.jl"), code)
        return Base.PkgId(name)
    end
    owner = package(
        "TCPrecompOwner", """
        module TCPrecompOwner
        using TypeContracts
        abstract type AbstractOwned end
        @contract AbstractOwned begin
            owned(::Self)::Int
        end
        struct Owned <: AbstractOwned end
        owned(::Owned) = 1
        @verify Owned
        @verify Owned for_contract = AbstractOwned
        @verify AbstractOwned subtypes = true
        @verify_all
        end
        """
    )
    # Imports the function only: the name `TCPrecompOwner` is not bound here.
    delegator = package(
        "TCPrecompDelegator", """
        module TCPrecompDelegator
        import TypeContracts
        using TCPrecompOwner: AbstractOwned
        import TCPrecompOwner: owned
        struct Inner end
        owned(::Inner) = 2
        struct Wrap <: AbstractOwned
            inner::Inner
        end
        TypeContracts.@delegate Wrap :inner AbstractOwned
        TypeContracts.@verify_all
        end
        """
    )
    reregister = package(
        "TCPrecompReregister", """
        module TCPrecompReregister
        using TypeContracts, TCPrecompOwner
        @contract TCPrecompOwner.AbstractOwned begin
            owned(::Self)::Int
        end
        end
        """
    )

    # A fresh process precompiles against the TypeContracts source on disk, not the
    # build loaded in this one.
    script = """
    pushfirst!(LOAD_PATH, $(repr(dir)))
    for name in $(repr([owner.name, delegator.name, reregister.name]))
        err = IOBuffer()
        failed = try
            Base.compilecache(Base.PkgId(name), err, devnull) isa Exception
        catch
            true
        end
        println(name, " ", failed ? "failed" : "ok", " ", repr(String(take!(err))))
    end
    """
    out = readchomp(`$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $script`)
    results = Dict(
        String(m[1]) => (m[2], m[3])
            for m in eachmatch(r"^(TCPrecomp\w+) (ok|failed) (.*)$"m, out)
    )
    @test results["TCPrecompOwner"][1] == "ok"
    @test results["TCPrecompDelegator"][1] == "ok"
    @test results["TCPrecompReregister"][1] == "failed"
    @test occursin(
        "already has contract registered in module TCPrecompOwner",
        results["TCPrecompReregister"][2]
    )
end

@testitem "@verify and @verify_all reject an unknown option" begin
    using Test
    using TypeContracts

    @eval module UnknownOpt
    using TypeContracts
    abstract type AbstractUO end
    @contract AbstractUO begin
        uo(::Self)
    end
    struct U <: AbstractUO end
    uo(::U) = 1
    end

    @test_throws "@verify: unknown option `subtype`" @eval UnknownOpt @verify U subtype = true
    @test_throws "@verify_all: unknown option `trimcompat`" @eval UnknownOpt @verify_all trimcompat = true
end

@testitem "@contract rejects a header with more parameters than the type" begin
    using Test
    using TypeContracts

    @eval module Arity
    using TypeContracts
    abstract type Two{A, B} end
    end

    @test_throws "@contract: the header names 3 type parameters, but" @eval Arity @contract Two{A, B, C} begin
        tf(::Self)::C
    end
end

@testitem "Self and type parameters inside UnionAll argument types" begin
    using Test
    using TypeContracts

    @eval module NestUA
    using TypeContracts
    abstract type AbstractUA{T} end
    @contract AbstractUA{T} begin
        sumall(::Self, ::AbstractArray{T})::T
        mk(::Type{<:Self})
    end
    struct U <: AbstractUA{Int} end
    sumall(::U, a::AbstractArray{Int})::Int = sum(a)
    mk(::Type{<:U}) = U()
    end

    @test satisfies(NestUA.U, NestUA.AbstractUA).satisfied
    @test interface_trait(NestUA.AbstractUA, NestUA.U) isa Implemented
end

@testitem "@contract rejects a type alias" begin
    using Test
    using TypeContracts

    @eval module AliasC
    using TypeContracts
    end
    @test_throws "@contract: AbstractVector is an alias of AbstractArray" @eval AliasC @contract AbstractVector{T} begin
        firstel(::Self)::T
    end
end

@testitem "@verify of a bare parametric name does not seal verified_trait" begin
    using Test
    using TypeContracts

    @eval module BareNoSeal
    using TypeContracts
    abstract type AbstractBS{T} end
    @contract AbstractBS{T} begin
        bs(::Self)::Int
    end
    struct Bk{T} <: AbstractBS{T} end
    bs(::Bk) = "not an int"
    @verify Bk
    end

    @test verified_trait(BareNoSeal.AbstractBS, BareNoSeal.Bk) isa NotImplemented
    @test_throws "return String ⊄ Int64" check_contract(BareNoSeal.Bk{Int})
end

@testitem "a subtype is checked against the parameters asked for" begin
    using Test
    using TypeContracts

    @eval module ParamAsk
    using TypeContracts
    abstract type AbstractPA{T} end
    @contract AbstractPA{T} begin
        pa(::Self, ::T)::T
    end
    struct P <: AbstractPA{Int} end
    pa(::P, x::Int) = x
    end

    @test satisfies(ParamAsk.P, ParamAsk.AbstractPA).satisfied
    @test satisfies(ParamAsk.P, ParamAsk.AbstractPA{Int}).satisfied
    @test !satisfies(ParamAsk.P, ParamAsk.AbstractPA{String}).satisfied
end

@testitem "describe and contract_md_string of a parameterized type" begin
    using Test
    using TypeContracts

    @eval module DescP
    using TypeContracts
    abstract type AbstractDP{T} end
    @contract AbstractDP{T} begin
        dp(::Self)::T
    end
    end

    @test occursin("dp(::Self)", sprint(io -> describe(DescP.AbstractDP{Int}; io)))
    @test occursin("dp(::Self)", contract_md_string(DescP.AbstractDP{Int}))
end

@testitem "@verify options must be written name = value" begin
    using Test
    using TypeContracts

    @eval module OptForm
    using TypeContracts
    abstract type AbstractOF end
    @contract AbstractOF begin
        of(::Self)
    end
    struct F <: AbstractOF end
    of(::F) = 1
    end

    @test_throws "@verify: options are written `name = value`, got `trim_compat`" @eval OptForm @verify F trim_compat
end
