using Test
using TypeContracts

# ══════════════════════════════════════════════════════════════════════
# Test fixtures — types and functions at module scope
# ══════════════════════════════════════════════════════════════════════

# ── Basic contract ────────────────────────────────────────────────────

abstract type AbstractShape end

function shape_area end
function shape_perimeter end
function shape_name end
function shape_color end

@contract AbstractShape begin
    shape_area(::Self)
    shape_perimeter(::Self)
    :optional
    shape_name(::Self) :: String
    shape_color(::Self)
end

@invariants AbstractShape begin
    "area is non-negative" => x -> shape_area(x) >= 0
    "perimeter is non-negative" => x -> shape_perimeter(x) >= 0
    :optional
    "name is non-empty" => x -> !isempty(shape_name(x))
end

struct TCircle <: AbstractShape
    radius::Float64
end

shape_area(c::TCircle) = π * c.radius^2
shape_perimeter(c::TCircle) = 2π * c.radius
shape_name(::TCircle) = "circle"

struct TSquare <: AbstractShape
    side::Float64
end

shape_area(s::TSquare) = s.side^2
# Intentionally missing shape_perimeter for TSquare

# ── Compile-time enforcement ──────────────────────────────────────────

abstract type AbstractSerializer end

function ser_encode end
function ser_decode end

@contract AbstractSerializer begin
    ser_encode(::Self, ::Any) :: String
    ser_decode(::Self, ::String)
end

struct TJSONSerializer <: AbstractSerializer end

ser_encode(::TJSONSerializer, data::Any) = "json"
ser_decode(::TJSONSerializer, s::String) = nothing

@verify TJSONSerializer

# ── Retroactive contracts ─────────────────────────────────────────────

@contract AbstractString begin
    length(::Self)
    ncodeunits(::Self)
end

# ── Multi-argument Self ───────────────────────────────────────────────

abstract type AbstractComparable end

function tcompare end

@contract AbstractComparable begin
    tcompare(::Self, ::Self)
end

struct TScore <: AbstractComparable
    value::Int
end

tcompare(a::TScore, b::TScore) = a.value - b.value

# ── Inheritance chain ─────────────────────────────────────────────────

abstract type AbstractAnimal end
abstract type AbstractDog <: AbstractAnimal end

function animal_speak end
function dog_fetch end

@contract AbstractAnimal begin
    animal_speak(::Self)
end

@contract AbstractDog begin
    dog_fetch(::Self)
end

@invariants AbstractAnimal begin
    "speak returns a string" => x -> animal_speak(x) isa AbstractString
end

struct TLabrador <: AbstractDog end
animal_speak(::TLabrador) = "woof"
dog_fetch(::TLabrador) = "ball"

struct TPoodle <: AbstractDog end
animal_speak(::TPoodle) = "yap"
# Missing dog_fetch for TPoodle

# ── Multi-arg with mixed types ────────────────────────────────────────

abstract type AbstractContainer end

function tget end
function tset! end

@contract AbstractContainer begin
    tget(::Self, ::Int)
    tset!(::Self, ::Int, ::Any)
end

struct TBox <: AbstractContainer
    items::Vector{Any}
end

tget(b::TBox, i::Int) = b.items[i]
tset!(b::TBox, i::Int, v::Any) = (b.items[i] = v)

# ── All-optional contract ─────────────────────────────────────────────

abstract type AbstractPlugin end

function plugin_name end
function plugin_version end

@contract AbstractPlugin begin
    :optional
    plugin_name(::Self) :: String
    plugin_version(::Self) :: Int
end

struct TEmptyPlugin <: AbstractPlugin end
struct TNamedPlugin <: AbstractPlugin end
plugin_name(::TNamedPlugin) = "test"

# ── Behavioral test fixtures ──────────────────────────────────────────

abstract type AbstractCounter end
function counter_value end
function counter_increment! end

@contract AbstractCounter begin
    counter_value(::Self) :: Int
    counter_increment!(::Self)
end

