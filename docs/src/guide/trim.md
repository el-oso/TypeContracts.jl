# Trim Compatibility

`juliac --trim` compiles Julia to a native binary by stripping everything not reachable
from declared entry points. The result has **no Julia runtime** — no JIT, no type
inferencer, no `Base.return_types`. This page explains what TypeContracts functions are
safe to call in a trimmed binary, and the tools available to catch problems early.

## What `juliac --trim` does

Starting from declared entry points, `juliac --trim` performs dead-code elimination and
rejects any call that is not statically resolvable — every argument type must be concrete
so the compiler knows exactly which method to dispatch to. A call that infers to `Any`
("dynamic dispatch") is rejected with a verifier error.

## `interface_trait` is the only runtime-safe function

`interface_trait(I, T)` is the only TypeContracts function designed to be called at
runtime in a trimmed binary. Two interlocking properties make it trim-safe:

**Reason 1 — it only uses `hasmethod`.**
The check inside `interface_trait` is purely `hasmethod(f, Tuple{ConcretType, ...})`.
`hasmethod` is a method-table lookup — no inference, no JIT — and is available in trimmed
binaries.

**Reason 2 — `@contract` bakes concrete types into a `@generated` method.**
`@contract I` emits a per-interface `@generated` method
`interface_trait(::Type{I}, ::Type{T}) where {T}`. Its generator runs once per `(I, T)`
pair at *specialization time* (ordinary Julia compilation), not at binary runtime. The
emitted body is a fixed conjunction of concrete `hasmethod` calls:

```julia
# What the @generated method emits for interface_trait(AbstractShape, Circle):
hasmethod(area, Tuple{Circle}) && hasmethod(perimeter, Tuple{Circle}) ?
    Implemented{AbstractShape}() : NotImplemented{AbstractShape}()
```

`area`, `Circle`, and `perimeter` are concrete values baked in at generation time. For
parametric contracts, `Self` and type parameters resolve against the concrete type during
generation, so the result is equally concrete. From the trimmer's perspective this is just
a conjunction of concrete `hasmethod` calls — statically resolvable.

## `@verify` at module top level is safe

`@verify` and `@verify_all` placed at **module top level** are safe in juliac binaries.
They run during Julia's precompilation step — before the native binary is produced — and
are not re-executed at binary runtime. The trimmer eliminates them because they are
unreachable from any declared entry point.

The only unsafe pattern is calling `@verify` or `check_contract` **inside a function
that runs at binary runtime** (e.g. an entry point or inside `__init__`). That embeds
`Base.return_types` in the runtime call graph. Use `@verify` at module top level only.

## Functions that cannot be called at runtime in a trimmed binary

| Function | Trim-safe at runtime? | Notes |
|---|---|---|
| `interface_trait` | ✓ Yes | Designed for runtime dispatch in trimmed binaries |
| `@verify`, `@verify_all` | ✓ Yes (module top level) | Eliminated by trimmer; safe to leave in |
| `check_contract` | ✗ No | Uses `Base.return_types` — test time only |
| `satisfies` | ✗ No | Uses `Base.return_types` — test time only |
| `implements` | ✗ No | Uses `Base.return_types` — test time only |
| `describe` | — | REPL / development tool |
| `list_contract` | — | REPL / development tool |
| `contract_md_string` | — | Documenter `@eval` blocks |
| `test_behavior` | — | Behavioral test suites |

## Method-based registration and world age

All contract state lives in **method definitions**, never a mutable global. `@contract I`
emits the `@generated` `interface_trait(::Type{I}, …)` method above plus a
`_contract_specs(::Type{I})` method used by the dev-time tools.

This matters for two reasons:

1. **Precompilation survival.** Method definitions are serialized into the registering
   package's precompile cache. A package that declares contracts works from a cold,
   precompiled load with **no `__init__` or re-registration step**. (A mutable dict
   would be reset if TypeContracts were invalidated and reloaded, silently breaking
   dependent packages — which is exactly the failure mode this design avoids.)

2. **World age.** `@generated` bodies run in a **fixed world age**. A single global
   `interface_trait` could not see `_contract_specs` methods registered later by other
   packages. TypeContracts avoids this by emitting *one `@generated` method per
   interface*, in the same package that declares the contract, immediately after that
   interface's `_contract_specs`. Each generator only needs its own baked-in data plus
   `_build_sig` from TypeContracts — no cross-package lookup, no world-age hazard.

## Extensions load only when needed

The REPL and Documenter extensions are never loaded in a trimmed binary:

- `TypeContractsREPLExt` triggers on `REPL`, which is absent in juliac binaries.
- `TypeContractsDocumenterExt` triggers on `Documenter`, likewise absent.

Both use a dispatch-hook pattern that resolves to a no-op when the extension is not
loaded. No `Markdown`, `Base.Docs`, or REPL code enters the binary — without any manual
opt-out.

## `check_trim_compat` — check your implementations

`@verify T trim_compat=true` runs `check_trim_compat(T)` immediately after the normal
`check_contract` pass. For each mandatory contract method it:

