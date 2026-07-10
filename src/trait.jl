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

"""
    verified_trait(::Type{I}, ::Type{T}) -> Implemented{I} | NotImplemented{I}

Check whether `T` has been **verified** against the full contract for `I` — method
existence *and* declared return types — via [`@verify`](@ref), `@verify_all`, or
[`@delegate`](@ref). Unlike [`interface_trait`](@ref), which checks method existence
only, `verified_trait` reflects the complete `check_contract`/`satisfies` result at
the moment verification succeeded.

Returns `NotImplemented{I}()` for any `(I, T)` pair that has not been explicitly
verified — even if `T` would in fact satisfy the contract structurally. This is a
nominal, opt-in guarantee (like Rust's `impl Trait for T`), not a structural one:
`@verify`/`@verify_all`/`@delegate` are what seal it in.

Trim/juliac-compatible: sealing emits one concrete, singleton-returning method per
verified `(I, T)` pair at verification time (module load / precompile) — strictly
more specific than the generic fallback below, so dispatch resolves it statically.
No runtime check, no allocation, no registry lookup, same as `interface_trait`.

**Revise caveat:** redefining an implementation method after `@verify` leaves the
sealed method in place until `T` is re-verified; the Revise extension's live
re-check warns on a contract violation but does not automatically unseal
`verified_trait`.

# Example
```julia
@verify Circle    # after this succeeds, verified_trait(Shape, Circle) === Implemented{Shape}()

process(x) = _process(verified_trait(Shape, typeof(x)), x)
_process(::Implemented{Shape}, x)    = area(x)
_process(::NotImplemented{Shape}, x) = error("not a verified shape")
```
"""
verified_trait(::Type{I}, ::Type{T}) where {I, T} = NotImplemented{I}()

# Emit a concrete `verified_trait(::Type{K}, ::Type{T}) = Implemented{K}()` method for
# every interface `T`'s supertype chain is registered against. Called after
# `check_contract(T)` succeeds — an exception before this point means nothing gets
# sealed. `Core.eval` in `mod` at module-load/precompile time makes this an ordinary
# method definition (survives precompilation, no mutable registry), exactly like the
# `interface_trait` methods `@contract` emits.
function _seal_verified!(mod::Module, T::Type)
    for S in supertypes(T)
        K = _registry_key(S)
        isempty(_contract_specs(K)) && continue
        Core.eval(mod, :(TypeContracts.verified_trait(::Type{$K}, ::Type{$T}) = TypeContracts.Implemented{$K}()))
    end
    return nothing
end

# Single-interface form, used by `@verify T for_contract=I` and `@delegate`.
function _seal_verified!(mod::Module, T::Type, I::Type)
    K = _registry_key(I)
    Core.eval(mod, :(TypeContracts.verified_trait(::Type{$K}, ::Type{$T}) = TypeContracts.Implemented{$K}()))
    return nothing
end

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
