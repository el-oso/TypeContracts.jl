@testitem "Return type enforcement" setup = [TCFixtures] begin
    using Test
    using TypeContracts
    using .TCFixtures

    @testset "correct return type passes" begin
        @test check_contract(TGoodMeasurable).passed
    end

    @testset "wrong return type throws InterfaceError" begin
        err = try
            check_contract(TBadMeasurable); nothing
        catch e
            e
        end
        @test err isa InterfaceError
        @test occursin("return", err.msg)
        @test occursin("String", err.msg) || occursin("⊄", err.msg)
    end

    @testset "satisfies reports wrong return type as missing" begin
        result = satisfies(TBadMeasurable, AbstractMeasurable)
        @test !result.satisfied
        @test any(m -> occursin("return", m), result.missing_methods)
    end

    @testset "type-unstable method flagged" begin
        err = try
            check_contract(TUnstableMeasurable); nothing
        catch e
            e
        end
        @test err isa InterfaceError
    end

    @testset "no annotation skips return type check" begin
        @test check_contract(TUnann).passed
    end

    @testset "Self return type resolves to the concrete implementing type" begin
        @test check_contract(TCloneGood).passed
        @test satisfies(TCloneGood, AbstractCloneable).satisfied

        result = satisfies(TCloneBad, AbstractCloneable)
        @test !result.satisfied
        @test any(m -> occursin("⊄", m), result.missing_methods)
    end

    @testset "@verify propagates return type check" begin
        threw = try
            @eval module VerifyReturnTypeFail
            using TypeContracts

            abstract type AbstractCounter2 end
            function tcount2 end

            @contract AbstractCounter2 begin
                tcount2(::Self)::Int
            end

            struct BadCounter2 <: AbstractCounter2 end
            tcount2(::BadCounter2) = "not an int"

            @verify BadCounter2
            end
            false
        catch
            true
        end
        @test threw
    end
end

@testitem "a return annotation proves conformance without inference" begin
    using Test
    using TypeContracts

    abstract type AnnC end
    function aop end
    function akw end
    @contract AnnC begin
        aop(::Self, x::Int)::Integer
        akw(::Self, A::AbstractMatrix)::AbstractMatrix
    end

    struct AnnOK <: AnnC end
    struct AnnWrong <: AnnC end
    struct Tricky <: AnnC end
    struct PlainOK <: AnnC end
    aop(::AnnOK, x::Int)::Int = x + 1
    aop(::AnnWrong, x::Int)::Float64 = x + 1.0
    function aop(::Tricky, x::Int)::Real
        y = x::Int
        return y * 2.0
    end
    aop(::PlainOK, x::Int) = x + 1
    for S in (AnnOK, AnnWrong, Tricky, PlainOK)
        @eval akw(::$S, A::AbstractMatrix; tol = 0.0)::AbstractMatrix = A
    end

    raises(T) = try
        TypeContracts._verify_check(T, nothing)
        false
    catch e
        e isa TypeContracts.InterfaceError || rethrow()
        true
    end
    byann(T) = TypeContracts._conforms_by_annotation(aop, Tuple{T, Int}, Integer)

    # An annotation that is a subtype of the declared type settles it, and no inference is needed.
    @test byann(AnnOK)
    @test !raises(AnnOK)

    # An annotation that is not a subtype proves nothing, so inference decides, and catches it.
    @test !byann(AnnWrong)
    @test raises(AnnWrong)

    # The annotation is read from the RETURNED value. `y = x::Int` is a `typeassert` too; taking it
    # would report `Int` for a method annotated `::Real` that returns a `Float64`, and pass it.
    @test TypeContracts._return_annotation(only(methods(aop, Tuple{Tricky, Int}))) === Real
    @test !byann(Tricky)
    @test raises(Tricky)

    # Unannotated methods fall through to inference unchanged.
    @test !byann(PlainOK)
    @test !raises(PlainOK)

    # A keyword method keeps its annotation in the `#f#N` body it forwards to.
    @test TypeContracts._conforms_by_annotation(akw, Tuple{AnnOK, AbstractMatrix}, AbstractMatrix)
end
