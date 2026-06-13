# Revise Integration

TypeContracts ships a weak-dependency extension for [Revise.jl](https://github.com/timholy/Revise.jl). When both packages are loaded in an interactive session, contract conformance is re-checked automatically after each revision cycle — so a violation introduced by editing a method shows up immediately as a warning, without having to restart Julia or re-run `@verify` manually.

## Activation

No configuration is required. Loading both packages is sufficient:

```julia
using Revise        # must come first so the extension loads
using TypeContracts
```

Or in any order that results in both being in scope — for example, inside a `startup.jl` that always loads Revise, followed by `using TypeContracts` in your project.

The extension is a weak dependency: if Revise is not loaded, TypeContracts behaves exactly as without it. No code changes are needed to make a package Revise-compatible.

## What gets re-checked

After each revision cycle the extension re-checks every type and module that was registered during precompile time:

| Registration | What is re-checked |
|---|---|
| `@verify T` | `T` itself |
| `@verify_all` | all concrete subtypes of registered contract types defined in the calling module |

A warning (not an error) is emitted for each violation so the REPL session stays alive:

```
┌ Warning: Contract violation detected by Revise
│   type = Circle
│   msg = Type Circle does not satisfy interface contract.
│   Missing or incorrect methods:
│     area(::Self) :: Float64 — return String ⊄ Float64  [required by AbstractShape]
└ @ TypeContracts ...
```

## Example

```julia
# file: shapes.jl
module Shapes
using TypeContracts

abstract type AbstractShape end
function area end

@contract AbstractShape begin
    area(::Self) :: Float64
end

struct Circle <: AbstractShape
    radius::Float64
end

area(c::Circle)::Float64 = π * c.radius^2

@verify Circle

end
```

In a REPL session:

```julia
julia> using Revise, TypeContracts
julia> includet("shapes.jl")   # Revise tracks the file
```

Now edit `shapes.jl` to break the contract — for example change `area` to return a `String`:

```julia
area(c::Circle) = "oops"
```

On the next REPL interaction, Revise picks up the change and the extension fires:

```
┌ Warning: Contract violation detected by Revise
│   type = Shapes.Circle
│   msg = Type Circle does not satisfy interface contract.
│   ...
└ @ TypeContracts ...
```

Fix the method, and the warning disappears on the next revision cycle.

## Notes

- The check fires on **any** file change tracked by Revise, not only changes to the files that define the checked types. This is intentional: a method added elsewhere could satisfy or break a contract.
- Types that appear in both `@verify T` and a `@verify_all` module are checked twice — once for each registration. This is harmless.
- The extension uses `Revise.add_callback` with `all=true`. The callback is registered in the extension's `__init__` and runs asynchronously via `Base.invokelatest` after each revision cycle, so it cannot block the REPL or crash the session.
