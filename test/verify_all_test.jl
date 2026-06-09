@testitem "@verify_all" setup = [TCFixtures] begin
    using Test
    using TypeContracts
    using .TCFixtures

    @testset "verifies all concrete subtypes in a module" begin
        @test VerifyAllPass._result.passed
        @test length(VerifyAllPass._result.types) == 2
    end

    @testset "fails if any type is incomplete" begin
        threw = try
            @eval module VerifyAllFail
            using TypeContracts

            abstract type AbstractGadget end
            function gadget_id end

            @contract AbstractGadget begin
                gadget_id(::Self)::Int
            end

            struct GoodGadget <: AbstractGadget end
            gadget_id(::GoodGadget) = 1

            struct BadGadget <: AbstractGadget end
            # missing gadget_id

            @verify_all
            end
            false
        catch
            true
        end
        @test threw
    end

    @testset "skips types from other modules" begin
        result = TypeContracts._verify_all_in_module(Module(:Empty))
        @test result.passed
        @test isempty(result.types)
    end

    @testset "handles abstract intermediate types" begin
        @test VerifyAllChain._result.passed
        @test length(VerifyAllChain._result.types) == 1
    end
end
