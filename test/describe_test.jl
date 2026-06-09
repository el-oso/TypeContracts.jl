@testitem "describe" setup = [TCFixtures] begin
    using Test
    using TypeContracts
    using .TCFixtures

    @testset "single type with mandatory and optional" begin
        buf = IOBuffer()
        describe(AbstractShape; io = buf)
        output = String(take!(buf))
        @test occursin("Interface contract for $(AbstractShape)", output)
        @test occursin("Mandatory methods:", output)
        @test occursin("shape_area(::Self)", output)
        @test occursin("Optional methods:", output)
        @test occursin("shape_name(::Self)", output)
        @test occursin("Behavioral invariants:", output)
        @test occursin("area is non-negative", output)
        @test occursin("Optional invariants:", output)
        @test occursin("name is non-empty", output)
    end

    @testset "unregistered type" begin
        buf = IOBuffer()
        describe(Real; io = buf)
        output = String(take!(buf))
        @test occursin("no contract registered", output)
    end

    @testset "Val(:all) walks supertypes" begin
        buf = IOBuffer()
        describe(TLabrador, Val(:all); io = buf)
        output = String(take!(buf))
        @test occursin("From $(AbstractAnimal):", output)
        @test occursin("From $(AbstractDog):", output)
        @test occursin("[invariant] speak returns a string", output)
    end
end
