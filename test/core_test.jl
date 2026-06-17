@testitem "Core contract checks" setup = [TCFixtures] begin
    using Test
    using TypeContracts
    using .TCFixtures

    @testset "list_contract returns registered specs" begin
        specs = list_contract(AbstractShape)
        @test length(specs) == 4
    end

    @testset "list_contract returns empty for unregistered types" begin
        @test isempty(list_contract(Real))
    end

    @testset "list_contract Val(:all) walks supertypes" begin
        all_contracts = list_contract(TLabrador, Val(:all))
        @test haskey(all_contracts, AbstractAnimal)
        @test haskey(all_contracts, AbstractDog)
        @test length(all_contracts) == 2
    end

    @testset "return type annotations are recorded" begin
        specs = list_contract(AbstractSerializer)
        @test specs[1].return_type == String
        @test specs[1].description == "ser_encode(::Self, ::Any) :: String"
    end

    @testset "registered_contracts returns full registry" begin
        reg = registered_contracts()
        @test isa(reg, Dict)
        @test haskey(reg, AbstractShape)
    end

    @testset "check_contract passes for complete implementation" begin
        result = check_contract(TCircle)
        @test result.passed
        @test result.type == TCircle
        @test AbstractShape in result.contracts
    end

    @testset "error message lists missing methods" begin
        try
            check_contract(TSquare)
            @test false
        catch e
            @test e isa InterfaceError
            @test occursin("shape_perimeter", e.msg)
            @test occursin("AbstractShape", e.msg)
        end
    end

    @testset "@verify passes at load time" begin
        result = @verify TJSONSerializer
        @test result.passed
    end

    @testset "retroactive contracts" begin
        @test check_contract(String).passed
        @test check_contract(SubString{String}).passed
    end

    @testset "Self in multiple argument positions" begin
        @test check_contract(TScore).passed
    end

    @testset "supertype chain inheritance" begin
        result = check_contract(TLabrador)
        @test result.passed
        @test length(result.contracts) == 2
    end

    @testset "missing inherited method is caught" begin
        @test_throws InterfaceError check_contract(TPoodle)

        result = satisfies(TPoodle, AbstractDog)
        @test !result.satisfied

        result = satisfies(TPoodle, AbstractAnimal)
        @test result.satisfied
    end

    @testset "multi-arg with mixed types" begin
        @test check_contract(TBox).passed
    end

    @testset "implements(T, S) returns Bool for @test" begin
        @test implements(TCircle, AbstractShape)
        @test !implements(TSquare, AbstractShape)
        @test implements(TJSONSerializer, AbstractSerializer)
    end

    @testset "implements(T, S) errors for unregistered contract" begin
        @test_throws ArgumentError implements(TCircle, Real)
    end

    @testset "implements(T, S) include_optional requires optional methods too" begin
        @test implements(TCircle, AbstractShape)
        @test !implements(TCircle, AbstractShape; include_optional = true)  # missing shape_color
        @test implements(TJSONSerializer, AbstractSerializer; include_optional = true)
    end

    @testset "implements(T) checks all supertype contracts" begin
        @test implements(TCircle)
        @test !implements(TSquare)
    end

    @testset "implements(T) errors for type with no contracts" begin
        struct TPlain end
        @test_throws ArgumentError implements(TPlain)
    end

    @testset "@test_implements passes for conforming type" begin
        @test_implements TCircle AbstractShape
    end
end

@testitem "check_contract(T, I) — structural check without subtyping" setup = [TCFixtures] begin
    using Test
    using TypeContracts

    # A structural protocol: interface type that no user type subtypes.
    abstract type AbstractProcessor end
    function process end
    @contract AbstractProcessor begin
        process(::Self, ::String) :: Int
    end

    # A type that satisfies the contract structurally (no <: AbstractProcessor).
    struct TextCounter end
    process(::TextCounter, s::String)::Int = length(s)

    # Structural check must pass.
    @test_nowarn check_contract(TextCounter, AbstractProcessor)
    r = check_contract(TextCounter, AbstractProcessor)
    @test r.passed
    @test r.type === TextCounter
    @test AbstractProcessor in r.contracts

    # @verify T for_contract=I must also pass.
    @test_nowarn @verify TextCounter for_contract = AbstractProcessor

    # A type that is missing the required method.
    struct EmptyImpl end
    @test_throws TypeContracts.InterfaceError check_contract(EmptyImpl, AbstractProcessor)

    # No contract registered → ArgumentError.
    abstract type NoContract end
    @test_throws ArgumentError check_contract(TextCounter, NoContract)
end
