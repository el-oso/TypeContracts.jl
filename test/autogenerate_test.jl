@testitem "Auto-generation of abstract type and function stubs" begin
    using TypeContracts

    # 1. Full auto-generation — nothing pre-defined.
    #    @contract must create the abstract type and all function stubs.
    m1 = Module(:AutoGen1, false)
    Core.eval(m1, :(using TypeContracts))
    Core.eval(m1, quote
        @contract Creature begin
            breathe(::Self)::Bool
            :optional
            name(::Self)::String
        end
    end)
    @test isabstracttype(m1.Creature)
    @test isdefined(m1, :breathe)
    @test isdefined(m1, :name)

    # 2. Partial: abstract type pre-exists with a supertype; only functions auto-generated.
    #    Use separate Core.eval calls so LandVehicle is already defined when @contract
    #    expands (macro expansion happens before block evaluation inside a single quote).
    m2 = Module(:AutoGen2, false)
    Core.eval(m2, :(using TypeContracts))
    Core.eval(m2, :(abstract type Vehicle end))
    Core.eval(m2, :(abstract type LandVehicle <: Vehicle end))
    Core.eval(m2, quote
        @contract LandVehicle begin
            drive(::Self)::Bool
        end
    end)
    @test supertype(m2.LandVehicle) === m2.Vehicle
    @test isdefined(m2, :drive)

    # 3. Fully pre-defined — neither the type nor functions should be re-emitted.
    m3 = Module(:AutoGen3, false)
    Core.eval(m3, :(using TypeContracts))
    Core.eval(m3, :(abstract type Widget end))
    Core.eval(m3, :(function render end))
    Core.eval(m3, quote
        @contract Widget begin
            render(::Self)::String
        end
    end)
    @test isabstracttype(m3.Widget)
    @test isdefined(m3, :render)

    # 4. Qualified functions (Base.show) must not trigger `function Base.show end`.
    #    `using Base` makes IO and Base available inside the bare module.
    m4 = Module(:AutoGen4, false)
    Core.eval(m4, :(using Base, TypeContracts))
    Core.eval(m4, quote
        @contract Printable begin
            Base.show(::Self, ::IO)
        end
    end)
    @test isabstracttype(m4.Printable)
    # `show` in m4 must be the Base function, not a locally generated stub.
    @test m4.show === Base.show

    # 5. Parametric: @contract Container{E} auto-generates `abstract type Container{E} end`.
    m5 = Module(:AutoGen5, false)
    Core.eval(m5, :(using TypeContracts))
    Core.eval(m5, quote
        @contract Bucket{E} begin
            store(::Self, ::E)
            retrieve(::Self)::E
        end
    end)
    @test isabstracttype(m5.Bucket)
    @test isdefined(m5, :store)
    @test isdefined(m5, :retrieve)

    # 6. @verify works end-to-end when the type came from auto-generation.
    m6 = Module(:AutoGen6, false)
    Core.eval(m6, :(using TypeContracts))
    Core.eval(m6, quote
        @contract Flyer begin
            fly(::Self)::Float64
        end
        struct Plane <: Flyer end
        fly(::Plane)::Float64 = 900.0
        @verify Plane
    end)
    @test true  # no error thrown
end
