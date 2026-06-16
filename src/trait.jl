"""
    interface_trait(::Type{I}, ::Type{T}) -> Implemented{I} | NotImplemented{I}

Check if `T` satisfies the mandatory contract for `I` (method existence only).
Returns a singleton trait type suitable for dispatch.

Trim/juliac-compatible. `@contract I` generates a concrete method
`interface_trait(::Type{I}, ::Type{T}) where {T}` whose body is a fixed conjunction
of concrete `hasmethod(f, Tuple{…})` calls — no runtime registry lookup, no
abstractly-typed `Function`, no dynamically-built signature. Because the method is
emitted by `@contract` (ordinary method definition, not a `Dict` mutation), it is
serialized into the registering package's precompile cache and survives precompilation
and package reloads. `hasmethod` is a method-table lookup that runs without the JIT or
type inferencer, so the result is statically resolvable and passes `juliac --trim`.

Interfaces with no registered contract fall through to the method below and return
`NotImplemented{I}()`.

# Example
```julia
process(x) = _process(interface_trait(AbstractShape, typeof(x)), x)
_process(::Implemented{AbstractShape}, x) = area(x)
_process(::NotImplemented{AbstractShape}, x) = error("not a shape")
```
"""
interface_trait(::Type{I}, ::Type{T}) where {I, T} = NotImplemented{I}()

# Generator body for the per-interface `interface_trait` methods emitted by `@contract`.
# Runs at specialization time with `T` the concrete querying type. `arg_lists`/`fns` hold
# the argument-type markers and function objects for each mandatory method, baked into the
# generated method at macro-expansion time. `_build_sig` resolves `Self`→`T` and
# `TypeParamRef`→concrete parameter *now*, so the emitted body is a fixed conjunction of
# concrete `hasmethod(f, Tuple{…})` calls (trim-safe; no runtime registry lookup).
function _build_trait_expr(@nospecialize(I), @nospecialize(T), arg_lists, fns)
    checks = Expr[]
    for i in eachindex(fns)
        sig = _build_sig(arg_lists[i], T)
        push!(checks, :(hasmethod($(fns[i]), $sig)))
    end
    isempty(checks) && return :($(Implemented{I}()))
    cond = foldl((a, b) -> :($a && $b), checks)
    return :($cond ? $(Implemented{I}()) : $(NotImplemented{I}()))
end
