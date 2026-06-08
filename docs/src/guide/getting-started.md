# Getting Started

## Installation

TypeContracts.jl requires Julia ≥ 1.9 and has no external dependencies — only `InteractiveUtils` from the Julia standard library. The optional `?`-doc integration is provided by a `REPL` package extension that loads automatically in interactive sessions (see [Documentation Integration](documentation.md)).

```julia
using Pkg
Pkg.add("TypeContracts")
```

## First example

The following example demonstrates all six core capabilities in one module: contract declaration, return-type annotation, optional methods, compile-time enforcement, non-throwing checks, and the `@verify_all` bulk check.

```julia
module Shapes
using TypeContracts

abstract type AbstractShape end

function area end
function perimeter end
function label end

# Declare the interface.
# Methods before :optional are mandatory; methods after are checked separately.
@contract AbstractShape begin
    area(::Self)      :: Float64
    perimeter(::Self) :: Float64
    :optional
    label(::Self)     :: String
end

# Conforming implementation.
struct Circle <: AbstractShape
    radius::Float64
end

area(c::Circle)::Float64      = π * c.radius^2
perimeter(c::Circle)::Float64 = 2π * c.radius
label(::Circle)               = "circle"

@verify Circle   # passes: all mandatory methods exist with correct return types

# Check without throwing — useful in tests.
result = satisfies(Circle, AbstractShape)
# (satisfied = true, missing_methods = [], missing_optional = [])

# A type that only implements mandatory methods still passes @verify.
struct Rectangle <: AbstractShape
    w::Float64
    h::Float64
end

area(r::Rectangle)::Float64      = r.w * r.h
perimeter(r::Rectangle)::Float64 = 2(r.w + r.h)

@verify Rectangle   # passes: label is optional

# Place @verify_all at the end to check every concrete subtype in this module at once.
# The module fails to load if any subtype violates a mandatory contract.
@verify_all

end # module
```

## What `@verify` catches

`@verify` runs at module precompilation and throws [`InterfaceError`](@ref) if either:

- A mandatory method is missing (`hasmethod` returns false).
- A mandatory method exists but its inferred return type is not a subtype of the declared type.

```julia
struct BadShape <: AbstractShape
    r::Float64
end

area(b::BadShape) = "oops"          # String, not Float64
perimeter(b::BadShape) = 2π * b.r

@verify BadShape
# InterfaceError: BadShape does not satisfy interface contract.
# Missing or incorrect methods:
#   area(::Self) :: Float64 — return String ⊄ Float64  [required by AbstractShape]
```

The module containing `@verify BadShape` **will not precompile**. You see the error when you first `using` it — the same failure mode as a syntax error.

## Next steps

- [Defining Contracts](contracts.md) — full `@contract` syntax including parametric interfaces and per-method docs.
- [Verification](verification.md) — `@verify`, `@verify_all`, `check_contract`, `satisfies`.
- [Behavioral Testing](behavioral.md) — `@invariants` and `test_behavior` for runtime property checks.
- [Trait Dispatch](traits.md) — `interface_trait` for Holy Trait dispatch patterns.
