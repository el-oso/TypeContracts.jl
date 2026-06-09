@testsetup module TCFixtures

using TypeContracts
import REPL

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
    shape_name(::Self)::String
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

# ── @delegate fixtures ────────────────────────────────────────────────

abstract type DelegateStore end
function ds_store! end
function ds_fetch end

@contract DelegateStore begin
    ds_store!(::Self, ::Int)::Nothing
    ds_fetch(::Self)::Int
end

mutable struct DBox
    value::Int
end
ds_store!(b::DBox, v::Int) = (b.value = v; nothing)
ds_fetch(b::DBox) = b.value

mutable struct LoggedBox <: DelegateStore
    inner::DBox
    n_ops::Int
end
LoggedBox() = LoggedBox(DBox(0), 0)

@delegate LoggedBox :inner DelegateStore

abstract type UnregisteredDelegate end

# ── Compile-time enforcement ──────────────────────────────────────────

abstract type AbstractSerializer end

function ser_encode end
function ser_decode end

@contract AbstractSerializer begin
    ser_encode(::Self, ::Any)::String
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
    plugin_name(::Self)::String
    plugin_version(::Self)::Int
end

struct TEmptyPlugin <: AbstractPlugin end
struct TNamedPlugin <: AbstractPlugin end
plugin_name(::TNamedPlugin) = "test"

# ── Behavioral test fixtures ──────────────────────────────────────────

abstract type AbstractCounter end
function counter_value end
function counter_increment! end

@contract AbstractCounter begin
    counter_value(::Self)::Int
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
        wrender(::Self)::String
        wwidth(::Self)::Int
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

# ── Return type enforcement fixtures ─────────────────────────────────

abstract type AbstractMeasurable end
function tmeasure end

@contract AbstractMeasurable begin
    tmeasure(::Self)::Float64
end

struct TGoodMeasurable <: AbstractMeasurable end
tmeasure(::TGoodMeasurable) = 1.0

struct TBadMeasurable <: AbstractMeasurable end
tmeasure(::TBadMeasurable) = "wrong"

struct TUnstableMeasurable <: AbstractMeasurable end
tmeasure(x::TUnstableMeasurable) = rand() > 0.5 ? 1.0 : "oops"

abstract type AbstractUnannotated end
function tunann end

@contract AbstractUnannotated begin
    tunann(::Self)
end

struct TUnann <: AbstractUnannotated end
tunann(::TUnann) = "anything"

# ── Parametric contract fixtures ──────────────────────────────────────

abstract type AbstractBucket{T} end
function bget end
function bset! end
function blen end

@contract AbstractBucket{T} begin
    bget(::Self, ::Int)::T
    bset!(::Self, ::T, ::Int)
    blen(::Self)::Int
end

struct IntBucket <: AbstractBucket{Int}
    data::Vector{Int}
end

bget(b::IntBucket, i::Int)::Int = b.data[i]
bset!(b::IntBucket, v::Int, i::Int) = (b.data[i] = v)
blen(b::IntBucket)::Int = length(b.data)

struct WrongBucket <: AbstractBucket{Int}
    data::Vector{Int}
end

bget(b::WrongBucket, i::Int)::String = "wrong"
bset!(b::WrongBucket, v::Int, i::Int) = (b.data[i] = v)
blen(b::WrongBucket)::Int = length(b.data)

# ── Documentation / juliac fixtures ──────────────────────────────────

abstract type AbstractRepeat end
function rep_fn end
@contract AbstractRepeat "v1" begin
    rep_fn(::Self) => "does a thing"
end
@invariants AbstractRepeat begin
    "always true" => x -> true
end

abstract type AbstractRT end
function rt_fn end
@contract AbstractRT begin
    rt_fn(::Self)
end
struct RTGood <: AbstractRT end
rt_fn(::RTGood) = 1
struct RTBad <: AbstractRT end

# ── Exports ───────────────────────────────────────────────────────────

export AbstractShape, shape_area, shape_perimeter, shape_name, shape_color
export TCircle, TSquare
export DelegateStore, ds_store!, ds_fetch, DBox, LoggedBox, UnregisteredDelegate
export AbstractSerializer, ser_encode, ser_decode, TJSONSerializer
export AbstractComparable, tcompare, TScore
export AbstractAnimal, animal_speak, AbstractDog, dog_fetch, TLabrador, TPoodle
export AbstractContainer, tget, tset!, TBox
export AbstractPlugin, plugin_name, plugin_version, TEmptyPlugin, TNamedPlugin
export AbstractCounter, counter_value, counter_increment!, TCounter, TBrokenCounter
export VerifyAllPass, VerifyAllChain
export AbstractMeasurable, tmeasure, TGoodMeasurable, TBadMeasurable, TUnstableMeasurable
export AbstractUnannotated, tunann, TUnann
export AbstractBucket, bget, bset!, blen, IntBucket, WrongBucket
export AbstractRepeat, rep_fn
export AbstractRT, rt_fn, RTGood, RTBad

end
