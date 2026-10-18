@testitem "contract_signatures" begin
    using Test
    using TypeContracts

    @eval module CSForeignOwner
    using TypeContracts
    abstract type ForeignBase{T} end
    @contract ForeignBase{T} begin
        fget(::Self)::T
    end
    end

    @eval module CSMod
    using TypeContracts, ..CSForeignOwner
    abstract type AbstractShapeS end
    struct SVGRendererS end
    @contract AbstractShapeS begin
        area(::Self)::Float64
        render(::SVGRendererS, ::Self)::String
        :optional
        label(::Self)::String
    end
    struct Circle <: AbstractShapeS end
    area(::Circle) = 1.0
    render(::SVGRendererS, ::Circle) = "<circle/>"

    abstract type AbstractBucketS{T} end
    @contract AbstractBucketS{T} begin
        get1(::Self)::T
    end
    struct IntBucket <: AbstractBucketS{Int} end
    get1(::IntBucket) = 1
    struct Bucket{T} <: AbstractBucketS{T}
        x::T
    end
    get1(b::Bucket) = b.x

    struct Local <: CSForeignOwner.ForeignBase{Int} end
    CSForeignOwner.fget(::Local) = 2

    @verify Bucket{Int}
    @verify IntBucket
    @verify_all
    end

    entries = contract_signatures(CSMod)
    entry(f, T) = only(filter(e -> e.f === f && e.T === T, entries))

    @testset "plain contract" begin
        e = entry(CSMod.area, CSMod.Circle)
        @test e.sig == Tuple{CSMod.Circle}
        @test e.return_type == Float64
        @test e.contract == CSMod.AbstractShapeS
        @test e.mandatory
    end

    @testset "Self in a non-first position" begin
        @test entry(CSMod.render, CSMod.Circle).sig == Tuple{CSMod.SVGRendererS, CSMod.Circle}
    end

    @testset "parametric contract resolves the parameter" begin
        e = entry(CSMod.get1, CSMod.IntBucket)
        @test e.sig == Tuple{CSMod.IntBucket}
        @test e.return_type == Int
        @test isempty(filter(e -> e.T === CSMod.Bucket, entries))
    end

    @testset "an instance verified explicitly is listed once" begin
        e = entry(CSMod.get1, CSMod.Bucket{Int})
        @test e.sig == Tuple{CSMod.Bucket{Int}}
        @test e.return_type == Int
        @test length(filter(e -> e.T === CSMod.IntBucket, entries)) == 1
    end

    @testset "contract owned by another module" begin
        @test entry(CSForeignOwner.fget, CSMod.Local).contract == CSForeignOwner.ForeignBase
        @test entry(CSForeignOwner.fget, CSMod.Local).return_type == Int
    end

    @testset "optional specs only on request" begin
        @test isempty(filter(e -> e.f === CSMod.label, entries))
        e = only(filter(e -> e.f === CSMod.label, contract_signatures(CSMod; optional = true)))
        @test !e.mandatory
        @test e.sig == Tuple{CSMod.Circle}
    end

    @testset "every entry of a verified module has a method" begin
        @test all(e -> hasmethod(e.f, e.sig), entries)
    end

    @testset "module without contract types" begin
        @test isempty(contract_signatures(Module(:EmptyS)))
    end
end
