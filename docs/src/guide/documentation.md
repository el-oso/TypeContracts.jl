# Documentation Integration

TypeContracts folds contract information into Julia's native `?`-help system via `Base.Docs`. When you call `@contract` or `@invariants`, the contract is rendered as Markdown and attached to the target type's docstring — alongside any existing documentation, without clobbering it.

## How it works

The Markdown rendering lives in a **package extension** (`TypeContractsREPLExt`) that is loaded automatically when Julia's `REPL` package is present — i.e., in every interactive session. In scripts and juliac-compiled binaries, `REPL` is absent, the extension never loads, and no Markdown machinery is ever pulled into the binary. No manual opt-out is required.

When the extension is active, `@contract` and `@invariants` attach a contract section under a sentinel signature `Tuple{Val{:TypeContractsContract}}`. Julia's REPL helpmode aggregates all docstring entries for a binding, so `?T` shows:

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

No manual steps are required. The doc-attachment code lives entirely in the REPL extension. Because `REPL` is not included in juliac-compiled binaries, the extension never activates and `Markdown`/`Base.Docs` are never pulled into the binary.

The structural runtime path — [`interface_trait`](@ref), [`check_contract`](@ref), [`satisfies`](@ref) — never touches Markdown or Base.Docs in any context. They call only `hasmethod` and `Base.return_types`.

## `@invariants` updates the doc section

When `@invariants` is called after `@contract` on the same type, the contract doc section is refreshed to include both method specs and behavioral invariants. The prior entry under the sentinel signature is deleted first, so no "Replacing docs" warning is emitted.

## Precompiled packages

When a package that uses TypeContracts is precompiled, `@contract` and `@invariants` run at precompile time and populate the registries. The extension is not present at precompile time, so no doc attachment happens then. When a user `using`s the package in an interactive session, the extension loads and retroactively attaches docs for all registered contracts in its `__init__`. The docs are always up-to-date for the entire interactive session.
