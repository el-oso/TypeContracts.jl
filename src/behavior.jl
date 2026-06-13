"""
    behavior_passes(T::Type, objects; S=nothing, include_optional=false) -> Bool

Return `true` if all mandatory behavioral invariants for `T`'s supertype chain
pass against `objects`. Designed for direct use with `@test`:

```julia
@test behavior_passes(Counter, [Counter(0), Counter(5)])
@test behavior_passes(Counter, [Counter(0)]; S=AbstractCounter)
@test behavior_passes(Counter, [Counter(0)]; include_optional=true)
```

Pass `S` to test only the invariants registered for a specific interface.
Pass `include_optional=true` to require optional invariants as well.
"""
function behavior_passes(
        ::Type{T},
        objects;
        S::Union{Type, Nothing} = nothing,
        include_optional::Bool = false,
    )::Bool where {T}
    r = isnothing(S) ? test_behavior(T, objects) : test_behavior(T, S, objects)
    include_optional || return r.passed
    return all(res -> res.passed, r.results)
end

"""
    @test_implements T S

Assert that `T` satisfies the structural contract for `S`, integrating with
the active `Test.@testset`. On failure, prints the list of missing methods
before recording the test failure. Requires `using Test` at the call site.

```julia
using Test, TypeContracts
@test_implements Circle AbstractShape
```
"""
macro test_implements(T_expr, S_expr)
    T_str = string(T_expr)
    S_str = string(S_expr)
    r = gensym("r")
    m = gensym("m")
    # esc(quote …) disables hygiene so @test resolves in the caller's module;
    # gensyms prevent local variable collisions with caller scope.
    return esc(
        quote
            let $r = TypeContracts.satisfies($T_expr, $S_expr)
                if !$r.satisfied
                    printstyled(
                        stderr,
                        "\n  @test_implements ", $T_str, " ", $S_str, " — missing methods:\n";
                        bold = true, color = :red,
                    )
                    for $m in $r.missing_methods
                        printstyled(stderr, "    • ", $m, "\n"; color = :light_black)
                    end
                end
                @test $r.satisfied
            end
        end
    )
end

"""
    @test_behavior_passes T objects

Assert that all mandatory behavioral invariants for `T`'s supertype chain pass
against `objects`, integrating with the active `Test.@testset`. On failure,
prints which invariants failed before recording the test failure.
Requires `using Test` at the call site.

```julia
using Test, TypeContracts
@test_behavior_passes Counter [Counter(0), Counter(5)]
```
"""
macro test_behavior_passes(T_expr, objs_expr)
    T_str = string(T_expr)
    r = gensym("r")
    f = gensym("f")
    return esc(
        quote
            let $r = TypeContracts.test_behavior($T_expr, $objs_expr)
                if !$r.passed
                    printstyled(
                        stderr,
                        "\n  @test_behavior_passes ", $T_str, " — failed invariants:\n";
                        bold = true, color = :red,
                    )
                    for $f in $r.mandatory_failures
                        printstyled(stderr, "    • ", $f.description, "\n"; color = :light_black)
                        isempty($f.error) ||
                            printstyled(stderr, "      error: ", $f.error, "\n"; color = :light_black)
                    end
                end
                @test $r.passed
            end
        end
    )
end

"""
    test_behavior(T::Type, objects) -> NamedTuple

Run all behavioral invariants registered for `T`'s supertype chain
against `deepcopy`'d test `objects`. Returns `(passed, results, mandatory_failures)`.

`passed` is true when all mandatory invariants hold for all objects.
"""
function test_behavior(::Type{T}, objects) where {T}
    results = NamedTuple{
        (:type, :description, :passed, :optional, :error),
        Tuple{Type, String, Bool, Bool, String},
    }[]

    for S in supertypes(T)
        behaviors = _behavior_specs(_registry_key(S))
        isempty(behaviors) && continue
        _run_behaviors!(results, S, behaviors, objects)
    end

    mandatory_failures = filter(r -> !r.passed && !r.optional, results)
    return (passed = isempty(mandatory_failures), results = results, mandatory_failures = mandatory_failures)
end

"""
    test_behavior(T::Type, S::Type, objects) -> NamedTuple

Run behavioral invariants registered for `S` specifically against objects of type `T`.
"""
function test_behavior(::Type{T}, ::Type{S}, objects) where {T, S}
    results = NamedTuple{
        (:type, :description, :passed, :optional, :error),
        Tuple{Type, String, Bool, Bool, String},
    }[]

    behaviors = _behavior_specs(S)
    !isempty(behaviors) && _run_behaviors!(results, S, behaviors, objects)

    mandatory_failures = filter(r -> !r.passed && !r.optional, results)
    return (passed = isempty(mandatory_failures), results = results, mandatory_failures = mandatory_failures)
end

function _run_behaviors!(results, S::Type, behaviors::Vector{BehaviorSpec}, objects)
    for bspec in behaviors
        for obj in objects
            passed = true
            errmsg = ""
            try
                passed = bspec.predicate(deepcopy(obj))::Bool
            catch e
                passed = false
                errmsg = sprint(showerror, e)
            end
            push!(
                results, (
                    type = S, description = bspec.description,
                    passed = passed, optional = bspec.optional, error = errmsg,
                )
            )
        end
    end
    return
end
