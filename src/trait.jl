"""
    interface_trait(::Type{I}, ::Type{T}) -> Implemented{I} | NotImplemented{I}

Check if `T` satisfies the mandatory contract for `I` (method existence only).
Returns a singleton trait type suitable for dispatch.

Trim/juliac-compatible: implemented as a `@generated` function. Both `I` and `T`
are known at specialization time, so the contract is looked up in the registry
*during code generation* and the body emitted as a fixed conjunction of concrete
`hasmethod(f, Tuple{…})` calls — no runtime registry lookup, no abstractly-typed
`Function`, no dynamically-built signature. The result is statically resolvable
and passes `juliac --trim` verification.

Because the contract is baked in at the first call for a given `(I, T)` pair,
register contracts before querying them — the standard usage (contracts declared
at module load, checked afterward).

# Example
```julia
process(x) = _process(interface_trait(AbstractShape, typeof(x)), x)
_process(::Implemented{AbstractShape}, x) = area(x)
_process(::NotImplemented{AbstractShape}, x) = error("not a shape")
```
"""
@generated function interface_trait(::Type{I}, ::Type{T}) where {I, T}
    specs = get(_registry, _registry_key(I), nothing)
    isnothing(specs) && return :(NotImplemented{I}())

    checks = Expr[]
    for spec in specs
        spec.optional && continue
        sig = _build_sig(spec.arg_types, T)        # concrete Tuple type, built now
        push!(checks, :(hasmethod($(spec.f), $sig)))
    end
    isempty(checks) && return :(Implemented{I}())

    cond = foldl((a, b) -> :($a && $b), checks)
    return :($cond ? Implemented{I}() : NotImplemented{I}())
end
