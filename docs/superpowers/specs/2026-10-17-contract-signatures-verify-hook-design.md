# `contract_signatures` and the verify hook

Two additions to TypeContracts. Both are dev/precompile-time tools, and neither changes the `@contract`, `@verify`, `@verify_all` or `@delegate` syntax.

- **A. `contract_signatures(mod; optional = false)`** lists the resolved signature of every contract method, for each concrete contract type defined in `mod`.
- **B. `_verify_hook(::_VerifyHook, mod, T, result)`** is a dispatch hook. Every verification path calls it once per verified type after the check passes.

The first consumer is StrictMode.jl, which depends on TypeContracts. TypeContracts gains no dependency on StrictMode. Neither addition does any performance analysis.

## A. `contract_signatures`

```julia
contract_signatures(mod::Module; optional::Bool = false)
    -> Vector{@NamedTuple{f::Function, sig::Type{<:Tuple}, return_type::Type,
                          T::Type, contract::Type, mandatory::Bool}}
```

**Which types.** It covers the same set of types that `@verify_all` checks in `mod`: names bound in `mod`, not abstract, with `parentmodule(T) === mod`, and with at least one supertype that has a registered contract. Contracts on foreign types are included, for example a type in `mod` that subtypes `AbstractVector` when `@contract AbstractVector{T}` is registered.

**One entry** for each `(T, contract in T's supertype chain, method spec)` triple:

| field | value |
|---|---|
| `f` | `spec.f` |
| `sig` | `_build_sig(spec.arg_types, T)`, the same `Tuple{…}` that `check_contract` passes to `hasmethod`. It can go straight into `hasmethod(f, sig)` and `Base.return_types(f, sig)`. |
| `return_type` | `_resolve_rt_spec(T, spec)`, the same expected return type that `check_contract` compares against. `Any` when the contract declares none. |
| `T` | the concrete type |
| `contract` | the registry key of the contract (`_registry_key(S)`) |
| `mandatory` | `!spec.optional` |

Optional specs are left out unless `optional = true`.

**One copy of the resolution logic.** `check_contract` and `contract_signatures` both call `_build_sig` and `_resolve_rt_spec`, which already exist as named functions. Today the type-selection filter is written out twice, in `_verify_all_in_module` and `_revise_check_module`. It moves into one function, `_contract_types_in_module(mod)`, which those two and `contract_signatures` all call.

**Trim.** This is not trim-safe, because it uses `names`, `supertypes` and the registry. The docstring says so. `trim_test.jl` needs no change: `interface_trait` and `verified_trait` stay the only trim-safe entry points.

**Exported.** It is documented in `reference/api.md` under Introspection and in `guide/introspection.md`.

## B. Verify hook

```julia
struct _VerifyHook end
_verify_hook(::_VerifyHook, mod::Module, T::Type, result) = nothing   # fallback
```

This uses the same dispatch-hook pattern as `_DocSyncHook` and `_MdRenderHook`. A consumer defines a more specific method in its own module. Nothing is registered in `__init__` and no mutable state is involved, so the hook survives precompilation and reloads. Only one consumer can define the generic method. A consumer can also define methods only for its own types, for example `_verify_hook(::_VerifyHook, ::Module, ::Type{MyType}, result)`. The tests use that form so they don't leak into other test items.

**When it is called.** Once per verified type, in every path that seals `verified_trait`, in this order:

`check passes → _verify_hook → _seal_verified! → check_trim_compat (if requested)`

If the hook throws, the exception propagates and that type is not sealed. A failed gate therefore never leaves `verified_trait` reporting `Implemented`.

| path | `mod` | `result` |
|---|---|---|
| `@verify T` | calling module | `check_contract(T)` result |
| `@verify T for_contract=I` | calling module | `check_contract(T, I)` result |
| `@verify T subtypes=true` | calling module | `check_contract(S)` result, for each leaf `S` |
| `@verify_all` | calling module | `check_contract(T)` result, for each type |
| `@delegate W :field I` | calling module | `(type = W, contracts = [_registry_key(I)], passed = true)`, the same shape as `check_contract` |

**Revise path.** The re-check that runs after a Revise edit calls the hook inside its existing `try`. A hook exception becomes a `@warn`, the same way a contract violation does. The re-check needs `mod`, so `_revise_tracked_types` stores `(mod, T)` pairs instead of `T` alone. `_revise_check_module` already has `mod`.

**Exported?** No. The hook is internal-named, like the existing hooks, and is documented in `reference/api.md` under a new "Extension hooks" heading.

## Testing

New test file `test/introspection_signatures_test.jl` (A) and additions to `test/verify_all_test.jl` (B).

- A: a plain contract; `Self` in a non-first position; a parametric contract (`TypeParamRef` resolved in both `sig` and `return_type`); a foreign-type contract with its subtype in the test module; the `optional` flag; and a consistency check that `hasmethod(e.f, e.sig)` holds for every entry of a module that passes `@verify_all`.
- B: the hook runs once per type, with the right `mod`/`T`/`result`, for each of the five paths; a throwing hook makes `@verify` throw, and `verified_trait` stays `NotImplemented`; the Revise path turns a hook exception into a `@warn` (tested with `@test_logs`); with no hook defined, behavior is unchanged (the existing suite covers this).

## Release

CHANGELOG entry under a new version. Both additions are additive.

## Open questions

1. **Version number:** 0.15.0 or 0.14.1? 0.14.0 is the latest registry release.
2. **The Revise re-check swallows non-`InterfaceError` exceptions without a word.** `_check_contract_warn` does `catch e; e isa InterfaceError && @warn …; end`, so any other exception disappears. With a hook in that path, a hook bug would vanish the same way. I propose warning on every exception there, with the exception and type shown. This would be a small fix in the same change.
3. **Parametric types bound by name:** `struct Bucket{T} <: AbstractBucket{T}` binds a `UnionAll`. I haven't checked how `@verify_all` currently treats it. Whatever it does, `contract_signatures` will match it (it uses the same filter), and I'll record the behavior in a test.
