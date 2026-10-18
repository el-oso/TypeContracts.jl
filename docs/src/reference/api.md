# API Reference

## Macros

```@docs
TypeContracts.@contract
TypeContracts.@verify
TypeContracts.@verify_all
TypeContracts.@invariants
TypeContracts.@delegate
```

## Structural checks

```@docs
TypeContracts.check_contract(::Type)
TypeContracts.check_contract(::Type, ::Type)
TypeContracts.check_trim_compat(::Type)
TypeContracts.check_trim_compat(::Type, ::Type)
TypeContracts.satisfies
TypeContracts.list_contract(::Type)
TypeContracts.list_contract(::Type, ::Val{:all})
TypeContracts.registered_contracts
```

## Testing helpers

```@docs
TypeContracts.implements(::Type, ::Type)
TypeContracts.implements(::Type)
TypeContracts.behavior_passes
TypeContracts.@test_implements
TypeContracts.@test_behavior_passes
```

## Behavioral testing

```@docs
TypeContracts.test_behavior(::Type{T}, objects) where T
TypeContracts.test_behavior(::Type{T}, ::Type{S}, objects) where {T,S}
TypeContracts.list_behaviors
TypeContracts.registered_behaviors
```

## Trait dispatch

```@docs
TypeContracts.interface_trait
TypeContracts.verified_trait
TypeContracts.Implemented
TypeContracts.NotImplemented
```

## Introspection

```@docs
TypeContracts.describe(::Type{T}; io::IO) where T
TypeContracts.describe(::Type{T}, ::Val{:all}; io::IO) where T
contract_signatures
```

!!! note
    `describe(T)` on a **concrete** type automatically shows the full supertype
    chain. `describe(T, Val(:all))` on an **abstract** type additionally walks
    upward through its own supertypes.

## Extension hooks

Another package can run its own checks whenever TypeContracts verifies a type, by adding a method to the verification hook:

```julia
TypeContracts._verify_hook(::TypeContracts._VerifyHook, mod::Module, T::Type, result)
```

- **When it is called:** once per verified type, by `@verify T`, `@verify T for_contract=I`, `@verify T subtypes=true` (for each subtype), `@verify_all` (for each type) and `@delegate`. The order is: contract check passes → `_verify_hook` → `verified_trait` sealed → `check_trim_compat` (if requested).
- **Arguments:** `mod` is the module that called the macro, and `result` has the shape `check_contract` returns, `(type, contracts, passed)`. `T` is usually concrete. It is a bare parametric name (a `UnionAll`) when `@delegate` wraps a parametric type or `@verify` is given one explicitly. `@verify` checks a bare name for method existence only, and does not seal `verified_trait` for it.
- **Throwing fails the verification:** the exception propagates out of the macro, and this call does not seal the type. A type that was not verified earlier therefore reads as `NotImplemented` from `verified_trait`; a seal from an earlier successful verification stays in place.
- **Under Revise**, the re-check after each edit calls the hook too, and reports any exception as a warning (see [Revise Integration](../guide/revise.md)).
- The fallback method, `_verify_hook(::Any, ::Any, ::Any, ::Any)`, does nothing. Only one package can define the generic method, and it must be written exactly as `_verify_hook(::_VerifyHook, ::Module, ::Type, ::Any)`. Methods restricted to particular types, such as `::Type{MyType}`, can coexist with it. A generic method that narrows another argument instead (for example `result::NamedTuple`) is ambiguous with them, and calls for those types throw a `MethodError`.

## Documenter integration

```@docs
TypeContracts.contract_md_string
TypeContracts.contract_md
```

## Trim diagnostics

Proactive pre-build scan and reactive juliac output translation. See the
[trim diagnostics guide](../guide/traits.md#Proactive-scan:-trim_report) for examples.

```@docs
TypeContracts.trim_report
TypeContracts.TrimReport
TypeContracts.TrimDiagnostics.explain_trim_failure
TypeContracts.TrimDiagnostics.TrimFailure
```

## Types

```@docs
TypeContracts.Self
TypeContracts.TypeParamRef
TypeContracts.InterfaceError
TypeContracts.MethodSpec
TypeContracts.BehaviorSpec
```
