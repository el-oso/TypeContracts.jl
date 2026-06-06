# Behavioral Testing

Structural checks verify that the right methods *exist* with the right signatures. Behavioral testing goes further: it runs predicates against real objects to confirm the methods *behave correctly*.

TypeContracts separates these two phases deliberately. Structural checking happens at precompile time (no instances needed). Behavioral testing happens at test time, when you have real objects to exercise.

## `@invariants` — declare behavioral predicates

```julia
@invariants AbstractType begin
    "description" => x -> predicate(x)
    :optional
    "optional check" => x -> other_predicate(x)
end
```

Each entry is a `String => Function` pair. The function receives a single test object and must return `Bool`. The `:optional` separator works exactly as in [`@contract`](@ref): invariants above it are mandatory, those below are optional.

```julia
abstract type AbstractShape end

@invariants AbstractShape begin
    "area is non-negative"      => x -> area(x) >= 0
    "perimeter is non-negative" => x -> perimeter(x) >= 0
    :optional
    "name is non-empty when present" => x -> !isempty(name(x))
end
```

`@invariants` can be defined alongside or after the corresponding `@contract`. If both are present for the same type, `?T` will show both the method contract and the behavioral invariants in a single documentation section.

## `test_behavior(T, objects)` — run the invariants

Pass the type and a collection of test objects. Each object is `deepcopy`'d before each predicate runs, so predicates that mutate their argument do not interfere with each other.

```julia
c = Circle(0.0, 0.0, 3.0)
r = Rectangle(0.0, 0.0, 4.0, 5.0)

result = test_behavior(AbstractShape, [c, r])
```

The return value is a named tuple with three fields:

| Field | Type | Meaning |
|---|---|---|
| `passed` | `Bool` | `true` when all mandatory invariants hold for all objects |
| `results` | `Vector{NamedTuple}` | one entry per (invariant, object) pair |
| `mandatory_failures` | `Vector{NamedTuple}` | subset of `results` where mandatory invariants failed |

Each element of `results` has the shape:

```julia
(
    type        = AbstractShape,
    description = "area is non-negative",
    passed      = true,
    optional    = false,
    error       = "",
)
```

If a predicate throws an exception rather than returning `false`, `passed` is set to `false` and the exception message is stored in `error`.

## Using `test_behavior` in a test suite

The structured return value integrates cleanly with `Test`:

```julia
using Test

@testset "AbstractShape behavioral invariants" begin
    objects = [Circle(0, 0, 1.0), Rectangle(0, 0, 3.0, 4.0)]
    result  = test_behavior(AbstractShape, objects)

    @test result.passed

    # Report each result individually for granular failure messages.
    for r in result.results
        r.optional && continue   # skip optional invariants
        @test r.passed broken = r.optional
    end
end
```

## Checking a specific interface

`test_behavior(T, S, objects)` runs only the invariants registered for `S`, not the full supertype chain:

```julia
test_behavior(Labrador, AbstractDog, [Labrador()])
```

## Supertype chain walk

`test_behavior(T, objects)` (two-argument form) walks `supertypes(T)` and runs invariants from every ancestor that has registered behaviors. This mirrors the structural check in `check_contract`.

## `list_behaviors(T)`

Returns the [`BehaviorSpec`](@ref) vector registered directly for `T`:

```julia
list_behaviors(AbstractShape)
# [BehaviorSpec("area is non-negative", ..., false),
#  BehaviorSpec("perimeter is non-negative", ..., false),
#  BehaviorSpec("name is non-empty when present", ..., true)]
```

## Difference from structural checks

| | `@contract` / `@verify` | `@invariants` / `test_behavior` |
|---|---|---|
| When it runs | Precompile time | Test time |
| Requires instances | No | Yes |
| What it checks | Method existence + return type | Runtime behavior of real objects |
| Catches | Missing methods, wrong types | Wrong outputs, unexpected mutations, exceptions |
