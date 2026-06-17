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

This pattern is zero-overhead at runtime: Julia specializes `_render` on the singleton type, and the dispatch is resolved statically when the type of `x` is known at compile time.

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

**Reason 2 — it is a `@generated` method that bakes in concrete types.**
`@contract I` emits a per-interface `@generated` method
`interface_trait(::Type{I}, ::Type{T}) where {T}`. `@generated` methods run their
*body* at *specialization time* — once per unique `(I, T)` type pair, during normal
Julia compilation, not at the runtime you ship. The generated code is a fixed expression:

```julia
# What the @generated method emits for interface_trait(AbstractShape, Circle):
hasmethod(area, Tuple{Circle}) && hasmethod(perimeter, Tuple{Circle}) ?
    Implemented{AbstractShape}() : NotImplemented{AbstractShape}()
```

`area`, `Circle`, and `perimeter` are **concrete values baked in at generation
time**. There is no stored abstract `Function` value, no runtime registry lookup, no
dynamic signature construction. For parametric contracts, `Self` and the contract's
type parameters are resolved against the concrete type during generation too, so the
emitted body is equally concrete. From the perspective of the trimmer, this is just a
conjunction of concrete `hasmethod` calls — statically resolvable.

### Method-based registration and world age

All contract state lives in **method definitions**, never a mutable global. `@contract I`
emits the `@generated` `interface_trait(::Type{I}, …)` method above, plus a
`_contract_specs(::Type{I})` method used by the dev-time tools (`check_contract`,
`satisfies`, `describe`, `list_contract`).

This matters for two reasons:

1. **Precompilation survival.** Method definitions are serialized into the registering
   package's precompile cache. A package that declares contracts works from a cold,
   precompiled load with **no `__init__` or re-registration step**. (A mutable dict
   would be reset if TypeContracts were invalidated and reloaded, silently breaking
   dependent packages — which is exactly the failure mode this design avoids.)

2. **World age.** `@generated` bodies run in a **fixed world age**. A *single global*
   `interface_trait` could not dispatch to `_contract_specs` methods registered later by
   other packages — they would be invisible to its generator. TypeContracts sidesteps
   this entirely by emitting *one `@generated` method per interface*, in the same package
   that declares the contract, immediately after that interface's `_contract_specs`. Each
   generator only ever needs its own baked-in method data (plus `_build_sig` from
   TypeContracts), so there is no cross-package lookup and no world-age hazard.

### `@verify` and juliac binaries

`@verify` and `@verify_all` at **module top level** are safe in a juliac binary.
They run during Julia's precompilation step — before the native binary is produced —
and are not re-executed at binary runtime. The trimmer automatically eliminates them
because they are unreachable from any declared entry point.

The only unsafe pattern is calling `@verify` or `check_contract` **inside a function
that runs at binary runtime** (e.g. an entry point, or inside `__init__`). That would
embed `Base.return_types` in the runtime call graph. Use `@verify` at module top level
only, which is the normal way to use it.

### Why some functions cannot be called at runtime in a trimmed binary

**`check_contract`, `satisfies`, `implements`** call `Base.return_types`, which
requires Julia's type inferencer — not available in a trimmed binary. These are test
and precompile-time tools only. Do not call them from functions that run at binary
runtime.

**`describe`, `list_contract`, `contract_md_string`** do not call `Base.return_types`
so they are trim-compatible in isolation, but they are development and documentation
tools. There is no sensible reason to call them at runtime in a static binary.

**`contract_md`** requires the `Documenter` extension, which is never loaded in a
juliac binary. Without the extension it returns `nothing` via a no-op dispatch hook.

### Summary: what to call at runtime in a trimmed binary

The answer is: **only `interface_trait`**, plus your own dispatch methods that branch
on `Implemented{I}` / `NotImplemented{I}`.

