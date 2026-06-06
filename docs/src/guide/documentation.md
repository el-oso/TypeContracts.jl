# Documentation Integration

TypeContracts folds contract information into Julia's native `?`-help system via `Base.Docs`. When you call `@contract` or `@invariants`, the contract is rendered as Markdown and attached to the target type's docstring — alongside any existing documentation, without clobbering it.

## How it works

`@contract` and `@invariants` call `_attach_contract_doc(T)` internally. This renders a Markdown section and registers it under a sentinel signature `Tuple{Val{:TypeContractsContract}}`. Julia's REPL helpmode aggregates all docstring entries for a binding, so `?T` shows:

1. The type's own docstring (from `Base` or the owning module).
2. A **TypeContracts Interface** section appended below a separator rule.

The two sections coexist without conflict because they are stored under different signatures in `Base.Docs`.

## Example — owned type

```julia
"""
    AbstractShape

Base abstract type for all 2-D geometric shapes.
"""
abstract type AbstractShape end

@contract AbstractShape "A 2-D geometric shape." begin
    area(::Self)::Float64      => "area enclosed by the shape"
    perimeter(::Self)::Float64 => "length of the boundary"
    :optional
    name(::Self)::String       => "human-readable display name"
end
```

Calling `?AbstractShape` in the REPL now shows both the type's docstring and the contract section:

```
  AbstractShape

  Base abstract type for all 2-D geometric shapes.

  ────────────────────────────────────────────────────────────────────────────

  TypeContracts Interface

  A 2-D geometric shape.

  Mandatory methods

    •  area(::Self) :: Float64 — area enclosed by the shape

    •  perimeter(::Self) :: Float64 — length of the boundary

  Optional methods

    •  name(::Self) :: String — human-readable display name
```

## Example — retroactive contract on a foreign type

Contracts on types you do not own work the same way. The contract section is appended below the existing documentation without modifying `Base`:

```julia
@contract AbstractVector{T} begin
    Base.getindex(::Self, ::Int) :: T
    Base.push!(::Self, ::T)
    Base.length(::Self) :: Int
end
```

`?AbstractVector` in the REPL now shows Base's own documentation followed by the TypeContracts section.

## juliac / static compilation

The documentation machinery (`Markdown`, `Base.Docs`, `Base.Docs.meta`) is load-time-only and not safe to use in a juliac-compiled binary at runtime. TypeContracts guards against this with a master switch:

```julia
disable_docs!()   # set _DOCS_ENABLED[] = false
enable_docs!()    # restore
```

In a static binary that registers contracts from `__init__`, call `disable_docs!()` first:

```julia
function __init__()
    TypeContracts.disable_docs!()
    @contract AbstractShape begin
        area(::Self) :: Float64
    end
end
```

When `disable_docs!()` is active, `@contract` and `@invariants` still register contracts in the structural registry — only the `?`-documentation attachment is skipped.

## The runtime path is always doc-free

[`interface_trait`](@ref), [`check_contract`](@ref), and [`satisfies`](@ref) never touch `Markdown` or `Base.Docs`, regardless of the `_DOCS_ENABLED` flag. They are safe in any context.

## `@invariants` updates the doc section

When `@invariants` is called after `@contract` on the same type, the contract doc section is refreshed to include both method specs and behavioral invariants. The prior entry under the sentinel signature is deleted first (before re-registering), so no "Replacing docs" warning is emitted.
