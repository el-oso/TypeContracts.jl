# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.14.2] - 2026-10-17

### Fixed

- The `_verify_hook` fallback is now `_verify_hook(::Any, ::Any, ::Any, ::Any)`. It had the
  same signature as the generic method the API reference tells packages to write,
  `_verify_hook(::_VerifyHook, ::Module, ::Type, ::Any)`, so a package that followed the
  reference replaced the fallback, which is an error during precompilation.
- `@verify_all`, `@verify T subtypes=true` and the Revise re-check check a bare parametric
  name only for missing methods. They no longer infer its return types with the type
  parameters set to `Any`, which reported false mismatches (`return Any ⊄ Int64` for
  `f(w::Wr) = w.x` against `f(::Self)::Int`, even when `Wr{Int}` satisfies the contract).
  Return types are checked on the concrete instances given to `@verify`.
- `@verify_all` and `contract_signatures` no longer throw a `MethodError` on a module that
  defines a parametric `Union` alias (`const U{T} = Union{A{T}, B{T}}`).
- `@verify T subtypes=true` warns "no concrete subtypes found" only when `T` has no
  subtypes to check, not when every subtype is a parametric type that was skipped. Each
  skipped type already gets its own warning, which an `@verify` of an instance silences.

### Changed

- The behavioral guide and the `test_behavior` docstring state that invariants describe
  single values, because each predicate receives a `deepcopy`. A type that owns a raw
  resource should make `Base.deepcopy_internal` throw, which `test_behavior` reports as a
  failed invariant; lifetime and timing properties belong in ordinary tests.

## [0.14.1] - 2026-10-17

### Added

- `contract_signatures(mod; optional = false)` — for each concrete contract type in
  `mod`, lists every contract method as `(f, sig, return_type, T, contract, mandatory)`,
  with `Self` and type parameters resolved exactly as `check_contract` resolves them.
  Dev/precompile-time only.
- Verification hook `TypeContracts._verify_hook(::_VerifyHook, mod, T, result)`. It is
  called once per type by `@verify`, `@verify_all`, `@verify T subtypes=true` and
  `@delegate`, after the contract check passes and before `verified_trait` is sealed. A
  throwing hook fails the verification. See "Extension hooks" in the API reference.
- "One method per subtype of another type" section in the contracts guide.

### Fixed

- `@verify_all`, `@verify T subtypes=true` and the Revise re-check no longer treat a bare
  parametric name (`Bucket` for `struct Bucket{T}`) as a concrete type. Such a type was
  checked with its type parameters resolved to `Any`, so declared return types went
  unchecked, and `verified_trait` was sealed on the `UnionAll` rather than on any instance.
  Such a type is still checked for missing methods (a missing method throws
  `InterfaceError`, as before), but it is no longer sealed, and a warning names the fix
  (`@verify Bucket{Int}`). The warning is not emitted once an instance has been verified,
  including a parametric wrapper sealed by `@delegate`. The example instance respects the
  parameter's bounds (`Fl{Float64}` for `Fl{T<:AbstractFloat}`).
- A bare parametric name with a bounded parameter (`struct Fl{T<:AbstractFloat} <: A{T}`)
  was not recognized as carrying `A`'s contract, so `@verify_all` ignored it silently.
- `@verify_all` no longer throws a `MethodError` when the module binds a `Union` alias,
  and a type bound under two names is checked and reported once.
- The Revise re-check warns on every exception. Exceptions other than `InterfaceError`
  were previously discarded without a message.

### Changed

- The test suite runs on TestItemRunner instead of ReTestItems.

## [0.14.0] - 2026-07-11

### Added

- `verified_trait(::Type{I}, ::Type{T})` — a second trait-dispatch function alongside
  `interface_trait`. Where `interface_trait` checks method *existence* only,
  `verified_trait` reflects the full `check_contract` result (existence **and**
  declared return types) at the moment verification succeeded. `@verify`, `@verify_all`,
  and `@delegate` now seal a concrete `verified_trait(::Type{I}, ::Type{T}) =
  Implemented{I}()` method after a successful check — sealing is automatic, no new
  keyword needed. Unverified `(I, T)` pairs fall through to `NotImplemented{I}()`.
  Same zero-allocation, `juliac --trim`-safe shape as `interface_trait`; see the new
  "Verified traits" section in `docs/src/guide/traits.md` for the full guarantee and
  its opt-in / Revise-staleness caveats.
- `docs/src/examples/julia-rust-go.md` Section 9 ("Interface-Gated Methods") now
  documents `verified_trait` as closing the return-type-checking gap against Rust for
  `@verify`'d types, including why `Base.return_types` cannot simply be called from
  inside `interface_trait`'s `@generated` generator (Julia disallows reflection there).

### Fixed

- `::Self` in return-type position (e.g. `clone(::Self) :: Self`) now resolves against the
  concrete implementing type at check time. Previously it was silently unresolved and any
  contract using it failed `check_contract`/`satisfies`/`@verify` for every implementer.
- `test_behavior(T, S, objects)` (the 2-argument form) now normalizes a parametric `S` through
  `_registry_key`, matching the 1-argument form. Previously passing e.g. `AbstractBucket{Int}`
  silently found no registered invariants.

### Changed

- `@contract`/`@invariants` now emit `@warn` when re-registering over an existing contract or
  invariant set for the same type, instead of silently overwriting it. This surfaces the
  cross-package coherence gap (no orphan-rule equivalent) at the point of overwrite.
- Deduplicated the repeated `hasmethod`/`Base.return_types` checking logic in `check_contract`
  and `satisfies` into shared internal helpers (`_check_spec`, `_warn_if_more_specific`,
  `_inferred_return_type`) in `src/check.jl`. No behavior change.

### Documentation

- Corrected two examples in the "Julia + TypeContracts vs Rust vs Go" guide
  (`docs/src/examples/julia-rust-go.md`) that were verified to be factually broken against the
  current implementation, and removed two examples that re-registered a contract/invariant set
  already provided by `BaseTypeContracts`, which triggered the exact coherence gap the guide was
  arguing TC avoids.
- Softened several overstated verdicts (`interface_trait` is existence-only, not a return-type
  check; `check_trim_compat` is a shallow heuristic, not a proof; Go generic constraints can gate
  on method sets, not just type unions) and added a "contract coherence" discussion to the
  Key Differences section.

## [0.13.0] - prior release

See git history for changes prior to this changelog's introduction.
