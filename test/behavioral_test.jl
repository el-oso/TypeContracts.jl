@testitem "Behavioral testing" setup = [TCFixtures] begin
    using Test
    using TypeContracts
    using .TCFixtures

    @testset "@invariants registers behaviors" begin
        specs = list_behaviors(AbstractShape)
        @test length(specs) == 3
        mandatory = filter(b -> !b.optional, specs)
        optional = filter(b -> b.optional, specs)
        @test length(mandatory) == 2
        @test length(optional) == 1
    end

    @testset "registered_behaviors returns registry copy" begin
        reg = registered_behaviors()
        @test isa(reg, Dict)
        @test haskey(reg, AbstractShape)
    end

    @testset "test_behavior passes for correct implementation" begin
        result = test_behavior(TCounter, [TCounter(0), TCounter(5)])
        @test result.passed
        @test all(r -> r.passed, result.results)
    end

    @testset "test_behavior catches broken implementation" begin
        result = test_behavior(TBrokenCounter, [TBrokenCounter(0)])
        @test !result.passed
        @test length(result.mandatory_failures) > 0
        @test any(r -> occursin("increment", r.description), result.mandatory_failures)
    end

    @testset "test_behavior with deepcopy prevents mutation leaking" begin
        c = TCounter(0)
        test_behavior(TCounter, [c])
        @test counter_value(c) == 0  # original untouched
    end

    @testset "test_behavior walks supertype chain" begin
        result = test_behavior(TLabrador, [TLabrador()])
        @test result.passed
        @test any(r -> r.type == AbstractAnimal, result.results)
    end

    @testset "test_behavior for specific interface" begin
        result = test_behavior(TLabrador, AbstractAnimal, [TLabrador()])
        @test result.passed
        @test all(r -> r.type == AbstractAnimal, result.results)
    end

    @testset "test_behavior catches exceptions in predicates" begin
        abstract type AbstractFailing end

        @invariants AbstractFailing begin
            "always throws" => x -> error("boom")
        end

        struct TFailing <: AbstractFailing end

        result = test_behavior(TFailing, [TFailing()])
        @test !result.passed
        @test any(r -> occursin("boom", r.error), result.results)
    end

    @testset "optional invariants don't affect passed" begin
        result = test_behavior(TCircle, AbstractShape, [TCircle(-1.0)])
        # area(-1) = π > 0, perimeter(-1) = -2π < 0 → mandatory fails
        @test !result.passed
    end

    @testset "BehaviorSpec show" begin
        specs = list_behaviors(AbstractShape)
        mandatory_spec = filter(b -> !b.optional, specs)[1]
        optional_spec = filter(b -> b.optional, specs)[1]
        @test !startswith(sprint(show, mandatory_spec), "[optional]")
        @test startswith(sprint(show, optional_spec), "[optional]")
    end
end
