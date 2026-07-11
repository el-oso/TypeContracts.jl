# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