1. Calls `Base.code_typed(f, concrete_sig; optimize=true)` to get the typed IR
2. Scans statements looking for calls to trim-unsafe functions (`Base.return_types`,
   `Base.invokelatest`, `Base.which`, `Base.methods`) in both `:call` (dynamic dispatch)
   and `:invoke` (static call) forms
3. Emits `@warn` for any found — does not throw, since trim-safety is advisory

The warning names the offending method and labels the IR pattern:

```
⚠ Trim-compatibility issues in MyImpl (contract AbstractFoo):
  foo(::Self) :: Float64: static call to Base.return_types (trim-unsafe)
```

```julia
@verify Circle trim_compat=true   # warns if area(::Circle) calls return_types etc.
@verify_all trim_compat=true      # applies to every verified type in the module

# Standalone check
result = check_trim_compat(Circle)
result.passed   # true if no issues found
result.issues   # Dict{Type, Vector{String}} — issues grouped by contract type
```

This is a **shallow scan**: it inspects only the top-level method body, not callees.
For exhaustive verification use `TrimCheck.@validate`.

## Proactive scan: `trim_report`

`trim_report(f, sig)` scans the optimized, type-inferred IR of a single function for
patterns `juliac --trim=safe` rejects — dynamic dispatch (a call whose result infers to
`Any`) and known reflection callees. It returns a `TrimReport` you can inspect or throw:

```julia
using TypeContracts: trim_report

f(x::Int64) = x + 1                              # clean
report = trim_report(f, Tuple{Int64})
report.passed    # true
report.findings  # String[] — empty

g(n::Int64) = Base.inferencebarrier(n) + 1        # dynamic dispatch
report = trim_report(g, Tuple{Int64})
report.passed    # false
report.findings  # ["dynamic dispatch (result inferred as `Any`): …"]

showerror(stdout, report)
# TrimReport: g(Int64) has 1 likely trim-unsafe site(s) …
#   ✗ dynamic dispatch (result inferred as `Any`): …
#   → make these calls statically resolvable …
```

`trim_report` inspects one function's IR after inlining, so many transitive issues
surface without recursing manually. It is a **fast, advisory** check — juliac's
whole-program verifier remains authoritative.

## Reactive translation: `TrimDiagnostics.explain_trim_failure`

When a `juliac --trim=safe` run fails, its raw output is a dump of numbered "Verifier
error" blocks — the same root cause repeated several times with full stack traces and no
source mapping. `TrimDiagnostics.explain_trim_failure` turns that into a concise,
source-mapped `TrimFailure`:

```julia
using TypeContracts: explain_trim_failure, TrimFailure

# captured = the raw string output from the failed juliac invocation
failure = explain_trim_failure(captured;
    entry_path   = "/path/to/_generated_entry.jl",  # filter generated wrapper frames
    source_files = ["/path/to/user_source.jl"],      # prioritize user-code frames
)
showerror(stdout, failure)
```

**Example output** for a function with one dynamic-dispatch site:

```
TrimFailure: juliac --trim=safe rejected 1 call site (4 verifier errors) — these calls are not statically resolvable.

  ✗ dyn(n::Int64)  user_source.jl:6  (4 errors)
      unresolved: (Base.compilerbarrier(:type, n::Int64)::Any + 1)::Any
      → a value inferred as `Any` makes this call dynamic — annotate or narrow
        the type (e.g. `x::Concrete`, a type assertion, or avoid abstract
        containers) so the call is statically resolvable.

  (rebuild with verbose=true / keep_build=true for raw juliac output.)
```

Key properties:

- Multiple raw verifier errors for the **same source line** collapse into one site, with
  a count.
- Generated wrapper frames (`_pt_entry.jl`, etc.) are filtered out; only user-source
  frames appear.
- If the output format is not recognized (e.g. a future juliac version), the function
  degrades gracefully: `failure.recognized == false`, and `showerror` prints the raw
  output so no information is hidden.

`TrimDiagnostics` is a self-contained submodule — no other TypeContracts module depends
on it — so it can be extracted into a standalone package later without breaking anything.

## Full example: trimmed binary with trait dispatch

```julia
module MyLib
using TypeContracts

abstract type AbstractShape end
function area end

@contract AbstractShape begin
    area(::Self) :: Float64
end

# Verify implementations at precompile time (trimmer eliminates @verify)
struct Circle <: AbstractShape; r::Float64 end
area(c::Circle)::Float64 = π * c.r^2
@verify Circle

# Runtime dispatch — the only TypeContracts function in the hot path
_draw(::Implemented{AbstractShape},    x) = "drawing shape, area=$(area(x))"
_draw(::NotImplemented{AbstractShape}, x) = error("$(typeof(x)) is not a shape")

draw(x) = _draw(interface_trait(AbstractShape, typeof(x)), x)

end # module
```

`@contract` emits the per-interface `interface_trait` method at module load time. By the
time `draw(x)` is first called with a concrete type, the `@generated` body specializes,
bakes in the concrete `hasmethod` checks, and the dispatch is static — exactly what the
trimmer needs.
