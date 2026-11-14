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

@testitem "return_types=false checks the method surface and skips inference" begin
    using Test
    using TypeContracts

    abstract type RTOff end
    function rtop end
    @contract RTOff begin
        rtop(::Self, x::Float64)::Float64
    end

    struct RTGood <: RTOff end
    struct RTWrongType <: RTOff end
    struct RTAbsent <: RTOff end
    rtop(::RTGood, x::Float64) = x + 1.0
    rtop(::RTWrongType, x::Float64) = "a String"

    raises(T, rt) = try
        TypeContracts._verify_check(T, nothing; return_types = rt)
        false
    catch e
        e isa TypeContracts.InterfaceError
    end

    # A declared return type the implementation violates is what inference is for, so it is caught
    # by default and deliberately not caught without it.
    @test !raises(RTGood, true)
    @test !raises(RTGood, false)
    @test raises(RTWrongType, true)
    @test !raises(RTWrongType, false)

    # Method existence does not depend on inference, so declining it must not hide an absent method.
    @test raises(RTAbsent, true)
    @test raises(RTAbsent, false)

    # The macro takes the option, keeps its default, and still rejects a name it does not know.
    @test (@verify RTGood return_types=false).passed
    @test (@verify RTGood).passed
    @test_throws LoadError @eval @verify RTGood no_such_option=false
end
