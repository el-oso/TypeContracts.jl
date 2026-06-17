# Trait Dispatch

TypeContracts supports the [Holy Trait](https://docs.julialang.org/en/v1/manual/methods/#Trait-based-dispatch-1) pattern: dispatch on whether a type satisfies an interface contract, without requiring the type to declare anything upfront.

For `juliac --trim` compatibility of `interface_trait` and the proactive/reactive trim tools, see [Trim Compatibility](trim.md).

## `interface_trait(I, T)` — the dispatch key

```julia
interface_trait(::Type{I}, ::Type{T}) -> Implemented{I} | NotImplemented{I}
```

Returns `Implemented{I}()` if `T` satisfies all mandatory methods of the contract
registered for `I`, or `NotImplemented{I}()` otherwise. Only method existence
(`hasmethod`) is checked — return-type inference is **not** run, making this safe for
runtime use including in `juliac --trim` compiled binaries.

```julia
abstract type AbstractShape end

@contract AbstractShape begin
    area(::Self)      :: Float64
    perimeter(::Self) :: Float64
end

struct Circle <: AbstractShape; r::Float64 end
area(c::Circle)::Float64      = π * c.r^2
perimeter(c::Circle)::Float64 = 2π * c.r

interface_trait(AbstractShape, Circle)   # Implemented{AbstractShape}()
interface_trait(AbstractShape, Int)      # NotImplemented{AbstractShape}()
```

## `Implemented{I}` and `NotImplemented{I}`

Plain singleton structs with no fields, exported by TypeContracts:

```julia
struct Implemented{I} end
struct NotImplemented{I} end
```

Use them as method argument types, type parameters, or anywhere a type is expected.
Julia specializes dispatch on them statically when the implementing type is known at
compile time, so the overhead is zero.

## Basic dispatch pattern

Define two internal methods — one per trait — and a public entry point:

```julia
_render(::Implemented{AbstractShape}, x)    = "shape: area=$(round(area(x); digits=2))"
_render(::NotImplemented{AbstractShape}, x) = "not a shape: $(typeof(x))"

render(x) = _render(interface_trait(AbstractShape, typeof(x)), x)
```

```julia
render(Circle(3.0))   # "shape: area=28.27"
render(42)            # "not a shape: Int64"
render("hello")       # "not a shape: String"
```

When the concrete type of `x` is known at the call site Julia resolves the dispatch
statically — no dynamic dispatch overhead.

## Graceful fallback instead of error

Not every `NotImplemented` case needs to error. Return a sentinel, log, or silently
skip:

```julia
abstract type Summarizable end

@contract Summarizable begin
    summary(::Self) :: String
end

_summarize(::Implemented{Summarizable}, x)    = summary(x)
_summarize(::NotImplemented{Summarizable}, x) = "(no summary available)"

summarize(x) = _summarize(interface_trait(Summarizable, typeof(x)), x)
```

```julia
struct Report; title::String end
summary(r::Report)::String = "Report: $(r.title)"
@verify Report

summarize(Report("Q1"))  # "Report: Q1"
summarize(42)            # "(no summary available)"
```

## Progressive enhancement with multiple interfaces

Types can implement as many interfaces as they like, independently. Each interface
produces its own trait. Compose them to express which combinations of capabilities are
required:

```julia
abstract type Printable end
abstract type Persistable end

@contract Printable begin
    Base.show(::IO, ::Self)
end

@contract Persistable begin
    serialize(::Self)   :: Vector{UInt8}
    deserialize(::Type{Self}, ::Vector{UInt8}) :: Self
end

# Dispatch on all combinations
function store_and_display(x)
    pt = interface_trait(Printable,   typeof(x))
    st = interface_trait(Persistable, typeof(x))
    _store_and_display(pt, st, x)
end

_store_and_display(::Implemented{Printable}, ::Implemented{Persistable},    x) =
    println("storing: ", x)       # show via Base.show; serialize for storage

_store_and_display(::Implemented{Printable}, ::NotImplemented{Persistable}, x) =
    println("display only: ", x)  # can show but not persist

_store_and_display(::NotImplemented{Printable}, ::Any, x) =
    error("$(typeof(x)) must be Printable")
```

Only method combinations that make sense need definitions — Julia's ordinary method
dispatch handles the fallthrough for any combination you don't define.

## Library extension point

Trait dispatch lets library code work with user-defined types without inheritance.
The library defines the interface and the dispatch; users add their own types later:

```julia
# --- In a library -----------------------------------------------------------
module ShapeLib
using TypeContracts

abstract type AbstractShape end

function area end
function color end

@contract AbstractShape begin
    area(::Self)  :: Float64
    :optional
    color(::Self) :: Symbol
end

_area_str(::Implemented{AbstractShape},    x) = string(round(area(x); digits=3))
_area_str(::NotImplemented{AbstractShape}, x) = "N/A"

_color_str(::Implemented{AbstractShape},    x) =
    hasproperty(x, :_has_color) ? string(color(x)) : "default"
_color_str(::NotImplemented{AbstractShape}, x) = "unknown"

function describe_shape(x)
    t = interface_trait(AbstractShape, typeof(x))
    "$(typeof(x)): area=$(_area_str(t, x))"
end

export AbstractShape, area, color, describe_shape
end # module

# --- In user code -----------------------------------------------------------
using ShapeLib

struct Hexagon <: AbstractShape; side::Float64 end
area(h::Hexagon)::Float64  = 3√3/2 * h.side^2
color(h::Hexagon)::Symbol  = :blue
@verify Hexagon

describe_shape(Hexagon(2.0))   # "Hexagon: area=10.392"
```

The library never needs to know about `Hexagon`. New shapes added by users automatically
get the correct dispatch behavior.

## Dispatch on parametric types

`interface_trait` works with parametric contracts. The type parameter resolves at
specialization time:

```julia
abstract type AbstractContainer{T} end

function cget end
function cset! end

@contract AbstractContainer{T} begin
    cget(::Self, ::Int)  :: T
    cset!(::Self, ::T, ::Int)
end

struct Stack{T} <: AbstractContainer{T}
    data::Vector{T}
end

cget(s::Stack{T}, i::Int) where T        = s.data[i]
cset!(s::Stack{T}, v::T, i::Int) where T = (s.data[i] = v)

@verify Stack{Float64}

interface_trait(AbstractContainer{Float64}, Stack{Float64})  # Implemented{...}()
interface_trait(AbstractContainer{Float64}, Stack{Int})      # NotImplemented{...}()
```

## Checking the trait at the type level

`interface_trait` takes types, not values. When you have a value, pass `typeof`:

```julia
x = Circle(1.0)
interface_trait(AbstractShape, typeof(x))     # Implemented{AbstractShape}()

# Or directly with a concrete type:
interface_trait(AbstractShape, Circle)        # Implemented{AbstractShape}()
```

To branch at the value level without a helper method:

```julia
function maybe_render(x)
    if interface_trait(AbstractShape, typeof(x)) isa Implemented
        return area(x)
    else
        return nothing
    end
end
```

The `isa Implemented` check is resolved at compile time when `x` has a known concrete
type, so this branch is as efficient as the two-method pattern.
