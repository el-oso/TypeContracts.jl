# Nine Ways to Structure Interfaces in Julia

> Inspired by [*Nine Ways to Do Inheritance in a Language Without Inheritance*](https://medium.com/@carlmkadie/nine-ways-to-do-inheritance-in-rust-a-language-without-inheritance-14825bf1e215).

Julia has no class hierarchy and no `interface` or `trait` keyword. Instead it
achieves polymorphism through **multiple dispatch**, **abstract types**, and
**parametric methods**. This page walks through nine recurring patterns, contrasting
the plain Julia idiom with the TypeContracts approach.

---

## 1. Abstract Types with Fallback Methods

Defining a method on an abstract type gives every concrete subtype a fallback
implementation. Subtypes that provide their own method override it; those that do not
inherit the default silently.

### Plain Julia

```julia
abstract type Animal end

# Fallback / "default" behaviour for all Animals
speak(::Animal) = "..."

struct Dog <: Animal end
struct Cat <: Animal end

speak(::Dog) = "woof"

speak(Dog())   # "woof"  — overridden
speak(Cat())   # "..."   — fallback (intentional? accidental? unknowable)
```

Nothing here records that `speak` is part of the `Animal` contract, which methods
are required versus optional, or what return type is expected. `Cat` silently gets
the fallback with no warning.

### With TypeContracts

```julia
abstract type Animal end

@contract Animal "An entity that can vocalise." begin
    speak(::Self) :: String    => "primary vocalisation"
    :optional
    describe(::Self) :: String => "human-readable name (defaults to type name)"
end

# Provide the fallback for the optional method
describe(a::Animal) = string(typeof(a))

struct Dog <: Animal end
speak(::Dog) = "woof"

@verify Dog   # static assertion — errors immediately if speak is missing

struct Cat <: Animal end
# speak not defined — @verify Cat would give:
# InterfaceError: Cat does not implement speak(::Cat) :: String
```

`@contract` makes the interface machine-readable. `satisfies(Dog, Animal)` returns a
named tuple, `describe(Animal)` prints the mandatory/optional split, and `?Animal`
in the REPL shows the contract inline with the existing docstring. `@verify` turns a
silent runtime surprise into a loud load-time failure.

---

## 2. Abstract Type Hierarchies

Abstract type hierarchies (`abstract type B <: A end`) build capability levels:
anything that is a `B` is also an `A`, and method dispatch naturally walks the chain.

### Plain Julia

```julia
abstract type Shape end
abstract type Polygon <: Shape end
abstract type RegularPolygon <: Polygon end

area(s::Shape)                 = error("$(typeof(s)) must implement area")
perimeter(p::Polygon)          = error("$(typeof(p)) must implement perimeter")
side_length(r::RegularPolygon) = error("$(typeof(r)) must implement side_length")

struct Square <: RegularPolygon
    side::Float64
end
side_length(s::Square) = s.side
perimeter(s::Square)   = 4 * s.side
area(s::Square)        = s.side^2
```

The `error(...)` stubs do not fire until the method is called at runtime, and nothing
checks that a concrete type has all three levels covered before the code ships.

### With TypeContracts

```julia
abstract type Shape end
abstract type Polygon <: Shape end
abstract type RegularPolygon <: Polygon end

@contract Shape begin
    area(::Self) :: Float64
end
@contract Polygon begin
    perimeter(::Self) :: Float64
end
@contract RegularPolygon begin
    side_length(::Self) :: Float64
end

struct Square <: RegularPolygon
    side::Float64
end
side_length(s::Square) = s.side
perimeter(s::Square)   = 4 * s.side
area(s::Square)        = s.side^2

@verify Square   # checks Shape, Polygon, AND RegularPolygon in one call
```

`check_contract` walks the full supertype chain, so a single `@verify Square` asserts
all three levels simultaneously. `satisfies(Square, Shape)`, `satisfies(Square, Polygon)`,
and `satisfies(Square, RegularPolygon)` each return independent verdicts listing exactly
which methods are missing at each level.

---

## 3. Extending Foreign Types

In Julia you can define a new method for any type you do not own — no wrapper required.
TypeContracts turns that informal extension into a verifiable contract.

### Plain Julia

```julia
# Add behaviour to Base's Int — no wrapper needed
is_odd(x::Int)  = x & 1 != 0
is_even(x::Int) = !is_odd(x)

# Or extend a Base abstract type retroactively
import Base: summary
Base.summary(io::IO, v::Vector) = print(io, length(v), "-element Vector")
```

Adding methods to foreign types is idiomatic Julia. The gap is that nothing records
which methods your extension promises, and a missing method is discovered only at the
call site.

### With TypeContracts

This is the use-case for
[BaseTypeContracts.jl](https://github.com/el_oso/BaseTypeContracts.jl): retroactive
contracts on `Base` abstract types.

```julia
using TypeContracts, BaseTypeContracts

# BaseTypeContracts.__init__ registered contracts for Base types automatically
satisfies(Vector{Int}, AbstractArray)       # (satisfied = true, ...)
satisfies(Dict{String,Int}, AbstractDict)   # (satisfied = true, ...)

# Write your own retroactive contract on a Base type
@contract AbstractSet "Finite mathematical set." begin
    Base.intersect(::Self, ::Self) :: Self
    Base.union(::Self, ::Self)     :: Self
    Base.issubset(::Self, ::Self)  :: Bool
end

# Verify your custom set type against it
satisfies(MyFancySet, AbstractSet)
```

`@contract` works on types you do not own. The contract is registered retroactively;
any abstract type — including types from `Base` — can be the target.

---

## 4. The Holy Trait Pattern

The **Holy Trait pattern** is the canonical Julia idiom for type-level dispatch: a
function maps types to singleton marker values, which then drive dispatch without
runtime cost. TypeContracts formalises this with `interface_trait`.

### Plain Julia (classic Holy Trait)

```julia
# Marker singletons
struct CanIterate end
struct CannotIterate end

# Classification function — must be extended for every new iterable type
can_iterate(::Type)                   = CannotIterate()
can_iterate(::Type{<:AbstractArray})  = CanIterate()
can_iterate(::Type{<:AbstractString}) = CanIterate()

# Dispatch on the trait value
function collect_items(x)
    _collect(x, can_iterate(typeof(x)))
end
_collect(x, ::CanIterate)    = collect(x)
_collect(x, ::CannotIterate) = error("$(typeof(x)) is not iterable")
```

Every new iterable type requires a manual extension of `can_iterate`. There is no
central registry, no contract definition, and no way to ask "does this type actually
implement the iteration protocol's required methods?"

### With TypeContracts

```julia
using TypeContracts, BaseTypeContracts   # registers the Iterable contract

function collect_items(x::T) where T
    _collect(x, interface_trait(Iterable, T))
end
_collect(x, ::Implemented{Iterable})    = collect(x)
_collect(x, ::NotImplemented{Iterable}) = error("$(typeof(x)) does not satisfy Iterable")

collect_items(rand(3))    # works
collect_items(42)         # clear InterfaceError
```

`interface_trait` returns `Implemented{I}()` or `NotImplemented{I}()` based on the
registered contract. Because it is a `@generated` function, the `hasmethod` calls are
resolved at code-generation time — no runtime dispatch, and the result passes
`juliac --trim` verification.

---

## 5. Delegation via Composition

A common pattern is wrapping an existing type and exposing its interface by forwarding
each required method to the inner value. The wrapper extends or instruments the
wrapped type's behaviour without modifying it.

### Plain Julia

```julia
struct LoggedArray{T} <: AbstractArray{T,1}
    data::Vector{T}
    n_reads::Ref{Int}
end
LoggedArray(v::Vector{T}) where T = LoggedArray{T}(v, Ref(0))

# Delegate the AbstractArray interface to the inner Vector
Base.size(a::LoggedArray)             = size(a.data)
Base.getindex(a::LoggedArray, i::Int) = (a.n_reads[] += 1; a.data[i])
Base.setindex!(a::LoggedArray{T}, v, i::Int) where T = (a.data[i] = v)
```

If you forget any delegation method, you get a vague `MethodError` at the call site
rather than a load-time diagnostic. There is nothing to diff against to know if the
delegation is complete.

### With TypeContracts — verify mode

```julia
using TypeContracts, BaseTypeContracts

struct LoggedArray{T} <: AbstractArray{T,1}
    data::Vector{T}
    n_reads::Ref{Int}
end
LoggedArray(v::Vector{T}) where T = LoggedArray{T}(v, Ref(0))

Base.size(a::LoggedArray)             = size(a.data)
Base.getindex(a::LoggedArray, i::Int) = (a.n_reads[] += 1; a.data[i])
Base.setindex!(a::LoggedArray{T}, v, i::Int) where T = (a.data[i] = v)

# BaseTypeContracts has the AbstractArray contract — verify delegation is complete
@verify LoggedArray{Int}
# Load-time error if any mandatory AbstractArray method is missing, naming it exactly
```

`@verify` at the bottom of the file turns delegation gaps from silent runtime
surprises into loud load-time failures.

### With TypeContracts — `@delegate` (generate + verify)

When a wrapper type exposes exactly the interface from a registered `@contract`,
`@delegate` reads the contract and emits the forwarding methods automatically — one
line replaces N:

```julia
using TypeContracts

abstract type Store end
function store!(::Store, ::Int) end
function fetch(::Store) end

@contract Store begin
    store!(::Self, ::Int) :: Nothing
    fetch(::Self)         :: Int
end

# Box is the inner implementation — no need for Box <: Store
mutable struct Box; value::Int; end
store!(b::Box, v::Int) = (b.value = v; nothing)
fetch(b::Box) = b.value

# Logged formally declares itself as a Store
mutable struct Logged <: Store
    inner::Box
    n_ops::Int
end
Logged() = Logged(Box(0), 0)

@delegate Logged :inner Store
# Equivalent to:
#   store!(_x1::Logged, _x2::Int) = store!(getfield(_x1, :inner), _x2)
#   fetch(_x1::Logged) = fetch(getfield(_x1, :inner))
# Followed by a satisfies() check that throws InterfaceError on failure.

lg = Logged()
store!(lg, 42)
fetch(lg)   # 42

satisfies(Logged, Store)   # (satisfied = true, missing_methods = [], missing_optional = [])
```

`@delegate WrapperType :field InterfaceType` reads the registered `@contract` for
`InterfaceType` at macro-expansion time, generates one forwarding method per mandatory
method, and immediately verifies the result via `satisfies`. The contract definition
serves as both the specification and the forwarding template — no separate interface
list needed.

---

## 6. Blanket Behaviour on Abstract Types

A method with an abstract type bound applies to all current and future subtypes
without repetition — define it once on the abstract type and every concrete subtype
gets it for free.

### Plain Julia

```julia
# One method covers all AbstractArray subtypes — present and future
function summarise(a::AbstractArray{T}) where T
    "$(ndims(a))D $(eltype(a)) array, size $(size(a))"
end

summarise(rand(3))     # "1D Float64 array, size (3,)"
summarise(rand(2, 3))  # "2D Float64 array, size (2, 3)"
```

This is idiomatic Julia. The gap is that there is no contract asserting
`AbstractArray` must provide `size` and `eltype`, so a type that only partially
implements the interface slips through until `summarise` is called.

### With TypeContracts

```julia
using TypeContracts, BaseTypeContracts

# BaseTypeContracts already registers structural contracts for AbstractArray.
# Add behavioral invariants — laws that go beyond method existence:
@invariants AbstractArray begin
    "length equals product of size" => a -> length(a) == prod(size(a))
    :optional
    "eachindex covers all elements" =>
        a -> length(collect(eachindex(a))) == length(a)
end

# Test real objects against both structural and behavioral contracts
test_behavior(Vector{Int}, AbstractArray, [Int[], [1, 2, 3], rand(Int, 5)])
# => named tuple with per-invariant results

# Static structural check on any subtype
satisfies(MyCustomArray, AbstractArray)
```

`@invariants` adds semantic laws on top of the structural contract. `test_behavior`
runs them against actual instances, catching implementations that pass `hasmethod`
but violate the semantic contract (e.g., a `size` that returns wrong dimensions).

---

## 7. `@generated` Functions

`@generated` functions generate their method body at specialisation time, with full
access to the concrete type parameters. The body runs once per unique `(T1, T2, …)`
combination and the result is compiled into static IR — no list of known types
required, no runtime overhead.

### Plain Julia

```julia
# Generate an unrolled sum for fixed-length NTuples — no loop overhead
@generated function tuple_sum(t::NTuple{N, T}) where {N, T}
    N == 0 && return :(zero(T))
    ops = [:(t[$i]) for i in 1:N]
    Expr(:call, :+, ops...)
end

tuple_sum((1, 2, 3))   # compiled to: t[1] + t[2] + t[3]
```

The body runs at compile time when `N` and `T` are known, emitting concrete IR
tailored to that specialisation.

### With TypeContracts

`interface_trait` itself is implemented as a `@generated` function. The registry is
consulted at code-generation time and the body is emitted as a static chain of
`hasmethod` calls with fully concrete signatures:

```julia
@generated function interface_trait(::Type{I}, ::Type{T}) where {I, T}
    specs = get(_registry, I, nothing)
    isnothing(specs) && return :(NotImplemented{I}())
    checks = Expr[]
    for spec in specs
        spec.optional && continue
        sig = _build_sig(spec.arg_types, T)   # concrete Tuple type, resolved now
        push!(checks, :(hasmethod($(spec.f), $sig)))
    end
    isempty(checks) && return :(Implemented{I}())
    cond = foldl((a, b) -> :($a && $b), checks)
    :($cond ? Implemented{I}() : NotImplemented{I}())
end
```

Because every `hasmethod` call targets a fully concrete signature (no `Any`, no
closures, no runtime dispatch), `juliac --trim` can trace the full call graph and
eliminate dead branches. `TrimCheck.@validate` passes without error.

---

## 8. Parametric Type Constraints

A method for `Buffer{8}` is a distinct specialisation from `Buffer{16}` — you can
define methods that exist only for specific values of a type parameter, gating
behaviour behind compile-time constraints.

### Plain Julia

```julia
struct Buffer{N}
    data::NTuple{N, UInt8}
end

Base.length(::Buffer{N}) where N = N

# Only Buffer{8} has this method
function set_from_bits(::Buffer{8}, bits::UInt8)
    Buffer{8}(ntuple(i -> UInt8((bits >> (i - 1)) & 1), 8))
end

set_from_bits(Buffer{8}(ntuple(_ -> 0x00, 8)), 0b10110001)   # works
# set_from_bits(Buffer{16}(...), 0b10110001)                  # MethodError at call site
```

The constraint is implicit — `Buffer{16}` simply has no `set_from_bits`. Callers
discover this only at the call site.

### With TypeContracts

```julia
struct Buffer{N}
    data::NTuple{N, UInt8}
end

@contract Buffer{8} begin
    set_from_bits(::Self, ::UInt8) :: Buffer{8} =>
        "reinterpret a byte as 8 single-bit fields"
end

Base.length(::Buffer{N}) where N = N

function set_from_bits(::Buffer{8}, bits::UInt8)
    Buffer{8}(ntuple(i -> UInt8((bits >> (i - 1)) & 1), 8))
end

@verify Buffer{8}

satisfies(Buffer{8},  Buffer{8})    # satisfied = true
satisfies(Buffer{16}, Buffer{8})    # satisfied = false (different type)
```

`@contract` can target any type, including parametric instantiations. `describe(Buffer{8})`
lists `set_from_bits` as mandatory, making the constraint explicit and discoverable.

---

## 9. `where`-Bounded Methods

`where T <: SomeAbstract` gates individual methods without restricting the containing
type — the struct stays broadly usable while specific methods state the extra
capabilities they require. TypeContracts replaces the conventional `<:` bound with an
explicit interface check that is compile-time verifiable and trim-safe.

### Plain Julia

```julia
struct DataStore
    backing::Dict{String, Vector{UInt8}}
end

# Method only available when T is a Number subtype
function store!(ds::DataStore, key::String, value::T) where T <: Number
    ds.backing[key] = reinterpret(UInt8, [value])
end

store!(DataStore(Dict()), "pi", 3.14f0)    # Float32 <: Number — works
# store!(DataStore(Dict()), "s", "hello")  # MethodError
```

The `where T <: Number` bound rejects non-subtypes but the error ("no method
matching `store!`") is less informative than it could be.

### With TypeContracts

```julia
struct DataStore
    backing::Dict{String, Vector{UInt8}}
end

# Dispatch through interface_trait — explicit, trim-safe, informative
function store!(ds::DataStore, key::String, value::T) where T
    _store!(ds, key, value, interface_trait(Number, T))
end
_store!(ds, key, val, ::Implemented{Number}) =
    (ds.backing[key] = reinterpret(UInt8, [val]); nothing)
_store!(ds, key, val, ::NotImplemented{Number}) =
    throw(InterfaceError("$(typeof(val)) does not satisfy the Number contract"))

store!(DataStore(Dict()), "pi", 3.14f0)    # works
store!(DataStore(Dict()), "s",  "hello")   # InterfaceError: String does not satisfy Number
```

The `interface_trait` dispatch pattern separates the constraint check from the
implementation. The error names the missing contract, the check is resolved at
compile time (via `@generated`), and the paths are trim-safe.

---

## Summary

| # | Pattern | Plain Julia | With TypeContracts |
|---|---|---|---|
| 1 | Default method behaviour | method on abstract type | `@contract` with `:optional` section; `@verify` at load time |
| 2 | Type hierarchies | `abstract type B <: A` | `@contract` per level; `@verify` checks all levels at once |
| 3 | Extending foreign types | define methods freely | `@contract` on any type; BaseTypeContracts.jl for Base |
| 4 | Holy Trait / type tagging | manual singleton dispatch | `interface_trait` → `Implemented`/`NotImplemented`; `@generated`, trim-safe |
| 5 | Delegation via composition | manual forwarding, `<: AbstractX` | `@delegate :field Interface` generates forwarders from contract; `@verify` checks completeness |
| 6 | Blanket abstract behaviour | method on abstract type | `@invariants` + `test_behavior` for semantic laws |
| 7 | `@generated` metaprogramming | ad-hoc `@generated` | `interface_trait` is `@generated` → statically compilable |
| 8 | Parametric constraints | method on `Concrete{N}` | `@contract Concrete{N}` + `@verify`; explicit and discoverable |
| 9 | `where`-bounded methods | `where T <: Abstract` | `interface_trait` dispatch — named contract, trim-safe |

Plain Julia covers all nine patterns — abstract types, parametric dispatch, and
multiple dispatch together are expressive enough without extra tooling. TypeContracts
adds three things the baseline lacks:

1. A **machine-readable contract declaration** that `@verify` / `satisfies` can check
   statically, giving load-time errors instead of runtime surprises.
2. **Behavioral invariants** via `@invariants` / `test_behavior` — laws that go
   beyond method existence and test real objects against real semantics.
3. **`--trim`-compatible trait dispatch** via `interface_trait`, safe for statically
   compiled binaries.

Pattern 4 (the Holy Trait) is the sharpest improvement: replacing ad-hoc singleton
dispatch with a registry-backed, `@generated`, trim-safe mechanism that is also
self-documenting and verifiable with `satisfies`.
