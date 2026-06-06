```@raw html
---
layout: home

hero:
  name: TypeContracts.jl
  text: Interface contracts for Julia
  tagline: Catch missing methods and wrong return types at precompilation time — before your code runs.
  actions:
    - theme: brand
      text: Get Started
      link: /guide/getting-started
    - theme: alt
      text: API Reference
      link: /reference/api

features:
  - title: Compile-time enforcement
    icon: 🔒
    details: "@verify and @verify_all run during precompilation. A module fails to load if any concrete subtype is missing a mandatory method or has the wrong inferred return type."
  - title: Return type checking
    icon: ✅
    details: "Declared return types are verified by Julia's type inferencer. A method that exists but returns the wrong type is caught before any test runs."
  - title: Parametric interfaces
    icon: 🔧
    details: "@contract AbstractType{T,N} lets method signatures reference type parameters. T and N are resolved from the concrete subtype's supertype chain at check time."
  - title: Supertype inheritance
    icon: 🌳
    details: "Contracts propagate down the type hierarchy automatically. A concrete type is checked against contracts for all its abstract supertypes without extra declaration."
  - title: Native ?-doc integration
    icon: 📖
    details: "Contracts are folded into the type's own ?-visible documentation — including retroactive contracts on foreign types. ?AbstractArray shows the contract below Base's own docs."
  - title: Holy trait dispatch
    icon: ⚡
    details: "interface_trait(I, T) returns Implemented{I}() or NotImplemented{I}() for efficient multiple-dispatch patterns. juliac-compatible — uses only hasmethod at runtime."
---
```

## What is TypeContracts.jl?

TypeContracts.jl brings Go-style structural interface contracts to Julia. You declare which methods every concrete subtype of an abstract type must implement, annotate expected return types, and have violations caught at **precompilation time** — before your code ever runs.

```julia
using TypeContracts

abstract type AbstractShape end
function area end
function perimeter end

@contract AbstractShape begin
    area(::Self)      :: Float64
    perimeter(::Self) :: Float64
end

struct Circle <: AbstractShape
    radius::Float64
end

area(c::Circle)::Float64      = π * c.radius^2
perimeter(c::Circle)::Float64 = 2π * c.radius

@verify Circle   # passes at precompile time

struct Square <: AbstractShape
    side::Float64
end

area(s::Square) = s.side^2   # perimeter missing

@verify Square   # InterfaceError: module fails to load
```

## Design philosophy

TypeContracts starts from **structure**: declare what methods must exist and what they must return, then enforce it. Behavioral testing (`@invariants` / `test_behavior`) is an addition on top of the structural foundation — the precompile-time guarantee is the anchor.

```
@contract / @verify    → methods exist, return types correct  (precompile time)
@invariants            → methods behave correctly             (test time)
```
