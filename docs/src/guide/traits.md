# Trait Dispatch

TypeContracts supports the [Holy Trait](https://docs.julialang.org/en/v1/manual/methods/#Trait-based-dispatch-1) pattern: dispatch on whether a type satisfies an interface contract, without requiring the type to declare anything.

## `interface_trait(I, T)` — the dispatch key

```julia
interface_trait(::Type{I}, ::Type{T}) -> Implemented{I} | NotImplemented{I}
```

Returns `Implemented{I}()` if `T` satisfies all mandatory methods of the contract registered for `I`, or `NotImplemented{I}()` otherwise. Only method existence (`hasmethod`) is checked — return type inference is **not** run, making this function safe for runtime use in juliac-compiled binaries.

```julia
abstract type AbstractShape end

@contract AbstractShape begin
    area(::Self)      :: Float64
    perimeter(::Self) :: Float64
end

struct Circle <: AbstractShape; r::Float64 end
area(c::Circle)::Float64      = π * c.r^2
perimeter(c::Circle)::Float64 = 2π * c.r

interface_trait(AbstractShape, Circle)   # Implemented{AbstractShape}()
interface_trait(AbstractShape, Int)      # NotImplemented{AbstractShape}()
```

## Dispatch pattern

Define two internal methods — one for each trait singleton — and a public entry point that calls `interface_trait` to select between them:

```julia
_render(::Implemented{AbstractShape}, x)    = "Shape[area=$(round(area(x); digits=2))]"
_render(::NotImplemented{AbstractShape}, x) = "not a shape: $(typeof(x))"

render(x) = _render(interface_trait(AbstractShape, typeof(x)), x)
```

```julia
render(Circle(3.0))   # "Shape[area=28.27]"
render(42)            # "not a shape: Int64"
render("hello")       # "not a shape: String"
```

This pattern is zero-overhead at runtime: Julia specialises `_render` on the singleton type, and the dispatch is resolved statically when the type of `x` is known at compile time.

## `Implemented{I}` and `NotImplemented{I}`

These are plain singleton structs with no fields:

```julia
struct Implemented{I} end
struct NotImplemented{I} end
```

They are exported by TypeContracts and can be used as type parameters, method argument types, or anywhere else a type is expected.

## juliac / trim compatibility

`interface_trait` is the only TypeContracts function designed to be called at runtime
inside a `juliac --trim` compiled binary. Understanding why requires understanding what
trim does and what makes a function trim-safe.

### What `juliac --trim` does

`juliac --trim` (also called ahead-of-time compilation or AOT) compiles Julia to a
native binary by performing dead-code elimination starting from one or more declared
entry points. Everything not reachable from those entry points is stripped. The result
has **no Julia runtime** — no JIT compiler, no type inferencer, and no `Base.return_types`.
Functions that depend on those facilities cannot work in a trimmed binary.

### Why `interface_trait` is trim-safe: two interlocking reasons

**Reason 1 — it only uses `hasmethod`.**
The check inside `interface_trait` is purely "does this method exist in the method
table?" (`hasmethod(f, Tuple{T, arg_types...})`). `hasmethod` is a simple lookup —
no inference, no JIT. It is available in trimmed binaries.

**Reason 2 — it is a `@generated` function that bakes in concrete types.**
`@generated` functions run their *body* at *specialisation time* — once per unique
`(I, T)` type pair, during normal Julia compilation, not at the runtime you ship.
The generated code is a fixed expression:

```julia
# What the @generated body emits for interface_trait(AbstractShape, Circle):
hasmethod(area, Tuple{Circle}) && hasmethod(perimeter, Tuple{Circle}) ?
    Implemented{AbstractShape}() : NotImplemented{AbstractShape}()
```

Both `area`, `Circle`, and `perimeter` are **concrete values baked in at generation
time**. There is no stored abstract `Function` value, no runtime registry lookup, no
dynamic signature construction. From the perspective of the trimmer, this is just a
pair of concrete `hasmethod` calls — statically resolvable.

### The `_registry` dict and world age

There is a subtle constraint that explains why TypeContracts uses *two* registries —
a mutable dict `_registry` for `interface_trait`, and dispatch-based `_contract_specs`
methods for everything else.

`@generated` bodies run in a **fixed world age** — the world age at the time the
`@generated` function was first specialised for a given type pair. They cannot see
methods added to `_contract_specs` *after* that world age, because those methods
did not exist when the body was generated. A plain method dispatch inside a
`@generated` body would silently return the wrong answer for contracts registered
later.

A mutable dict has no world-age constraint — dict reads are always current. So
`_registry` is the correct data structure for `interface_trait` to read during code
generation: when `@contract` fires it writes to `_registry` unconditionally, and the
`@generated` body reads `_registry` at specialisation time and emits concrete
`hasmethod` expressions for whatever it finds there.

Every other TypeContracts function — `check_contract`, `satisfies`, `describe`,
`list_contract` — uses `_contract_specs` (the dispatch-based registry) because they
run at normal world ages where method dispatch works correctly. They never touch
`_registry` directly.

### Why other functions are not trim-safe

**`check_contract`, `satisfies`, `implements`** all call `Base.return_types`.
Return type checking requires Julia's type inferencer, which is part of the Julia
runtime and is **not available in a trimmed binary**. These functions are designed
for precompile time and test time, not for runtime use in a static binary.

**`@verify`, `@verify_all`** run at module load/precompile time by design. They also
call `Base.return_types`. They will never appear in a user's runtime call path.

**`describe`, `list_contract`, `contract_md_string`** do not call `Base.return_types`,
so they are technically trim-compatible in isolation. However, they are introspection
and documentation tools. There is no sensible reason to call them at runtime in a
static binary — they exist for development-time exploration and documentation
generation. Treat them as precompile-time tools.

**`contract_md`** requires the `Documenter` extension, which is never loaded in a
juliac binary. Without the extension it returns `nothing` via a no-op dispatch hook.

### What to call at runtime in a trimmed binary

The answer is: **only `interface_trait`**, plus your own dispatch methods that branch
on `Implemented{I}` / `NotImplemented{I}`.

| Function | Trim-safe? | When to use |
|---|---|---|
| `interface_trait` | ✓ Yes | Runtime dispatch in trimmed binary |
| `@verify`, `@verify_all` | — precompile only | Module load / `__init__` |
| `check_contract` | ✗ No (`Base.return_types`) | Test time |
| `satisfies` | ✗ No (`Base.return_types`) | Test time |
| `implements` | ✗ No (`Base.return_types`) | Test time |
| `describe` | — doc tool | REPL / development |
| `list_contract` | — doc tool | REPL / development |
| `contract_md_string` | — doc tool | Documenter `@eval` blocks |
| `test_behavior` | — test tool | Behavioral test suites |

### Checking your implementations with `@verify`

`@verify T trim_compat=true` runs `check_trim_compat(T)` immediately after the
normal `check_contract` pass. For each mandatory contract method it:

1. Calls `Base.code_typed(f, concrete_sig; optimize=false)` to get the typed IR
2. Walks the IR statements looking for calls to known trim-unsafe functions:
   `Base.return_types`, `Base.invokelatest`, `Base.which`, `Base.methods`
3. Emits `@warn` for any found — does not throw, since trim-safety is advisory

This is a **shallow scan**: it inspects only the top-level method body, not callees.
For exhaustive verification use `TrimCheck.@validate`.

```julia
@verify Circle trim_compat=true   # warns if area(::Circle) calls return_types etc.
@verify_all trim_compat=true      # applies the check to every verified type

# Standalone check
result = check_trim_compat(Circle)
result.passed     # true if no issues found
result.issues     # Dict{Type, Vector{String}} — issues grouped by contract type
```

`check_trim_compat` itself has zero runtime overhead: it runs at module load time
(same as `@verify`) and emits no code into the precompiled image.

### No manual opt-out needed

The documentation and doc-attachment machinery lives entirely in package extensions:

- `TypeContractsREPLExt` loads only when `REPL` is present. `REPL` is not present in
  juliac-compiled binaries, so `Markdown` and `Base.Docs` are never pulled in.
- `TypeContractsDocumenterExt` loads only when `Documenter` is present, which is
  likewise absent from juliac binaries.

Both extensions use the same dispatch-hook pattern as `_attach_contract_doc`: the hook
resolves statically to a no-op in the trimmed context. No REPL, no Markdown, no Docs
code enters the binary.

### Registering contracts in a trimmed binary

Register contracts in your module body or `__init__`, then call `interface_trait`
at runtime:

```julia
module MyLib
using TypeContracts

abstract type AbstractShape end
function area end

@contract AbstractShape begin
    area(::Self) :: Float64
end

# --- Runtime use: only interface_trait --------------------------------
_draw(::Implemented{AbstractShape},    x) = "drawing shape, area=$(area(x))"
_draw(::NotImplemented{AbstractShape}, x) = error("$(typeof(x)) is not a shape")

draw(x) = _draw(interface_trait(AbstractShape, typeof(x)), x)

end # module
```

`@contract` writes to `_registry` at module load time (before any `@generated`
specialisation). By the time `draw(x)` is first called with a concrete type,
`interface_trait` specialises, reads `_registry`, bakes in the concrete `hasmethod`
checks, and the result is a static dispatch — exactly what the trimmer needs.

## Checking multiple interfaces

`interface_trait` checks a single interface at a time. For types that need to satisfy multiple interfaces, compose the traits:

```julia
abstract type Printable end
abstract type Serializable end

@contract Printable begin
    Base.show(::IO, ::Self)
end

@contract Serializable begin
    serialize(::Self) :: Vector{UInt8}
end

function process(x)
    pt = interface_trait(Printable, typeof(x))
    st = interface_trait(Serializable, typeof(x))
    _process(pt, st, x)
end

_process(::Implemented{Printable}, ::Implemented{Serializable}, x) = ...
_process(::Implemented{Printable}, ::NotImplemented{Serializable}, x) = ...
_process(::NotImplemented{Printable}, ::Any, x) = error("type must be Printable")
```