@invariants AbstractCounter begin
    "value is non-negative" => x -> counter_value(x) >= 0
    "increment increases value" => x -> begin
        before = counter_value(x)
        counter_increment!(x)
        counter_value(x) > before
    end
end

mutable struct TCounter <: AbstractCounter
    n::Int
end

counter_value(c::TCounter) = c.n
counter_increment!(c::TCounter) = (c.n += 1)

@verify TCounter

mutable struct TBrokenCounter <: AbstractCounter
    n::Int
end

counter_value(c::TBrokenCounter) = c.n
counter_increment!(c::TBrokenCounter) = nothing  # doesn't actually increment

@verify TBrokenCounter  # structural check passes — methods exist

# ── @verify_all test modules (must be at module scope) ────────────────

module VerifyAllPass
    using TypeContracts

    abstract type AbstractWidget end
    function wrender end
    function wwidth end

    @contract AbstractWidget begin
        wrender(::Self) :: String
        wwidth(::Self) :: Int
    end

    struct Button <: AbstractWidget end
    wrender(::Button) = "btn"
    wwidth(::Button) = 80

    struct Label <: AbstractWidget end
    wrender(::Label) = "lbl"
    wwidth(::Label) = 40

    const _result = @verify_all
end

module VerifyAllChain
    using TypeContracts

    abstract type AbstractBase end
    abstract type AbstractMid <: AbstractBase end

    function base_fn end

    @contract AbstractBase begin
        base_fn(::Self)
    end

    struct Leaf <: AbstractMid end
    base_fn(::Leaf) = "leaf"

    const _result = @verify_all
end

# ══════════════════════════════════════════════════════════════════════
# Tests
# ══════════════════════════════════════════════════════════════════════

@testset "TypeContracts.jl" begin

    # ── Phase 1: Optional Methods ─────────────────────────────────────

    @testset "Optional methods" begin
        @testset "contract parses mandatory and optional" begin
            specs = list_contract(AbstractShape)
            mandatory = filter(s -> !s.optional, specs)
            optional  = filter(s -> s.optional, specs)
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

    # ── Existing behavior (preserved) ─────────────────────────────────

    @testset "Core contract checks" begin
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
    end

    # ── Phase 2: Holy Trait Dispatch ──────────────────────────────────

    @testset "Holy trait dispatch" begin
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
            @test sprint(show, Implemented{AbstractShape}()) == "Implemented{AbstractShape}()"
            @test sprint(show, NotImplemented{AbstractShape}()) == "NotImplemented{AbstractShape}()"
        end
    end

    # ── Phase 3: Describe ─────────────────────────────────────────────

    @testset "describe" begin
        @testset "single type with mandatory and optional" begin
            buf = IOBuffer()
            describe(AbstractShape; io=buf)
            output = String(take!(buf))
            @test occursin("Interface contract for AbstractShape", output)
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
            describe(Real; io=buf)
            output = String(take!(buf))
            @test occursin("no contract registered", output)
        end

        @testset "Val(:all) walks supertypes" begin
            buf = IOBuffer()
            describe(TLabrador, Val(:all); io=buf)
            output = String(take!(buf))
            @test occursin("From AbstractAnimal:", output)
            @test occursin("From AbstractDog:", output)
            @test occursin("[invariant] speak returns a string", output)
        end
    end

    # ── Phase 4: Behavioral Testing ───────────────────────────────────

    @testset "Behavioral testing" begin
        @testset "@invariants registers behaviors" begin
            specs = list_behaviors(AbstractShape)
            @test length(specs) == 3
            mandatory = filter(b -> !b.optional, specs)
            optional  = filter(b -> b.optional, specs)
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
            optional_spec  = filter(b -> b.optional, specs)[1]
            @test !startswith(sprint(show, mandatory_spec), "[optional]")
            @test startswith(sprint(show, optional_spec), "[optional]")
        end
    end

    # ── @verify_all ───────────────────────────────────────────────────

    @testset "@verify_all" begin
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
                        gadget_id(::Self) :: Int
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

end
