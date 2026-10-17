# contract_signatures, verify hook, parametric skip — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship TypeContracts 0.14.1 with `contract_signatures`, the `_verify_hook` dispatch hook, and correct handling of parametric types in the bulk verification paths.

**Architecture:** One shared type-selection function (`_contract_types_in_module`) and one checkability predicate (`_is_checkable`) feed `@verify_all`, `@verify T subtypes=true`, the Revise re-check, and `contract_signatures`. Signature resolution reuses the existing `_build_sig` / `_resolve_rt_spec`. The hook follows the existing `_DocSyncHook` dispatch pattern: an empty struct, a no-op fallback method, and one call per verified type.

**Tech Stack:** Julia ≥ 1.12, TestItemRunner (`@testitem`, `@testmodule TCFixtures`), Runic.

**Spec:** `docs/superpowers/specs/2026-10-17-contract-signatures-verify-hook-design.md`

**Already done (spec part D):** the Revise re-check warns on every exception (commit `14195f8`, test `test/revise_check_test.jl`).

## Global Constraints

- Release is **0.14.1**. Every change is non-breaking: no change to `@contract`, `@verify`, `@verify_all` or `@delegate` syntax.
- TypeContracts gets no StrictMode dependency of any kind, and no performance analysis.
- No new mutable global state. The hook is dispatch-based. Silencing reads `methods(verified_trait)`.
- `interface_trait` and `verified_trait` remain the only trim-safe entry points (`test/trim_test.jl` must stay green, unchanged).
- Comments and docstrings state what the code does now. No history, no plan references.
- Run `runic -i .` before every commit.
- Iterate with `julia_run_testitems` (`name_pattern` / `file_pattern`). The gate is `julia --project=. -e 'using Pkg; Pkg.test()'`, run in Task 4 only.

## Review Focus

1. **A type parameter fixed by the subtype**, e.g. `struct IntBucket <: AbstractBucket{Int}`. It is concrete and must still be checked, not skipped. Test in Task 1.
2. **A parametric type with several parameters**, e.g. `Pair2{A,B}`. The example in the warning must read `@verify Pair2{Int, Int}`. Test in Task 1.
3. **A verified instance under `for_contract=`.** Sealing only one contract still counts as verified and silences the warning. Test in Task 1.
4. **`contract_signatures` on a module with no contract types** returns an empty vector and does not throw. Test in Task 2.
5. **A hook that throws in `@verify_all` on the second of two types.** The exception propagates, the first type stays sealed, and the second type is not sealed. Test in Task 3.

---

### Task 1: Parametric types are skipped, not falsely verified (spec C)

**Files:**
- Modify: `src/check.jl` (`_verify_subtypes`, `_revise_check_module`; add helpers next to `_concrete_subtypes`)
- Modify: `src/macros.jl` (`_verify_all_in_module`)
- Create: `test/parametric_skip_test.jl`
- Modify: `docs/src/guide/verification.md` (new subsection "Parametric types")

**Interfaces:**
- Produces:
  - `_is_checkable(T::Type, context::Union{String,Nothing}) -> Bool`. Returns `isconcretetype(T)`. When it returns `false`, `context !== nothing`, and `!_has_verified_instance(T)`, it emits the warning below.
  - `_has_verified_instance(T::Type) -> Bool`
  - `_contract_types_in_module(mod::Module, context::Union{String,Nothing}) -> Vector{Type}`. Selects names bound in `mod` that are `Type`s, not abstract, with `parentmodule(T) === mod` and a contract-carrying supertype; then filters with `_is_checkable(T, context)` and drops duplicates.
- `_verify_all_in_module` uses `_contract_types_in_module(mod, "@verify_all")`. `_revise_check_module` uses `_contract_types_in_module(mod, nothing)`. `_verify_subtypes(T, mod)` filters `_concrete_subtypes(T)` with `_is_checkable(S, "@verify $T subtypes=true")`. The `"no concrete subtypes found"` warning still fires when the filtered list is empty.

