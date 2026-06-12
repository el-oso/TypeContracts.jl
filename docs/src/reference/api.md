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
TypeContracts.check_contract
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
TypeContracts.Implemented
TypeContracts.NotImplemented
```

## Introspection

```@docs
TypeContracts.describe(::Type{T}; io::IO) where T
TypeContracts.describe(::Type{T}, ::Val{:all}; io::IO) where T
```

## Types

```@docs
TypeContracts.Self
TypeContracts.TypeParamRef
TypeContracts.InterfaceError
TypeContracts.MethodSpec
TypeContracts.BehaviorSpec
```
