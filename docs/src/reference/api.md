# API Reference

## Macros

```@docs
TypeContracts.@contract
TypeContracts.@verify
TypeContracts.@verify_all
TypeContracts.@invariants
```

## Structural checks

```@docs
TypeContracts.check_contract
TypeContracts.satisfies
TypeContracts.list_contract(::Type)
TypeContracts.list_contract(::Type, ::Val{:all})
TypeContracts.registered_contracts
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
TypeContracts.Implemented
TypeContracts.NotImplemented
```

## Introspection

```@docs
TypeContracts.describe(::Type{T}; io::IO) where T
TypeContracts.describe(::Type{T}, ::Val{:all}; io::IO) where T
```

## Documentation control

```@docs
TypeContracts.disable_docs!
TypeContracts.enable_docs!
```

## Types

```@docs
TypeContracts.Self
TypeContracts.TypeParamRef
TypeContracts.InterfaceError
TypeContracts.MethodSpec
TypeContracts.BehaviorSpec
```