`_has_verified_instance(T)`: let `name = Base.unwrap_unionall(T).name`. Return true if some `m in methods(verified_trait)` has `p = Base.unwrap_unionall(m.sig).parameters[3]` with `p <: Type`, `X = p.parameters[1]`, `X isa DataType`, `isconcretetype(X)`, and `X.name === name`.

Warning, emitted with `@warn msg type = T contract = C`, where `C` is the registry key of the first contract-carrying supertype of `T`, `name = Base.unwrap_unionall(T).name.name`, `n = length(Base.unwrap_unionall(T).parameters)`, and `ex = "$name{" * join(fill("Int", n), ", ") * "}"`. The text is exactly:

```
$context skipped $name: it is parametric, and its contract can only be
checked for concrete parameters.
To check it, add `@verify` for each instance your code uses, before `@verify_all`:
    @verify $ex
Any verified instance also silences this warning. If the contract does not depend
on the parameter, one representative instance is enough.
```

(The spec shows a second example line, `@verify Bucket{Float64}`. It is dropped here because a second instance can't be generated in general. **Ask the user before executing this task** whether one example line is acceptable.)

- [ ] **Step 1: Write the failing tests** in `test/parametric_skip_test.jl`, as `@testitem "Parametric types in bulk verification"`. Each case defines its own module with `@eval module … end`, the same way `verify_all_test.jl` does:
  - `Bad{T} <: AbstractBucketP{T}` with `get1(::Bad) = "nope"` under the contract `get1(::Self)::T`. `@test_logs (:warn, r"@verify_all skipped Bad") @verify_all` passes; `verified_trait(AbstractBucketP, Bad)` and `verified_trait(AbstractBucketP, Bad{Int})` are both `NotImplemented`; the result's `types` does not contain `Bad`.
  - The same module with `@verify Good{Int}` before `@verify_all` (where `get1(g::Good) = g.x`): `@test_logs @verify_all` captures no logs, and `verified_trait(AbstractBucketP, Good{Int}) === Implemented{AbstractBucketP}()`.
  - Review Focus 1: `IntBucket <: AbstractBucketP{Int}` with `get1(::IntBucket) = "x"` makes `@verify_all` throw an `InterfaceError` matching `"String ⊄ Int64"`.
  - Review Focus 2: `Pair2{A,B} <: AbstractBucketP{A}` produces a warning matching `r"@verify Pair2\{Int, Int\}"`.
  - Review Focus 3: `@verify Good3{Int} for_contract=AbstractBucketP` before `@verify_all` means no warning.
  - `@verify AbstractBucketP subtypes=true` on a module containing only `Bad{T}` warns matching `r"@verify .*AbstractBucketP subtypes=true skipped Bad"`, plus the existing `"no concrete subtypes found"` warning.
  - `TypeContracts._revise_check_module(mod)` on the `Bad` module emits no logs (`@test_logs`).

- [ ] **Step 2: Run them and confirm they fail.** `julia_run_testitems` with `name_pattern = "Parametric types in bulk"`. Expected: FAIL, because no warning is emitted and the `IntBucket`/`Bad` assertions on `verified_trait` don't hold for `Bad`.

- [ ] **Step 3: Implement** `_is_checkable`, `_has_verified_instance` and `_contract_types_in_module` in `src/check.jl`, and route the three callers through them as described in Interfaces.

- [ ] **Step 4: Run the new item plus the existing `@verify_all`, `Parametric contracts` and `verified_trait` items.** Expected: all PASS.

- [ ] **Step 5: Document.** In `docs/src/guide/verification.md`, add a "Parametric types" subsection under `@verify_all`. It covers why a bare parametric name is skipped, the warning text, and the fix (`@verify Bucket{Int}` before `@verify_all`, plus the rule that any verified instance silences the warning).

- [ ] **Step 6: Commit** `src/check.jl src/macros.jl test/parametric_skip_test.jl docs/src/guide/verification.md`, with subject "Skip parametric types in bulk verification".

### Task 2: `contract_signatures` (spec A)

**Files:**
- Modify: `src/check.jl` (add the function after `_contract_types_in_module`)
- Modify: `src/TypeContracts.jl` (add `contract_signatures` to the `check_contract, satisfies, …` export line)
- Create: `test/contract_signatures_test.jl`
- Modify: `docs/src/guide/introspection.md`, `docs/src/reference/api.md` (Introspection section)

**Interfaces:**
- Consumes: `_contract_types_in_module(mod, nothing)` (Task 1), `_build_sig`, `_resolve_rt_spec`, `_registry_key`, `_contract_specs`.
- Produces: `contract_signatures(mod::Module; optional::Bool = false) -> Vector{@NamedTuple{f::Function, sig::Type{<:Tuple}, return_type::Type, T::Type, contract::Type, mandatory::Bool}}`. It returns one entry for each (type, contract in `supertypes(T)`, spec), in that order, and leaves out optional specs unless `optional = true`.

The docstring states that the function is dev/precompile-time only and not trim-safe (it reads `names`, `supertypes` and the contract registry). It also states that `sig` and `return_type` are exactly what `check_contract` uses.

- [ ] **Step 1: Write the failing tests** in `test/contract_signatures_test.jl`, as `@testitem "contract_signatures"`, with one `@eval module` fixture:
  - A plain contract `area(::Self)::Float64` with `Circle`: one entry, `sig == Tuple{Circle}`, `return_type == Float64`, `contract == AbstractShapeS`, `mandatory`.
  - `Self` in the second position, `render(::SVGRendererS, ::Self)::String`: `sig == Tuple{SVGRendererS, Circle}`.
  - A parametric contract `get1(::Self)::T` with `IntBucket <: AbstractBucketS{Int}`: `return_type == Int`. A bare parametric `Bucket{T}` in the same module has no entries.
  - A foreign contract: the contract lives in another module. Define `abstract type ForeignBase{T} end` and its `@contract` in a separate `@eval module ForeignOwner`, and in the fixture module define `struct Local <: ForeignOwner.ForeignBase{Int}`. Its entry has `contract == ForeignOwner.ForeignBase`. A contract on a Base type would leak into other test items, which is why the test doesn't use one.
  - The `optional` flag: an `:optional` spec appears only with `optional = true`, and then with `mandatory == false`.
  - Consistency: for every entry of a module where `@verify_all` passed, `hasmethod(e.f, e.sig)` holds.
  - Review Focus 4: `contract_signatures(Module(:EmptyS)) == []`, with no throw.

- [ ] **Step 2: Run them and confirm they fail.** `name_pattern = "contract_signatures"`. Expected: FAIL with an `UndefVarError` for `contract_signatures`.

- [ ] **Step 3: Implement** `contract_signatures` in `src/check.jl` and export it.

- [ ] **Step 4: Run the item.** Expected: PASS.

- [ ] **Step 5: Document.** Add a `contract_signatures(mod)` section to `guide/introspection.md` with an example and the not-trim-safe note, and add it to the `reference/api.md` Introspection `@docs` block.

- [ ] **Step 6: Commit**, with subject "Add contract_signatures".

### Task 3: Verify hook (spec B)

**Files:**
- Modify: `src/registry.jl` (hook type and fallback next to `_DocSyncHook`; change `_revise_tracked_types` to `Set{Tuple{Module,Type}}()`)
- Modify: `src/macros.jl` (`@verify`, both `let` branches; `_verify_all_in_module`; `@delegate`)
- Modify: `src/check.jl` (`_verify_subtypes`; `_check_contract_warn` becomes `_check_contract_warn(mod::Module, T::Type)`; `_revise_check_module` passes `mod`)
- Modify: `ext/TypeContractsReviseExt.jl` (`for (mod, T) in _revise_tracked_types`)
- Modify: `test/revise_check_test.jl` (call the two-argument form)
- Create: `test/verify_hook_test.jl`
- Modify: `docs/src/reference/api.md` (new "Extension hooks" section), `docs/src/guide/revise.md` (one paragraph: hook exceptions are reported as warnings in the re-check)

**Interfaces:**
- Produces: `struct _VerifyHook end`, `const _VERIFY_HOOK = _VerifyHook()`, and `_verify_hook(::_VerifyHook, mod::Module, @nospecialize(T::Type), result) = nothing`. Each of the five paths calls `_verify_hook(_VERIFY_HOOK, mod, T, result)` with `mod`/`result` taken from the spec's table, in the order **check passes → `_verify_hook` → `_seal_verified!` → `check_trim_compat` (if requested)**. For `@delegate`, `result = (type = W, contracts = Type[_registry_key(I)], passed = true)`.
- `_check_contract_warn(mod, T)` calls the hook after a successful `check_contract(T)`, inside the existing `try`. A hook exception produces `"Contract re-check failed"` (the non-`InterfaceError` branch).
- `@verify` pushes `(@__MODULE__, T)` into `_revise_tracked_types`.

- [ ] **Step 1: Write the failing tests** in `test/verify_hook_test.jl`, as `@testitem "verify hook"`. Each fixture module defines a hook method restricted to its own type, so other test items are not affected: `TypeContracts._verify_hook(::TypeContracts._VerifyHook, mod::Module, ::Type{HookT}, result) = push!(CALLS, (mod, HookT, result))`, where `CALLS` is a `const` vector in the fixture module.
  - `@verify HookT`: one call with `mod` equal to the fixture module and `result.passed`.
  - `@verify HookT for_contract=I`, `@verify I subtypes=true`, `@verify_all` and `@delegate W :field I`: one call each with the matching `T` and `result.contracts`.
  - A throwing hook (`error("gate")`): `@verify HookBad` throws `"gate"`, and `verified_trait(I, HookBad)` is `NotImplemented`.
  - Review Focus 5: `@verify_all` over `A` (passing hook) and `B` (throwing hook) throws. `verified_trait(I, A)` is `Implemented` and `verified_trait(I, B)` is `NotImplemented`. Name the types so `names(mod)` order is irrelevant: assert per type, not on call order.
  - Revise path: `@test_logs (:warn, "Contract re-check failed") match_mode=:any TypeContracts._check_contract_warn(mod, HookBad2)`, where `HookBad2` satisfies the contract and its hook throws.

- [ ] **Step 2: Run them and confirm they fail.** `name_pattern = "verify hook"`. Expected: FAIL with an `UndefVarError` for `_VerifyHook`.

- [ ] **Step 3: Implement** as described in Interfaces, and update `test/revise_check_test.jl` to the two-argument `_check_contract_warn`.

- [ ] **Step 4: Run** `verify hook`, `Revise re-check`, `@verify_all`, `@delegate` and `verified_trait`. Expected: all PASS.

- [ ] **Step 5: Document** the "Extension hooks" section in `api.md`: the signature, when the hook is called, the call order, that only one generic method can be defined, and that methods restricted by type are allowed. Add the `revise.md` paragraph.

- [ ] **Step 6: Commit**, with subject "Add _verify_hook dispatch hook".

### Task 4: Release 0.14.1

**Files:**
- Modify: `Project.toml` (`version = "0.14.1"`). This is the only hand edit to a TOML file in this plan. It is not a dependency change, and Pkg has no command for setting the version.
- Modify: `CHANGELOG.md` (a new `## [0.14.1] - <date>` section, with Added: `contract_signatures` and `_verify_hook`; Fixed: parametric types in bulk verification, and Revise re-check exceptions)
- Modify: `CLAUDE.md` (Architecture table: `check.jl` gains `contract_signatures` and `_contract_types_in_module`; `registry.jl` gains `_VerifyHook`). The file is untracked, so it is not part of the commit.

- [ ] **Step 1: Run `runic -i .`** and the full gate `julia --project=. -e 'using Pkg; Pkg.test()'`. Expected: `Testing TypeContracts tests passed`, with no failures.
- [ ] **Step 2: Build the docs** (`include("make.jl")` in a warm `docs` session). Expected: no errors, and the new sections are present in `docs/build`.
- [ ] **Step 3: Commit** `Project.toml CHANGELOG.md`, with subject "Release 0.14.1".
- [ ] **Step 4: Notify the StrictMode session.** Say that 0.14.1 is ready locally, list the API exactly as shipped, and note that the release still has to be registered.