| Function | Trim-safe at runtime? | Notes |
|---|---|---|
| `interface_trait` | ✓ Yes | Runtime dispatch in trimmed binary |
| `@verify`, `@verify_all` | ✓ Yes (module top level) | Eliminated by trimmer; safe to leave in |
| `check_contract` | ✗ No (`Base.return_types`) | Test time only |
| `satisfies` | ✗ No (`Base.return_types`) | Test time only |
| `implements` | ✗ No (`Base.return_types`) | Test time only |
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

### Proactive scan: `trim_report`

`trim_report(f, sig)` scans the optimized, type-inferred IR of a single function for the
patterns `juliac --trim=safe` rejects — dynamic dispatch (a call whose result infers to
`Any`) and known reflection callees (`Base.return_types`, `invokelatest`, `which`,
`methods`). It returns a `TrimReport` you can inspect or throw:

```julia
using TypeContracts: trim_report

f(x::Int64) = x + 1                               # clean
report = trim_report(f, Tuple{Int64})
report.passed    # true
report.findings  # String[] — empty

g(n::Int64) = Base.inferencebarrier(n) + 1         # dynamic dispatch
report = trim_report(g, Tuple{Int64})
report.passed    # false
report.findings  # ["dynamic dispatch (result inferred as `Any`): …"]
showerror(stdout, report)
# TrimReport: g(Int64) has 1 likely trim-unsafe site(s) …
#   ✗ dynamic dispatch (result inferred as `Any`): …
#   → make these calls statically resolvable …
```

This is a **fast, advisory** check — it inspects one function's IR (after inlining, so
many transitive issues surface) but does not run juliac's whole-program verifier. Treat
findings as warnings; juliac remains authoritative.

### Reactive translation: `TrimDiagnostics.explain_trim_failure`

When a `juliac --trim=safe` run fails, its raw output is a long dump of numbered
"Verifier error" blocks — the same root cause repeated several times, with full stack
traces, no source mapping to user code. `TrimDiagnostics.explain_trim_failure` turns
that into a concise, source-mapped `TrimFailure`:

```julia
using TypeContracts: explain_trim_failure, TrimFailure

# captured = the raw string output from the failed juliac invocation
failure = explain_trim_failure(captured;
    entry_path  = "/path/to/_generated_entry.jl",   # filter generated frames
    source_files = ["/path/to/user_source.jl"],      # prioritize user frames
)
# failure isa TrimFailure
showerror(stdout, failure)
```

**Example output** for a function with one dynamic-dispatch site:

```
TrimFailure: juliac --trim=safe rejected 1 call site (4 verifier errors) — these calls are not statically resolvable.

  ✗ dyn(n::Int64)  user_source.jl:6  (4 errors)
      unresolved: (Base.compilerbarrier(:type, n::Int64)::Any + 1)::Any
      → a value inferred as `Any` makes this call dynamic — annotate or narrow the type
        (e.g. `x::Concrete`, a type assertion, or avoid abstract containers) so the
        call is statically resolvable.

  (rebuild with verbose=true / keep_build=true for raw juliac output.)
```

Key properties:
- Multiple raw verifier errors for the **same source line** are collapsed into one site.
- Generated wrapper frames (`_pt_entry.jl`, `_mexgen.jl`, …) are filtered out; only user-source frames appear.
- If the output format is not recognized (e.g. a future juliac version), the function degrades gracefully: `failure.recognized == false`, `showerror` prints the raw output so no information is hidden.

**`TrimDiagnostics` is a self-contained submodule** — no other TypeContracts module
depends on it — so it can be split into a standalone package later without breaking
anything. Tools built on juliac (ParselTongue, Mexicah) call it internally; the parsed
`TrimFailure` is what `build_extension`/`build_mex` throw on a trim failure.

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

`@contract` emits the per-interface `interface_trait` method at module load time. By
the time `draw(x)` is first called with a concrete type, that method specializes, its
generator bakes in the concrete `hasmethod` checks, and the result is a static dispatch
— exactly what the trimmer needs. No registry dict, no `__init__` step.

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
