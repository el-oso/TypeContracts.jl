# Introspection

TypeContracts provides several functions to inspect what contracts and behaviors are registered at any point.

## `describe(T)` — pretty-print a contract

Prints the full contract for `T` to `stdout` (or an `io` keyword argument):

```julia
abstract type AbstractShape end

@contract AbstractShape "A 2-D geometric shape." begin
    area(::Self)::Float64      => "area enclosed by the shape"
    perimeter(::Self)::Float64 => "length of the boundary"
    :optional
    name(::Self)::String       => "human-readable name"
end

@invariants AbstractShape begin
    "area is non-negative" => x -> area(x) >= 0
end

describe(AbstractShape)
# Interface contract for AbstractShape
# ────────────────────────────────────────
#   A 2-D geometric shape.
#
#   Mandatory methods:
#     • area(::Self) :: Float64 — area enclosed by the shape
#     • perimeter(::Self) :: Float64 — length of the boundary
#   Optional methods:
#     • name(::Self) :: String — human-readable name
#   Behavioral invariants:
#     • area is non-negative
```

To capture the output, pass an `IOBuffer`:

```julia
buf = IOBuffer()
describe(AbstractShape; io = buf)
text = String(take!(buf))
```

## `describe(T, Val(:all))` — supertype chain

Shows contracts from every ancestor of `T` that has a registered contract:

```julia
describe(Circle, Val(:all))
# Full interface contract for Circle
# ========================================
#
#   From AbstractShape:
#     area(::Self) :: Float64
#     perimeter(::Self) :: Float64
#     [optional] name(::Self) :: String
#     [invariant] area is non-negative
```

## `list_contract(T)` — method specs for one type

Returns the `Vector{MethodSpec}` registered directly for `T`:

```julia
specs = list_contract(AbstractShape)
# 3-element Vector{MethodSpec}:
#   area(::Self) :: Float64
#   perimeter(::Self) :: Float64
#   [optional] name(::Self) :: String
```

Each [`MethodSpec`](@ref) exposes:

| Field | Type | Meaning |
|---|---|---|
| `f` | `Function` | the function object |
| `arg_types` | `Vector{Any}` | argument types (`Self`, `TypeParamRef`, or concrete type) |
| `return_type` | `Type` | display return type (`Any` when unspecified or parametric) |
| `return_type_spec` | `Union{Type, TypeParamRef}` | used for actual return type checking |
| `description` | `String` | human-readable signature string |
| `optional` | `Bool` | whether this method is optional |
| `doc` | `String` | per-method prose (`""` if none) |

## `list_contract(T, Val(:all))` — full chain

Returns a `Dict{Type, Vector{MethodSpec}}` mapping each ancestor with a contract to its specs:

```julia
list_contract(Circle, Val(:all))
# Dict{Type, Vector{MethodSpec}} with 1 entry:
#   AbstractShape => [area(::Self) :: Float64, ...]
```

## `list_behaviors(T)` — behavioral specs

Returns the `Vector{BehaviorSpec}` registered for `T`:

```julia
list_behaviors(AbstractShape)
# [BehaviorSpec("area is non-negative", ..., false)]
```

Each [`BehaviorSpec`](@ref) has:

| Field | Type | Meaning |
|---|---|---|
| `description` | `String` | invariant description |
| `predicate` | `Function` | `x -> Bool` |
| `optional` | `Bool` | whether this invariant is optional |

## `contract_signatures(mod)` — resolved signatures for a module

Lists every contract method, with `Self` and type parameters resolved, for each concrete type in `mod` that `@verify_all` would check. This is for tools that analyze the methods a contract requires:

```julia
module Shapes
using TypeContracts
abstract type AbstractShape end
@contract AbstractShape begin
    area(::Self)::Float64
    :optional
    name(::Self)::String
end
struct Circle <: AbstractShape; r::Float64 end
area(c::Circle) = π * c.r^2
@verify_all
end

contract_signatures(Shapes)
# 1-element Vector:
#  (f = area, sig = Tuple{Circle}, return_type = Float64, T = Circle,
#   contract = AbstractShape, mandatory = true)

contract_signatures(Shapes; optional = true)   # also lists name(::Circle)
```

`sig` and `return_type` are exactly what `check_contract` checks, so `hasmethod(e.f, e.sig)` and `Base.return_types(e.f, e.sig)` apply directly. Bare parametric names are left out (see [Parametric types](verification.md#Parametric-types)). Contracts registered in other modules are included when the concrete type is defined in `mod`.

`contract_signatures` reads `names`, `supertypes` and the contract registry, so it is a dev/precompile-time tool and is not `juliac --trim` safe.

## `registered_contracts()` and `registered_behaviors()`

Return all registered contracts and behaviors as dictionaries — useful for tooling, documentation generators, or diagnostic scripts. Intended for interactive/REPL use:

```julia
registered_contracts()
# Dict{Type, Vector{MethodSpec}} with all registered contracts

registered_behaviors()
# Dict{Type, Vector{BehaviorSpec}} with all registered behaviors
```
