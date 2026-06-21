# TypeContracts.jl
[![CI](https://github.com/el-oso/TypeContracts.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/el-oso/TypeContracts.jl/actions/workflows/CI.yml)
[![Coverage](https://coveralls.io/repos/github/el-oso/TypeContracts.jl/badge.svg?branch=master)](https://coveralls.io/github/el-oso/TypeContracts.jl?branch=master)
[![](https://img.shields.io/badge/docs-dev-blue.svg)](https://el-oso.github.io/TypeContracts.jl/dev/)

Statically-checked interface contracts for abstract types in Julia.

Define which methods every concrete subtype must implement, annotate expected return types, and have violations caught at **precompilation time** — before your code runs.

---

## What it does

Julia has no built-in mechanism to enforce that a concrete type implements the methods expected by its abstract supertype. TypeContracts fills that gap with six capabilities:

| Capability | Mechanism |
|---|---|
| Declare required method signatures | `@contract AbstractType begin ... end` |
| Declare optional method signatures | `:optional` separator inside `@contract` |
| Annotate and enforce return types | `method(::Self) :: ReturnType` — checked via Julia's type inferencer |
| Parametric type variables in signatures | `@contract AbstractType{T} begin ... end` — `T` resolves at check time |
| Discover what an interface requires | `describe(T)`, `list_contract(T)`, `satisfies(T, S)` |
| Enforce conformance at precompile time | `@verify T` / `@verify_all` — fail to load if a method is missing or returns the wrong type |
| Live re-checking during development | Revise.jl extension — re-checks contracts after each edit cycle, warns instead of throwing |

Behavioral invariants (property-based testing on real objects) are also supported via `@invariants` and `test_behavior`.

---

## Assumptions

**Closed-world.** TypeContracts works under the closed-world assumption: all types and methods are known at precompilation time. Dynamic code loading (`eval`, `invokelatest`) is excluded from the guarantee scope.

**Precompile-time enforcement.** `@verify` and `@verify_all` run when the module is precompiled — before the native binary is produced — not at binary runtime. They use `Base.return_types` internally, but the trimmer eliminates them automatically because they are unreachable from any entry point. Leave `@verify` at module top level as normal; you do not need to remove it for juliac builds.

**`interface_trait` is the only runtime function.** The Holy Trait dispatch helper uses only `hasmethod` and is safe to call in Juliac-compiled binaries at runtime. Use `@verify T trim_compat=true` to also check that your implementation methods are free of trim-unsafe calls.

**Revise re-checking is advisory.** The Revise extension emits `@warn` after each edit cycle for any registered type or module that violates its contract. It does not throw, so the REPL session stays alive. Activate by loading `Revise` before `TypeContracts`.

**Abstract types only.** `@contract` requires its target to be an abstract type.

---

## Development note

This package was developed with assistance from [Claude](https://claude.ai) (Anthropic). All code has been reviewed and is maintained by the author.

## Requirements

- Julia ≥ 1.9
- No external dependencies (only `InteractiveUtils` from the standard library)

---

## Quick example

```julia
module Shapes
using TypeContracts

# Declare the interface for an abstract type.
# Methods before :optional are mandatory; methods after are recorded but not enforced.
abstract type AbstractShape end

function area end
function perimeter end
function label end

@contract AbstractShape begin
    area(::Self)      :: Float64
    perimeter(::Self) :: Float64
    :optional
    label(::Self)     :: String
end

# Conforming implementation — @verify checks method existence and return types.
struct Circle <: AbstractShape
    radius::Float64
end

area(c::Circle)::Float64      = π * c.radius^2
perimeter(c::Circle)::Float64 = 2π * c.radius
label(::Circle)               = "circle"

@verify Circle

# Non-conforming implementation — @verify would throw InterfaceError at load time:
#
#   struct Square <: AbstractShape; side::Float64 end
#   area(s::Square) = s.side^2   # perimeter missing → @verify Square fails
#
# satisfies() gives a non-throwing report instead of an error:
#
#   satisfies(Circle, AbstractShape)
#   # (satisfied = true, missing_methods = [], missing_optional = ["label(::Self) :: String"])

# Place @verify_all at the end of your module to check every concrete subtype at once.
# The module will fail to load if any subtype is missing a mandatory method
# or if any inferred return type does not match the declared one.
@verify_all

end # module
```

### Parametric interfaces

Type variables in the contract header resolve to the concrete element type at check time:

```julia
module Containers
using TypeContracts

abstract type AbstractContainer{T} end

function cget end
function cset! end

# T refers to the element type of whichever concrete subtype is being checked.
@contract AbstractContainer{T} begin
    cget(::Self, ::Int) :: T     # inferred return type must be <: T
    cset!(::Self, ::T, ::Int)    # second argument must accept T
end

struct FloatBox <: AbstractContainer{Float64}
    data::Vector{Float64}
end

cget(b::FloatBox, i::Int)::Float64     = b.data[i]
cset!(b::FloatBox, v::Float64, i::Int) = (b.data[i] = v)

# T resolves to Float64 for FloatBox — inferred return type matches.
@verify FloatBox

@verify_all

end # module
```

---

## Documentation

Full documentation is available at **https://el-oso.github.io/TypeContracts.jl/dev/**.

---

## API reference

| Function / Macro | Description |
|---|---|
| `@contract T begin ... end` | Register a contract for abstract type `T` |
| `@contract T{A,B} begin ... end` | Register a parametric contract with type variables `A`, `B` |
| `@verify T` | Assert at load time that `T` satisfies all mandatory contracts |
| `@verify T trim_compat=true` | Also scan each contract method's IR for trim-unsafe calls (`Base.return_types`, etc.) — emits `@warn` |
| `@verify_all` | Assert all concrete subtypes in the calling module satisfy their contracts |
| `@verify_all trim_compat=true` | Same trim scan applied to every verified type |
| `check_contract(T)` | Throws `InterfaceError` if `T` is non-conforming |
| `check_trim_compat(T)` | Advisory IR scan for trim-unsafe calls in `T`'s contract methods — warns, does not throw |
| `satisfies(T, S)` | Non-throwing check; returns `(satisfied, missing_methods, missing_optional)` |
| `list_contract(T)` | Returns `Vector{MethodSpec}` registered for `T` |
| `list_contract(T, Val(:all))` | Returns contracts for `T`'s full supertype chain |
| `describe(T)` | Pretty-prints the contract for `T`; full chain for concrete types, own level for abstract types |
| `describe(T; all=true)` | Always shows the full supertype chain (equivalent to `describe(T, Val(:all))`) |
| `interface_trait(I, T)` | Returns `Implemented{I}()` or `NotImplemented{I}()` for trait dispatch |
| `@invariants T begin ... end` | Register behavioral predicates for `T` |
| `test_behavior(T, objects)` | Run behavioral invariants against test objects |
