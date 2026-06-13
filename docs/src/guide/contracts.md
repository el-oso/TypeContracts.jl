# Defining Contracts

A contract declares what methods an abstract type requires from any concrete subtype that implements it.

## Basic syntax

```julia
@contract AbstractType begin
    method1(::Self, ::ArgType)
    method2(::Self) :: ReturnType
end
```

[`Self`](@ref) is a sentinel type that is substituted with the concrete type being checked at verification time. Every argument in a method signature must be typed.

```julia
@contract AbstractSerializer begin
    encode(::Self, ::Any) :: String
    decode(::Self, ::String)          # :: Any when unspecified
end
```

`@contract` automatically defines `abstract type AbstractSerializer end` and stub functions (`function encode end`, `function decode end`) if they are not already defined in the calling module.

::: tip When to declare the abstract type manually

If your type needs a supertype, declare it explicitly before `@contract`:

```julia
abstract type AbstractSerializer <: AbstractIO end   # supertype required
@contract AbstractSerializer begin
    encode(::Self, ::Any) :: String
    decode(::Self, ::String)
end
```

`@contract` sees the pre-existing definition and does not overwrite it.

:::

## Return types

A return type annotation is enforced by Julia's type inferencer (`Base.return_types`). At verification time, the inferred return type must be `<:` the declared type:

```julia
@contract AbstractSerializer begin
    encode(::Self, ::Any) :: String
end

struct GoodSerializer <: AbstractSerializer end
encode(::GoodSerializer, x) = string(x)   # inferred String ✓

struct BadSerializer <: AbstractSerializer end
encode(::BadSerializer, x) = 42            # inferred Int ✗

check_contract(GoodSerializer)   # passes
check_contract(BadSerializer)
# InterfaceError: encode(::Self, ::Any) :: String — return Int64 ⊄ String
```

If no return type is declared, the inferred type is not checked (it is treated as `Any`).

## Optional methods

The `:optional` separator splits the block into mandatory (above) and optional (below) methods. [`@verify`](@ref) and [`check_contract`](@ref) enforce only mandatory methods. [`satisfies`](@ref) reports missing optional methods separately in its `missing_optional` field.

```julia
@contract AbstractShape begin
    area(::Self)      :: Float64    # mandatory
    perimeter(::Self) :: Float64    # mandatory
    :optional
    name(::Self)  :: String         # optional
    color(::Self) :: Symbol         # optional
end
```

A type that implements only mandatory methods passes `@verify`:

```julia
struct Circle <: AbstractShape
    radius::Float64
end
area(c::Circle)::Float64      = π * c.radius^2
perimeter(c::Circle)::Float64 = 2π * c.radius

@verify Circle   # passes; name and color are not required

satisfies(Circle, AbstractShape)
# (satisfied = true, missing_methods = [], missing_optional = ["name(::Self) :: String", "color(::Self) :: Symbol"])
```

## Parametric interfaces

When the abstract type has type parameters, they can be referenced directly in method signatures using the `@contract AbstractType{T,N}` header form:

```julia
@contract AbstractContainer{T} begin
    cget(::Self, ::Int) :: T     # return type = element type
    cset!(::Self, ::T, ::Int)    # second argument must accept T
    clen(::Self) :: Int
end
```

At check time, `T` is resolved by inspecting the concrete type's supertype chain. For `FloatBox <: AbstractContainer{Float64}`, `T` becomes `Float64`:

```julia
struct FloatBox <: AbstractContainer{Float64}
    data::Vector{Float64}
end

cget(b::FloatBox, i::Int)::Float64     = b.data[i]
cset!(b::FloatBox, v::Float64, i::Int) = (b.data[i] = v)
clen(b::FloatBox)::Int                 = length(b.data)

@verify FloatBox   # T resolves to Float64; inferred return type of cget matches ✓
```

Multiple parameters work the same way:

```julia
abstract type AbstractGrid{T,N} end

@contract AbstractGrid{T,N} begin
    gridget(::Self, ::NTuple{N,Int}) :: T
    griddims(::Self) :: NTuple{N,Int}
end
```

## Interface description and per-method docs

An optional string argument adds an interface-level description. Per-method prose is written as `sig => "description"` using the `=>` operator:

```julia
@contract AbstractShape "A 2-D geometric shape." begin
    area(::Self)::Float64      => "area enclosed by the shape"
    perimeter(::Self)::Float64 => "length of the boundary"
    :optional
    name(::Self)::String       => "human-readable display name"
end
```

Both the description and per-method prose are:
- shown by [`describe`](@ref)
- folded into the type's `?`-help via [`Base.Docs`](https://docs.julialang.org/en/v1/stdlib/REPL/#stdlib-repl-docs) (see [Documentation Integration](documentation.md))

## Retroactive contracts for foreign types

`@contract` works on any abstract type, including types you do not own. For foreign types and qualified functions (`Base.getindex`, etc.) the type and functions already exist, so no stubs are generated:

```julia
using TypeContracts

# Add a contract to a Base abstract type.
@contract AbstractVector{T} begin
    Base.getindex(::Self, ::Int) :: T
    Base.setindex!(::Self, ::T, ::Int)
    Base.length(::Self) :: Int
    Base.push!(::Self, ::T)
end
```

`check_contract(Vector{Int})` then verifies that `Vector{Int}` satisfies this contract.

## Supertype chain

Contracts are **inherited automatically** through the abstract type hierarchy. A type is checked against contracts for every ancestor that has a registered contract — no explicit composition declaration is needed:

```julia
# AbstractAnimal has no supertype constraint, so @contract creates it automatically.
# AbstractDog needs <: AbstractAnimal, so it must be declared explicitly.
abstract type AbstractDog <: AbstractAnimal end

@contract AbstractAnimal begin
    speak(::Self) :: String
end

@contract AbstractDog begin
    fetch(::Self, item) :: Nothing
end

struct Labrador <: AbstractDog end
speak(::Labrador) = "woof"
fetch(::Labrador, item) = nothing

@verify Labrador   # checks both AbstractAnimal and AbstractDog contracts ✓
```
