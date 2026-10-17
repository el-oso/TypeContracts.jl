# `contract_signatures` and the verify hook

Two additions and two fixes, released together as 0.14.1. All of them are dev/precompile-time behavior, and none changes the `@contract`, `@verify`, `@verify_all` or `@delegate` syntax. None is breaking.

- **A. `contract_signatures(mod; optional = false)`** lists the resolved signature of every contract method, for each concrete contract type defined in `mod`.
- **B. `_verify_hook(::_VerifyHook, mod, T, result)`** is a dispatch hook. Every verification path calls it once per verified type after the check passes.
- **C. Parametric types are skipped, not falsely verified.** `@verify_all`, `@verify T subtypes=true` and the Revise re-check stop treating a bare parametric name (a `UnionAll`) as a concrete type.
- **D. The Revise re-check warns on every exception**, not only on `InterfaceError`.

The first consumer is StrictMode.jl, which depends on TypeContracts. TypeContracts gains no dependency on StrictMode. Neither addition does any performance analysis.

## A. `contract_signatures`

```julia
contract_signatures(mod::Module; optional::Bool = false)
    -> Vector{@NamedTuple{f::Function, sig::Type{<:Tuple}, return_type::Type,
                          T::Type, contract::Type, mandatory::Bool}}
```

**Which types.** It covers the same set of types that `@verify_all` checks in `mod` (see C): names bound in `mod`, `isconcretetype`, with `parentmodule(T) === mod`, and with at least one supertype that has a registered contract. Bare parametric names are left out, so every entry has fully resolved type parameters. Contracts on foreign types are included, for example a type in `mod` that subtypes `AbstractVector` when `@contract AbstractVector{T}` is registered.

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

## C. Parametric types in the bulk paths

**Current behavior.** `_concrete_subtypes`, `_verify_all_in_module` and `_revise_check_module` each skip a type only when `isabstracttype` is true. A bare parametric name such as `Bucket` (from `struct Bucket{T} <: AbstractBucket{T}`) is a `UnionAll`, for which `isabstracttype` is `false`, so it gets checked as if it were concrete. A `TypeParamRef` then resolves to `Any`, so the return-type check is skipped and a wrong return type passes. The seal is also placed on `Bucket` itself, so `verified_trait(AbstractBucket, Bucket{Int})` returns `NotImplemented`.

**New behavior.** All three paths use one shared function, `_contract_types_in_module(mod)`; `_concrete_subtypes` uses the same predicate. A type is checked only if `isconcretetype(T)` is true. A non-abstract type that fails that test is skipped with one `@warn`:

```
┌ Warning: @verify_all skipped Bucket: it is parametric, and its contract can only be
│ checked for concrete parameters.
│ To check it, add `@verify` for each instance your code uses, before `@verify_all`:
│     @verify Bucket{Int}
│     @verify Bucket{Float64}
│ Any verified instance also silences this warning. If the contract does not depend
│ on the parameter, one representative instance is enough.
└ type = Bucket, contract = AbstractBucket
```

The example instance uses `Int` for each type parameter. Its only purpose is to show the syntax, so the message says "for each instance your code uses" rather than suggesting `Int` is right. For `subtypes=true` the first line reads `@verify AbstractBucket subtypes=true skipped Bucket: …`.

**Silencing the warning.** The warning is not emitted when at least one concrete instance of the type has already been verified. TypeContracts checks this by looking for a sealed `verified_trait` method whose second argument is `Type{X}`, where `X` is a concrete instance of the same type (same `Base.unwrap_unionall(T).name`). It reads the method table and keeps no new state. Because `@verify_all` goes at the end of a module, an earlier `@verify Bucket{Int}` silences it. The Revise re-check skips parametric names without warning, since `@verify_all` already warned at load time.

## D. Revise re-check exceptions

`_check_contract_warn` warns `"Contract violation detected by Revise"` on an `InterfaceError` and `"Contract re-check failed"`, with the exception and backtrace, on any other exception. Before this change, other exceptions were dropped without a message. With the hook (B) in this path, that would also hide hook bugs.

## Testing

New test file `test/introspection_signatures_test.jl` (A) and additions to `test/verify_all_test.jl` (B).

- A: a plain contract; `Self` in a non-first position; a parametric contract (`TypeParamRef` resolved in both `sig` and `return_type`); a foreign-type contract with its subtype in the test module; the `optional` flag; and a consistency check that `hasmethod(e.f, e.sig)` holds for every entry of a module that passes `@verify_all`.
- B: the hook runs once per type, with the right `mod`/`T`/`result`, for each of the five paths; a throwing hook makes `@verify` throw, and `verified_trait` stays `NotImplemented`; the Revise path turns a hook exception into a `@warn` (tested with `@test_logs`); with no hook defined, behavior is unchanged (the existing suite covers this).
- C: a parametric type with a wrong return type is skipped with the warning by both `@verify_all` and `subtypes=true`, and is not sealed; after `@verify Bad{Int}` it is skipped without a warning; a non-parametric concrete type is still checked; `contract_signatures` omits the bare name.
- D: `test/revise_check_test.jl` (already written): an `InterfaceError` gives the violation warning, and a `MethodError` (from `check_contract(Union{})`) gives the "re-check failed" warning.

**Test runner.** The suite runs on TestItemRunner. Shared fixtures are in `@testmodule TCFixtures`. Individual items run through the julia MCP server during iteration, and `Pkg.test()` is the gate before release.

## Release

0.14.1, with a CHANGELOG entry. StrictMode's existing compat, `TypeContracts = "0.13, 0.14"`, already admits it. Docs to update: `guide/introspection.md` (A), `guide/verification.md` (C: parametric types and the silencing rule), `guide/revise.md` (D), and `reference/api.md` (A, and B under "Extension hooks").
