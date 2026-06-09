@testitem "Optional methods" setup = [TCFixtures] begin
    using Test
    using TypeContracts
    using .TCFixtures

    @testset "contract parses mandatory and optional" begin
        specs = list_contract(AbstractShape)
        mandatory = filter(s -> !s.optional, specs)
        optional = filter(s -> s.optional, specs)
        @test length(mandatory) == 2
        @test length(optional) == 2
        @test mandatory[1].description == "shape_area(::Self)"
        @test optional[1].description == "shape_name(::Self) :: String"
    end

    @testset "check_contract skips optional methods" begin
        result = check_contract(TCircle)
        @test result.passed
    end

    @testset "check_contract still fails on missing mandatory" begin
        @test_throws InterfaceError check_contract(TSquare)
    end

    @testset "satisfies separates mandatory and optional" begin
        result = satisfies(TCircle, AbstractShape)
        @test result.satisfied
        @test isempty(result.missing_methods)
        @test length(result.missing_optional) == 1
        @test "shape_color(::Self)" in result.missing_optional

        result = satisfies(TSquare, AbstractShape)
        @test !result.satisfied
        @test "shape_perimeter(::Self)" in result.missing_methods
    end

    @testset "all-optional contract: check_contract always passes" begin
        @test check_contract(TEmptyPlugin).passed
        @test check_contract(TNamedPlugin).passed
    end

    @testset "all-optional contract: satisfies reports missing optional" begin
        result = satisfies(TEmptyPlugin, AbstractPlugin)
        @test result.satisfied
        @test length(result.missing_optional) == 2

        result = satisfies(TNamedPlugin, AbstractPlugin)
        @test result.satisfied
        @test length(result.missing_optional) == 1
    end

    @testset "MethodSpec show includes [optional] prefix" begin
        specs = list_contract(AbstractShape)
        opt = filter(s -> s.optional, specs)[1]
        @test startswith(sprint(show, opt), "[optional] ")
    end

    @testset "@contract requires abstract type" begin
        @test_throws ErrorException @eval @contract Int begin
            length(::Self)
        end
    end

    @testset "contract can be overwritten" begin
        abstract type AbstractTemp end
        function ttemp end

        @contract AbstractTemp begin
            ttemp(::Self)
        end

        @test length(list_contract(AbstractTemp)) == 1

        @contract AbstractTemp begin
            ttemp(::Self)
            ttemp(::Self, ::Int)
        end

        @test length(list_contract(AbstractTemp)) == 2
    end
end
