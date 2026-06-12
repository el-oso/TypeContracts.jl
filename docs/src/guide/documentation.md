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

---

## Documenter.jl Integration

TypeContracts also integrates with [Documenter.jl](https://documenter.juliadocs.org) to bring the same contract information into your generated HTML documentation.

### `contract_md_string` — zero-config `@eval` blocks

[`contract_md_string`](@ref) is always available in the TypeContracts core — no extension needed. It returns the contract for `T` as a plain `String` of Markdown. Documenter renders any `String` returned from an `@eval` block as Markdown, so you can inject contract documentation at any point in a page:

````markdown
```@eval
using TypeContracts
TypeContracts.contract_md_string(AbstractShape)
```
````

This is the lightest integration option: no `make.jl` changes, no auto-attachment to `@docs` blocks — just inline content where you want it.

### Automatic `@docs` enhancement

When `using Documenter` is in scope (i.e. in `docs/make.jl`), the `TypeContractsDocumenterExt` extension loads automatically. Its `__init__` attaches a contract section to every registered type's `Base.Docs` entry before `makedocs` runs. Standard `@docs T` blocks in your pages then show the contract section below the type's own docstring — no per-page changes needed.

```julia
# docs/make.jl — extension loads automatically with Documenter
using MyPackage, Documenter
makedocs(...)
```

The mechanism is identical to the REPL extension: the sentinel signature `Tuple{Val{:TypeContractsContract}}` keeps the contract section separate from the type's own docstring. Both coexist without conflict, and `@docs T` shows them together.

### `contract_md` — explicit `Markdown.MD` objects

[`contract_md`](@ref) returns a `Markdown.MD` object (the parsed form, suitable for Documenter's internal pipeline). It is available when the Documenter extension is loaded and returns `nothing` otherwise.

```julia
using TypeContracts, Documenter, Markdown

md = TypeContracts.contract_md(AbstractShape)  # Markdown.MD
```

Most users will not need this directly — `contract_md_string` covers `@eval` use cases and auto-attachment covers `@docs` use cases.

### Example: BaseTypeContracts

[BaseTypeContracts.jl](https://github.com/el-oso/BaseTypeContracts.jl) uses this integration. Its `docs/make.jl` imports `Documenter`, which triggers the extension. Every Base abstract type's contract then appears inline in the generated API reference alongside the type's own documentation.
