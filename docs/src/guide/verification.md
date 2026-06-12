# Verification

TypeContracts provides several tools for checking contract conformance, divided by *when* they run and *what* they return:

| Function | When | On failure |
|---|---|---|
| `@verify`, `@verify_all` | Precompile time | Aborts module loading |
| `check_contract` | Call site | Throws `InterfaceError` |
| `satisfies` | Call site | Returns diagnostic named tuple |
| `implements` | Test time | Returns `Bool`; errors on unregistered contract |

For the test-friendly boolean helpers (`implements`, `@test_implements`), see the [Testing](testing.md) guide.

## `@verify T` — precompile-time enforcement

Place `@verify T` after all method definitions for `T`. Julia evaluates it when the enclosing module is precompiled. If `T` violates any mandatory contract, an [`InterfaceError`](@ref) is thrown and the `.ji` precompile cache is **not written** — the module cannot be loaded.

```julia
module MyModule
using TypeContracts

abstract type AbstractQueue{T} end
function enqueue! end
function dequeue! end
function Base.isempty end

@contract AbstractQueue{T} begin
    enqueue!(::Self, ::T)
    dequeue!(::Self) :: T
    Base.isempty(::Self) :: Bool
end

struct VectorQueue{T} <: AbstractQueue{T}
    data::Vector{T}
end

enqueue!(q::VectorQueue{T}, x::T) where T = push!(q.data, x)
dequeue!(q::VectorQueue{T}) where T        = popfirst!(q.data)
Base.isempty(q::VectorQueue)               = isempty(q.data)

@verify VectorQueue{Int}   # T = Int; all three methods checked ✓

end # module
```

`@verify` checks:
1. **Method existence** — `hasmethod(f, Tuple{T, arg_types...})` for every mandatory spec.
2. **Return type** — `Base.return_types(f, sig)` must produce a type `<: declared_type` for every mandatory spec with a declared return type.

!!! note
    `@verify` uses `Base.return_types`, which requires Julia's type-inference machinery. It is a precompile/load-time tool, not suitable for use inside a juliac-compiled binary at runtime. Use [`interface_trait`](@ref) for runtime checks.

## `@verify_all` — bulk enforcement

Place `@verify_all` once at the end of your module, after all type and method definitions. It discovers every concrete subtype of a registered contract type that was defined in the calling module and verifies each one.

```julia
module Shapes
using TypeContracts

abstract type AbstractShape end
function area end

@contract AbstractShape begin
    area(::Self) :: Float64
end

struct Circle  <: AbstractShape; r::Float64 end
struct Square  <: AbstractShape; s::Float64 end
struct Polygon <: AbstractShape; verts::Int end

area(c::Circle)::Float64  = π * c.r^2
area(s::Square)::Float64  = s.s^2
area(p::Polygon)::Float64 = 0.0   # stub — still Float64

@verify_all   # checks Circle, Square, and Polygon in one call

end
```

`@verify_all` is scoped to the calling module (`parentmodule(T) === @__MODULE__`). Subtypes defined in other modules require their own `@verify` or `@verify_all` call.

## `check_contract(T)` — throwing check

For use in tests or in a Julia session. Throws [`InterfaceError`](@ref) if `T` violates any mandatory contract in its supertype chain; returns a named tuple `(type, contracts, passed)` on success.

```julia
check_contract(Circle)
# (type = Circle, contracts = [AbstractShape], passed = true)

check_contract(BadShape)
# InterfaceError: BadShape does not satisfy interface contract.
# Missing or incorrect methods:
#   area(::Self) :: Float64 — return String ⊄ Float64  [required by AbstractShape]
```

`check_contract` walks the full `supertypes(T)` chain and checks every registered contract it finds.

## `satisfies(T, S)` — non-throwing check

Returns a named tuple without throwing. Useful when you need the diagnostic detail of *which* methods are missing:

```julia
result = satisfies(Circle, AbstractShape)
# (satisfied = true, missing_methods = [], missing_optional = ["name(::Self) :: String"])

result.satisfied       # true
result.missing_methods # []
result.missing_optional # ["name(::Self) :: String"]
```

For a plain `Bool` suitable for `@test`, use [`implements`](@ref) instead:

```julia
@test implements(Circle, AbstractShape)
```

The three fields:

| Field | Type | Meaning |
|---|---|---|
| `satisfied` | `Bool` | `true` when all mandatory methods are present with correct return types |
| `missing_methods` | `Vector{String}` | mandatory methods missing or with wrong return type |
| `missing_optional` | `Vector{String}` | optional methods not implemented |

## `InterfaceError`

[`InterfaceError`](@ref) is a plain exception with a `msg::String` field. It is thrown by `@verify`, `@verify_all`, and `check_contract`.

```julia
try
    check_contract(BadShape)
catch e
    e isa InterfaceError   # true
    println(e.msg)
end
```

## Assumptions

**Closed world.** The guarantee holds for methods that are defined at precompilation time. Methods added later via `eval` or `invokelatest` are outside the scope of the check.

**Type inferencer.** Return type checking calls `Base.return_types`, which produces the type the compiler infers. If a method is not type-stable, the inferred return type may be `Union{...}` or `Any`, and the check may pass even if the method occasionally returns the wrong type at runtime.
