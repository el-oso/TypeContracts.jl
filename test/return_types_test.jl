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
