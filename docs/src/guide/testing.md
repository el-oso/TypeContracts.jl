# Testing

TypeContracts provides dedicated testing helpers that integrate naturally with Julia's `Test` standard library. They complement the compile-time tools — after `@verify` has confirmed methods exist at precompile time, these functions let you write clean, readable test assertions.

## The two phases

```
@contract / @verify / check_contract  →  methods exist, return types correct  (compile time)
implements / @test_implements         →  structural contract, boolean result   (test time)
@invariants / test_behavior           →  methods behave correctly              (test time)
behavior_passes / @test_behavior_passes
```

## `implements(T, S)` — boolean structural check

`implements(T, S)` is the test-friendly counterpart to `satisfies`. It returns a plain `Bool` and throws `ArgumentError` if `S` has no registered contract (catching the common mistake of checking against an unregistered type):

```julia
using Test, TypeContracts

@test implements(Circle, AbstractShape)
@test !implements(BadShape, AbstractShape)
@test implements(Circle, AbstractShape; include_optional = true)
```

Pass `include_optional = true` to also require all optional methods.

`implements` errors on an unregistered contract, surfacing the mistake immediately:

```julia
implements(Circle, Real)
# ArgumentError: no contract registered for Real
```

## `implements(T)` — check all applicable contracts

The one-argument form walks `T`'s entire supertype chain and checks every registered contract it finds. It errors if `T` has no applicable contracts at all — a useful guard against checking the wrong type:

```julia
@test implements(Circle)         # checks AbstractShape, and any other ancestor contracts
@test !implements(BadShape)      # fails because AbstractShape contract is violated

implements(SomeUnconstrainedType)
# ArgumentError: no contracts registered for any supertype of SomeUnconstrainedType
```

This is the simplest way to assert that a concrete type is fully correct:

```julia
@testset "Circle satisfies all contracts" begin
    @test implements(Circle)
end
```

## `@test_implements T S` — macro with failure detail

`@test_implements` records a `Test` result exactly like `@test`, but on failure it also prints the list of missing methods to `stderr` before the failure is recorded:

```julia
using Test, TypeContracts

@test_implements Circle AbstractShape
# on failure: prints missing methods, then records a Test failure
```

This avoids the need to run `satisfies` separately to find out what went wrong.

## `behavior_passes(T, objects)` — boolean behavioral check

`behavior_passes` wraps `test_behavior` and returns a plain `Bool`:

```julia
objects = [Circle(1.0), Circle(5.0)]

@test behavior_passes(Circle, objects)
@test behavior_passes(Circle, objects; S = AbstractShape)          # specific interface only
@test behavior_passes(Circle, objects; include_optional = true)    # require optional invariants
```

`S` restricts the check to one specific interface (useful when a type has multiple behavioral ancestors).

## `@test_behavior_passes T objects` — macro with failure detail

Like `@test_implements`, the macro records a `Test` result and on failure prints which invariants failed:

```julia
@test_behavior_passes Circle [Circle(1.0), Circle(5.0)]
# on failure: prints failed invariants with their descriptions and error messages
```

## Putting it together

A typical test file for a new concrete type:

```julia
using Test, TypeContracts

@testset "Circle" begin
    @testset "structural" begin
        @test_implements Circle AbstractShape
    end

    @testset "behavioral" begin
        objects = [Circle(1.0), Circle(5.0), Circle(0.0)]
        @test_behavior_passes Circle objects
    end
end
```

For types with multiple supertypes, `implements(T)` and `@test_behavior_passes` each walk the full chain automatically:

```julia
@testset "Labrador" begin
    @test implements(Labrador)
    @test_behavior_passes Labrador [Labrador()]
end
```

## Relationship to `satisfies` and `test_behavior`

`implements` and `behavior_passes` are thin convenience wrappers. Use the underlying functions directly when you need the diagnostic details:

```julia
# detailed inspection
r = satisfies(BadShape, AbstractShape)
r.satisfied        # false
r.missing_methods  # ["perimeter(::Self) :: Float64"]
r.missing_optional # []

# granular behavioral results
result = test_behavior(Circle, [Circle(1.0)])
for r in result.results
    @test r.passed broken = r.optional
end
```

See [Verification](verification.md) and [Behavioral Testing](behavioral.md) for the full API of those underlying functions.
