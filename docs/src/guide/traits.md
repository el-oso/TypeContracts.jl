# Trait Dispatch

TypeContracts supports the [Holy Trait](https://docs.julialang.org/en/v1/manual/methods/#Trait-based-dispatch-1) pattern: dispatch on whether a type satisfies an interface contract, without requiring the type to declare anything.

## `interface_trait(I, T)` — the dispatch key

```julia
interface_trait(::Type{I}, ::Type{T}) -> Implemented{I} | NotImplemented{I}
```

Returns `Implemented{I}()` if `T` satisfies all mandatory methods of the contract registered for `I`, or `NotImplemented{I}()` otherwise. Only method existence (`hasmethod`) is checked — return type inference is **not** run, making this function safe for runtime use in juliac-compiled binaries.

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

## Dispatch pattern

Define two internal methods — one for each trait singleton — and a public entry point that calls `interface_trait` to select between them:

```julia
_render(::Implemented{AbstractShape}, x)    = "Shape[area=$(round(area(x); digits=2))]"
_render(::NotImplemented{AbstractShape}, x) = "not a shape: $(typeof(x))"

render(x) = _render(interface_trait(AbstractShape, typeof(x)), x)
```

```julia
render(Circle(3.0))   # "Shape[area=28.27]"
render(42)            # "not a shape: Int64"
render("hello")       # "not a shape: String"
```

This pattern is zero-overhead at runtime: Julia specialises `_render` on the singleton type, and the dispatch is resolved statically when the type of `x` is known at compile time.

## `Implemented{I}` and `NotImplemented{I}`

These are plain singleton structs with no fields:

```julia
struct Implemented{I} end
struct NotImplemented{I} end
```

They are exported by TypeContracts and can be used as type parameters, method argument types, or anywhere else a type is expected.

## juliac compatibility

`interface_trait` uses only `hasmethod` — it does not call `supertypes`, `Base.return_types`, `Markdown`, or `Base.Docs`. It is safe to call in a statically compiled binary produced by juliac (`--trim`).

If you need trait dispatch in a static binary, register your contracts in the module's `__init__` function and call `disable_docs!()` before registration to keep the documentation machinery out of the binary:

```julia
function __init__()
    TypeContracts.disable_docs!()
    @contract AbstractShape begin
        area(::Self) :: Float64
    end
end
```

## Checking multiple interfaces

`interface_trait` checks a single interface at a time. For types that need to satisfy multiple interfaces, compose the traits:

```julia
abstract type Printable end
abstract type Serializable end

@contract Printable begin
    Base.show(::IO, ::Self)
end

@contract Serializable begin
    serialize(::Self) :: Vector{UInt8}
end

function process(x)
    pt = interface_trait(Printable, typeof(x))
    st = interface_trait(Serializable, typeof(x))
    _process(pt, st, x)
end

_process(::Implemented{Printable}, ::Implemented{Serializable}, x) = ...
_process(::Implemented{Printable}, ::NotImplemented{Serializable}, x) = ...
_process(::NotImplemented{Printable}, ::Any, x) = error("type must be Printable")
```
