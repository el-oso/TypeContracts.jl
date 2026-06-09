@testitem "Holy trait dispatch" setup = [TCFixtures] begin
    using Test
    using TypeContracts
    using .TCFixtures

    @testset "Implemented for conforming type" begin
        @test interface_trait(AbstractShape, TCircle) isa Implemented{AbstractShape}
    end

    @testset "NotImplemented for non-conforming type" begin
        @test interface_trait(AbstractShape, TSquare) isa NotImplemented{AbstractShape}
    end

    @testset "NotImplemented for unregistered interface" begin
        @test interface_trait(Real, Int) isa NotImplemented{Real}
    end

    @testset "optional methods don't affect trait" begin
        @test interface_trait(AbstractPlugin, TEmptyPlugin) isa Implemented{AbstractPlugin}
    end

    @testset "trait dispatch works" begin
        _proc(::Implemented{AbstractShape}, x) = shape_area(x)
        _proc(::NotImplemented{AbstractShape}, x) = -1
        proc(x) = _proc(interface_trait(AbstractShape, typeof(x)), x)

        @test proc(TCircle(1.0)) ≈ π
        @test proc(42) == -1
    end

    @testset "show methods" begin
        @test sprint(show, Implemented{AbstractShape}()) == "Implemented{$(AbstractShape)}()"
        @test sprint(show, NotImplemented{AbstractShape}()) == "NotImplemented{$(AbstractShape)}()"
    end
end
