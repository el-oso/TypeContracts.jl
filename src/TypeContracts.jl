module TypeContracts

using InteractiveUtils: supertypes

export @contract, @verify, @verify_all, @invariants, @delegate,
    check_contract, satisfies, list_contract, registered_contracts,
    test_behavior, list_behaviors, registered_behaviors,
    describe, interface_trait,
    Self, TypeParamRef, InterfaceError, MethodSpec, BehaviorSpec,
    Implemented, NotImplemented

# ── Core Types ────────────────────────────────────────────────────────

"""
    Self

Sentinel type used in `@contract` declarations as a placeholder for the
concrete implementing type. At verification time, `Self` is substituted
with the actual type being checked.
"""
struct Self end

Base.show(io::IO, ::Type{Self}) = print(io, "Self")

"""
    TypeParamRef

Reference to a type parameter of a parametric abstract type.
Used in `@contract AbstractType{T,N}` blocks to refer to `T` or `N`
in method signatures and return types.

At check time, resolved by extracting the corresponding parameter from
the concrete type's supertype chain.

Juliac-compatible: plain data struct, no closures.
"""
struct TypeParamRef
    abstract_base::Any  # UnionAll or DataType (e.g. AbstractArray)
    param_index::Int    # 1 = first type param (T), 2 = second (N), etc.
end

"""
    InterfaceError <: Exception

Thrown when a type does not satisfy its registered interface contract.
"""
struct InterfaceError <: Exception
    msg::String
end

Base.showerror(io::IO, e::InterfaceError) = print(io, "InterfaceError: ", e.msg)

"""
    MethodSpec

A single method requirement within an interface contract.

# Fields
- `f::Function` — the function object
- `arg_types::Vector{Any}` — argument types (`Self`, `TypeParamRef`, or concrete `Type`)
- `return_type::Type` — annotated return type for display (`Any` if unspecified or parametric)
- `return_type_spec::Union{Type,TypeParamRef}` — used for actual return type checking
- `description::String` — human-readable signature for error messages
- `optional::Bool` — whether this method is optional
- `doc::String` — optional prose description (`""` if none); shown in `?`-docs and `describe`
"""
struct MethodSpec
    f::Function
    arg_types::Vector{Any}
    return_type::Type
    return_type_spec::Union{Type, TypeParamRef}
    description::String
    optional::Bool
    doc::String
end

function Base.show(io::IO, s::MethodSpec)
    s.optional && print(io, "[optional] ")
    return print(io, s.description)
end

"""
    BehaviorSpec

A behavioral invariant tested against real objects at test time.

# Fields
- `description::String` — human-readable description
- `predicate::Function` — `x -> Bool`, takes a test object
- `optional::Bool` — whether this invariant is optional
"""
struct BehaviorSpec
    description::String
    predicate::Function
    optional::Bool
end

function Base.show(io::IO, b::BehaviorSpec)
    b.optional && print(io, "[optional] ")
    return print(io, b.description)
end

# ── Holy Trait Types ──────────────────────────────────────────────────

"""
    Implemented{I}

Singleton trait type returned by [`interface_trait`](@ref) when a type satisfies
all mandatory methods of interface `I`. Used as a dispatch key.

```julia
_process(::Implemented{AbstractShape}, x) = area(x)
```
"""
struct Implemented{I} end

"""
    NotImplemented{I}

Singleton trait type returned by [`interface_trait`](@ref) when a type does **not**
satisfy all mandatory methods of interface `I`. Used as a dispatch key.

```julia
_process(::NotImplemented{AbstractShape}, x) = error("not a shape")
```
"""
struct NotImplemented{I} end

Base.show(io::IO, ::Implemented{I}) where {I} = print(io, "Implemented{$I}()")
Base.show(io::IO, ::NotImplemented{I}) where {I} = print(io, "NotImplemented{$I}()")

# ── Registries ────────────────────────────────────────────────────────
#
# `_registry` is kept as a mutable dict solely for the `interface_trait`
# @generated function. @generated bodies run in a fixed world age and cannot
# dispatch to methods added after the @generated function was defined, so
# dict access (world-age-insensitive) is the only safe option there.
#
# Everything else — check_contract, satisfies, describe, list_contract,
# list_behaviors, test_behavior — uses dispatch-based functions below.
# Those are extended by `@contract` / `@invariants` via method definitions,
# which are code rather than mutable state, making multi-package coexistence
# safe under Julia's precompilation model.

const _registry = Dict{Type, Vector{MethodSpec}}()

"""
    _contract_specs(::Type{T}) -> Vector{MethodSpec}

Return method specs registered for abstract type `T` via `@contract`.
Returns `MethodSpec[]` for types with no registered contract.
"""
_contract_specs(::Type) = MethodSpec[]

"""
    _behavior_specs(::Type{T}) -> Vector{BehaviorSpec}

Return behavioral invariants registered for type `T` via `@invariants`.
Returns `BehaviorSpec[]` for types with none registered.
"""
_behavior_specs(::Type) = BehaviorSpec[]

"""
    _contract_desc(::Type{T}) -> String

Return the interface-level prose description for abstract type `T`.
Returns `""` if none was provided to `@contract`.
"""
_contract_desc(::Type) = ""

# Documentation attachment uses a *dispatch-based* hook. `ext/TypeContractsREPLExt.jl`
# (loaded only when REPL is present, i.e. interactive sessions) adds a method of
# `_attach_contract_doc` specialised on `_DocSyncHook`. In scripts and juliac-trim
# builds the extension is absent, so the macros' doc-attach call resolves statically
# to the no-op fallback (see the `_attach_contract_doc` definitions below).
#
# This is what keeps `@contract` / `@invariants` registration trim-safe even from a
# module `__init__` (which juliac compiles as an entrypoint): the call goes through
# ordinary multiple dispatch to a concrete method, never through a stored
# `Function` value — the latter is an unresolved dynamic call that `--trim=safe`
# rejects.
struct _DocSyncHook end
const _DOC_SYNC_HOOK = _DocSyncHook()

# ── Introspection helpers ─────────────────────────────────────────────

function _method_registered_type(m::Method)
    p = m.sig.parameters
    length(p) == 2 || return nothing
    p[2] isa DataType && p[2].name.name === :Type || return nothing
    isempty(p[2].parameters) && return nothing
    T = p[2].parameters[1]
    return T isa Type ? T : nothing
end

"""
    registered_contracts() -> Dict{Type, Vector{MethodSpec}}

Return every abstract type that has a registered `@contract`, mapped to its
`Vector{MethodSpec}`. Implemented via method introspection; intended for
interactive use.
"""
function registered_contracts()::Dict{Type, Vector{MethodSpec}}
    result = Dict{Type, Vector{MethodSpec}}()
    for m in methods(_contract_specs)
        T = _method_registered_type(m)
        T === nothing && continue
        result[T] = _contract_specs(T)
    end
    return result
end

"""
    registered_behaviors() -> Dict{Type, Vector{BehaviorSpec}}

Return every type that has registered `@invariants`, mapped to its
`Vector{BehaviorSpec}`. Implemented via method introspection; intended for
interactive use.
"""
function registered_behaviors()::Dict{Type, Vector{BehaviorSpec}}
    result = Dict{Type, Vector{BehaviorSpec}}()
    for m in methods(_behavior_specs)
        T = _method_registered_type(m)
        T === nothing && continue
        result[T] = _behavior_specs(T)
    end
    return result
end

# ── Internal ──────────────────────────────────────────────────────────

"""
    _extract_param(concrete_type, ref::TypeParamRef) -> Type

Resolve a `TypeParamRef` by walking `concrete_type`'s supertype chain to find
the parameterisation of `ref.abstract_base` and returning parameter at
`ref.param_index`. Returns `Any` if the chain does not contain the base.
"""
function _extract_param(concrete_type::Type, ref::TypeParamRef)
    # Unwrap all UnionAll layers to reach the DataType (e.g. AbstractArray{T,N}
    # is UnionAll{T, UnionAll{N, DataType}}, so two unwraps are needed).
    # UnionAll.body::Any erases the type across the loop, so we assert DataType
    # explicitly after the || guard for JET / juliac trim inference.
    base = ref.abstract_base
    while base isa UnionAll
        base = base.body
    end
    base isa DataType || return Any
    base_name = (base::DataType).name
    for S in supertypes(concrete_type)
        S isa DataType || continue
        S.name === base_name || continue
        ref.param_index <= length(S.parameters) || return Any
        return S.parameters[ref.param_index]
    end
    return Any
end

function _resolve_rt_spec(concrete_type::Type, spec::MethodSpec)
    return spec.return_type_spec isa TypeParamRef ?
        _extract_param(concrete_type, spec.return_type_spec) :
        spec.return_type_spec
end

# For parameterized supertypes like AbstractBucket{Int}, return the UnionAll
# wrapper (AbstractBucket) so it matches registry entries from
# @contract AbstractBucket{T} begin ... end
function _registry_key(S::Type)
    S isa DataType && !isempty(S.parameters) && return S.name.wrapper
    return S
end

function _build_sig(arg_types::Vector{Any}, T::Type)
    n = length(arg_types)
    resolved = Vector{Type}(undef, n)
    @inbounds for i in 1:n
        at = arg_types[i]
        resolved[i] = at === Self ? T :
            at isa TypeParamRef ? _extract_param(T, at) :
            at
    end
    return Tuple{resolved...}
end

# ── Public API: Structural Checks ─────────────────────────────────────

"""
    check_contract(T::Type) -> NamedTuple{(:type, :contracts, :passed)}

Verify that `T` satisfies all **mandatory** contracts for its supertype chain.
Checks both method existence and declared return types (via Julia's type inferencer).
Optional methods are skipped. Throws `InterfaceError` on failure.

This is a precompile-time tool. `Base.return_types` is called here and requires
Julia's type inference machinery — use via `@verify` / `@verify_all` at module
load time, not in Juliac-compiled binaries at runtime.
"""
function check_contract(T::Type)
    errors = String[]
    checked = Type[]

    for S in supertypes(T)
        specs = _contract_specs(_registry_key(S))
        isempty(specs) && continue
        push!(checked, _registry_key(S))
        for spec in specs
            spec.optional && continue
            sig = _build_sig(spec.arg_types, T)
            if !hasmethod(spec.f, sig)
                push!(errors, "  $(spec.description)  [required by $S]")
            else
                expected_rt = _resolve_rt_spec(T, spec)
                if expected_rt !== Any
                    inferred_rts = Base.return_types(spec.f, sig)
                    inferred_rt = isempty(inferred_rts) ? Union{} :
                        length(inferred_rts) == 1 ? inferred_rts[1] :
                        Union{inferred_rts...}
                    if !(inferred_rt <: expected_rt)
                        push!(
                            errors,
                            "  $(spec.description) — return $(inferred_rt) ⊄ $(expected_rt)  [required by $S]"
                        )
                    end
                end
            end
        end
    end

    if !isempty(errors)
        throw(
            InterfaceError(
                "Type $T does not satisfy interface contract.\n" *
                    "Missing or incorrect methods:\n" *
                    join(errors, "\n")
            )
        )
    end

    return (type = T, contracts = checked, passed = true)
end

"""
    satisfies(T::Type, S::Type) -> NamedTuple

Non-throwing check. Returns `(satisfied, missing_methods, missing_optional)`.
`satisfied` is true when all mandatory methods are present and return types match.

Precompile-time tool — uses `Base.return_types` for return type checking.
"""
function satisfies(T::Type, S::Type)
    specs = _contract_specs(_registry_key(S))
    isempty(specs) && return (satisfied = true, missing_methods = String[], missing_optional = String[])

    missing_methods = String[]
    missing_optional = String[]
    for spec in specs
        sig = _build_sig(spec.arg_types, T)
        if !hasmethod(spec.f, sig)
            push!(spec.optional ? missing_optional : missing_methods, spec.description)
        elseif !spec.optional
            expected_rt = _resolve_rt_spec(T, spec)
            if expected_rt !== Any
                inferred_rts = Base.return_types(spec.f, sig)
                inferred_rt = isempty(inferred_rts) ? Union{} :
                    length(inferred_rts) == 1 ? inferred_rts[1] :
                    Union{inferred_rts...}
                if !(inferred_rt <: expected_rt)
                    push!(
                        missing_methods,
                        "$(spec.description) [return: $(inferred_rt) ⊄ $(expected_rt)]"
                    )
                end
            end
        end
    end

    return (satisfied = isempty(missing_methods), missing_methods = missing_methods, missing_optional = missing_optional)
end

"""
    list_contract(T::Type) -> Vector{MethodSpec}

Return method specs registered directly for type `T`.
"""
function list_contract(T::Type)::Vector{MethodSpec}
    return _contract_specs(T)
end

"""
    list_contract(T::Type, Val(:all)) -> Dict{Type, Vector{MethodSpec}}

Return all contracts applicable to `T` via its supertype chain.
"""
function list_contract(T::Type, ::Val{:all})::Dict{Type, Vector{MethodSpec}}
    result = Dict{Type, Vector{MethodSpec}}()
    for S in supertypes(T)
        key = _registry_key(S)
        specs = _contract_specs(key)
        !isempty(specs) && (result[key] = specs)
    end
    return result
end

"""
    list_behaviors(T::Type) -> Vector{BehaviorSpec}

Return behavioral invariants registered directly for type `T`.
"""
function list_behaviors(T::Type)::Vector{BehaviorSpec}
    return _behavior_specs(T)
end

# ── Public API: Holy Trait Dispatch ───────────────────────────────────

"""
    interface_trait(::Type{I}, ::Type{T}) -> Implemented{I} | NotImplemented{I}

Check if `T` satisfies the mandatory contract for `I` (method existence only).
Returns a singleton trait type suitable for dispatch.

Trim/juliac-compatible: implemented as a `@generated` function. Both `I` and `T`
are known at specialization time, so the contract is looked up in the registry
*during code generation* and the body emitted as a fixed conjunction of concrete
`hasmethod(f, Tuple{…})` calls — no runtime registry lookup, no abstractly-typed
`Function`, no dynamically-built signature. The result is statically resolvable
and passes `juliac --trim` verification.

Because the contract is baked in at the first call for a given `(I, T)` pair,
register contracts before querying them — the standard usage (contracts declared
at module load, checked afterward).

# Example
```julia
process(x) = _process(interface_trait(AbstractShape, typeof(x)), x)
_process(::Implemented{AbstractShape}, x) = area(x)
_process(::NotImplemented{AbstractShape}, x) = error("not a shape")
```
"""
@generated function interface_trait(::Type{I}, ::Type{T}) where {I, T}
    specs = get(_registry, _registry_key(I), nothing)
    isnothing(specs) && return :(NotImplemented{I}())

    checks = Expr[]
    for spec in specs
        spec.optional && continue
        sig = _build_sig(spec.arg_types, T)        # concrete Tuple type, built now
        push!(checks, :(hasmethod($(spec.f), $sig)))
    end
    isempty(checks) && return :(Implemented{I}())

    cond = foldl((a, b) -> :($a && $b), checks)
    return :($cond ? Implemented{I}() : NotImplemented{I}())
end

# ── Public API: Behavioral Testing ────────────────────────────────────

"""
    test_behavior(T::Type, objects) -> NamedTuple

Run all behavioral invariants registered for `T`'s supertype chain
against `deepcopy`'d test `objects`. Returns `(passed, results, mandatory_failures)`.

`passed` is true when all mandatory invariants hold for all objects.
"""
function test_behavior(::Type{T}, objects) where {T}
    results = NamedTuple{
        (:type, :description, :passed, :optional, :error),
        Tuple{Type, String, Bool, Bool, String},
    }[]

    for S in supertypes(T)
        behaviors = _behavior_specs(_registry_key(S))
        isempty(behaviors) && continue
        _run_behaviors!(results, S, behaviors, objects)
    end

    mandatory_failures = filter(r -> !r.passed && !r.optional, results)
    return (passed = isempty(mandatory_failures), results = results, mandatory_failures = mandatory_failures)
end

"""
    test_behavior(T::Type, S::Type, objects) -> NamedTuple

Run behavioral invariants registered for `S` specifically against objects of type `T`.
"""
function test_behavior(::Type{T}, ::Type{S}, objects) where {T, S}
    results = NamedTuple{
        (:type, :description, :passed, :optional, :error),
        Tuple{Type, String, Bool, Bool, String},
    }[]

    behaviors = _behavior_specs(S)
    !isempty(behaviors) && _run_behaviors!(results, S, behaviors, objects)

    mandatory_failures = filter(r -> !r.passed && !r.optional, results)
    return (passed = isempty(mandatory_failures), results = results, mandatory_failures = mandatory_failures)
end

function _run_behaviors!(results, S::Type, behaviors::Vector{BehaviorSpec}, objects)
    for bspec in behaviors
        for obj in objects
            passed = true
            errmsg = ""
            try
                passed = bspec.predicate(deepcopy(obj))::Bool
            catch e
                passed = false
                errmsg = sprint(showerror, e)
            end
            push!(
                results, (
                    type = S, description = bspec.description,
                    passed = passed, optional = bspec.optional, error = errmsg,
                )
            )
        end
    end
    return
end

# ── Public API: Describe ──────────────────────────────────────────────

"""
    describe(T::Type; io::IO=stdout)

Pretty-print the full contract for `T`: mandatory methods, optional methods,
and behavioral invariants.
"""
function describe(::Type{T}; io::IO = stdout) where {T}
    printstyled(io, "Interface contract for "; bold = true)
    printstyled(io, T; bold = true, color = :cyan)
    println(io)
    printstyled(io, "─"^40; color = :light_black)
    println(io)

    specs = _contract_specs(T)
    behaviors = _behavior_specs(T)
    desc = _contract_desc(T)

    if isempty(specs) && isempty(behaviors)
        printstyled(io, "  (no contract registered)\n"; color = :light_black)
        return nothing
    end

    if !isempty(desc)
        printstyled(io, "  ", desc; color = :light_black)
        println(io); println(io)
    end

    if !isempty(specs)
        mandatory = filter(s -> !s.optional, specs)
        optional = filter(s -> s.optional, specs)

        if !isempty(mandatory)
            printstyled(io, "  Mandatory methods:\n"; bold = true, color = :green)
            for s in mandatory
                print(io, "    ")
                _print_method_line(io, s)
                println(io)
            end
        end
        if !isempty(optional)
            printstyled(io, "  Optional methods:\n"; bold = true, color = :yellow)
            for s in optional
                print(io, "    ")
                _print_method_line(io, s)
                println(io)
            end
        end
    end

    if !isempty(behaviors)
        mandatory_b = filter(b -> !b.optional, behaviors)
        optional_b = filter(b -> b.optional, behaviors)

        if !isempty(mandatory_b)
            printstyled(io, "  Behavioral invariants:\n"; bold = true, color = :magenta)
            for b in mandatory_b
                print(io, "    ")
                printstyled(io, b.description; color = :light_black)
                println(io)
            end
        end
        if !isempty(optional_b)
            printstyled(io, "  Optional invariants:\n"; bold = true, color = :yellow)
            for b in optional_b
                print(io, "    ")
                printstyled(io, b.description; color = :light_black)
                println(io)
            end
        end
    end

    return nothing
end

"""
    describe(T::Type, Val(:all); io::IO=stdout)

Pretty-print contracts for `T`'s full supertype chain.
"""
function describe(::Type{T}, ::Val{:all}; io::IO = stdout) where {T}
    printstyled(io, "Full interface contract for "; bold = true)
    printstyled(io, T; bold = true, color = :cyan)
    println(io)
    printstyled(io, "="^40; color = :light_black)
    println(io)

    found = false
    for S in supertypes(T)
        key = _registry_key(S)
        specs = _contract_specs(key)
        behaviors = _behavior_specs(key)
        (isempty(specs) && isempty(behaviors)) && continue
        found = true

        println(io)
        print(io, "  From ")
        printstyled(io, S; bold = true, color = :cyan)
        println(io, ":")

        if !isempty(specs)
            mandatory = filter(s -> !s.optional, specs)
            optional = filter(s -> s.optional, specs)
            for s in mandatory
                print(io, "    ")
                _print_method_line(io, s)
                println(io)
            end
            for s in optional
                print(io, "    ")
                printstyled(io, "[optional] "; color = :yellow)
                _print_method_line(io, s)
                println(io)
            end
        end

        if !isempty(behaviors)
            for b in behaviors
                print(io, "    ")
                if b.optional
                    printstyled(io, "[optional invariant] "; color = :yellow)
                else
                    printstyled(io, "[invariant] "; color = :magenta)
                end
                printstyled(io, b.description; color = :light_black)
                println(io)
            end
        end
    end

    found || printstyled(io, "  (no contracts registered)\n"; color = :light_black)
    return nothing
end

# ── Documentation integration ─────────────────────────────────────────
# Doc attachment is handled by ext/TypeContractsREPLExt.jl, which loads
# automatically when REPL is present (interactive sessions). In scripts and
# juliac binaries REPL is absent, so the extension never loads, Markdown is
# never pulled in, and the call below resolves to the no-op fallback.
#
# Two-argument dispatch hook: the REPL extension adds a method specialised on
# `_DocSyncHook` that does the actual Markdown attachment. Only this no-op
# fallback exists in a trimmed/script context, so the call is statically resolved.
_attach_contract_doc(::Any, @nospecialize(::Type)) = nothing

# One-argument entry the macros emit. `::Type{T}` (rather than a plain `::Type`
# value argument) forces specialisation, so the type passed to the hook is
# concrete and the dispatch stays statically resolvable under `juliac --trim`.
function _attach_contract_doc(::Type{T}) where {T}
    _attach_contract_doc(_DOC_SYNC_HOOK, T)
    return nothing
end

# Colored method line for `describe`: function name in cyan, args normal, doc dimmed.
function _print_method_line(io::IO, s::MethodSpec)
    desc = s.description
    paren = findfirst('(', desc)
    if isnothing(paren)
        printstyled(io, desc; color = :cyan)
    else
        printstyled(io, desc[1:prevind(desc, paren)]; color = :cyan, bold = true)
        print(io, desc[paren:end])
    end
    return if !isempty(s.doc)
        printstyled(io, " — "; color = :light_black)
        printstyled(io, s.doc; color = :light_black)
    end
end

# ── Macros ────────────────────────────────────────────────────────────

"""
    @contract AbstractType begin
        method1(::Self, ::ArgType)
        method2(::Self) :: ReturnType
        :optional
        method3(::Self)
    end

    @contract AbstractType{T,N} begin
        method1(::Self, ::Int) :: T
        method2(::Self, ::T, ::Int)
    end

Register a method contract for a type. Type parameters (`T`, `N`, …) declared
in the header can be used anywhere in the method signatures — they are resolved
at check time from the concrete type's supertype chain.

Methods before `:optional` are mandatory (enforced by `@verify`).
Methods after `:optional` are recorded but not enforced at compile time.

Functions must be in scope when `@contract` is evaluated.

# Documentation

An optional interface description and per-method descriptions are folded into the
type's `?`-visible documentation (and `describe`). They work for owned types and
for retroactive contracts on foreign types (e.g. `Base.AbstractArray`):

```julia
@contract AbstractShape "A 2-D geometric shape." begin
    area(::Self)::Float64      => "area enclosed by the shape"
    perimeter(::Self)::Float64 => "length of the boundary"
    :optional
    name(::Self)::String       => "human-readable name"
end
```

`?AbstractShape` then shows the contract section alongside any existing docstring.
"""
macro contract(T_expr, block)
    return _build_contract_expr(T_expr, "", block)
end

macro contract(T_expr, desc, block)
    desc isa String ||
        error("@contract: interface description must be a string literal, got: $desc")
    return _build_contract_expr(T_expr, desc, block)
end

function _build_contract_expr(T_expr, desc::String, block)
    block isa Expr && block.head == :block ||
        error("@contract requires a begin...end block")

    abstract_sym, type_vars = _parse_contract_header(T_expr)

    parsed = _parse_block(block)
    spec_exprs = Expr[]

    for (fname, atypes, rtype, opt, mdoc) in parsed
        aexprs = Any[_resolve_arg_expr(t, type_vars, abstract_sym) for t in atypes]

        rtype_display_expr, rtype_spec_expr = _resolve_rtype_exprs(rtype, type_vars, abstract_sym)

        sigdesc = _fmt(fname, atypes, rtype)

        push!(
            spec_exprs, :(
                TypeContracts.MethodSpec(
                    $(esc(fname)),
                    Any[$(aexprs...)],
                    $rtype_display_expr,
                    $rtype_spec_expr,
                    $sigdesc,
                    $opt,
                    $mdoc
                )
            )
        )
    end

    return quote
        isabstracttype($(esc(abstract_sym))) ||
            error("@contract requires an abstract type, got $($(esc(abstract_sym)))")
        # Dict write for interface_trait (@generated bodies need world-age-safe dict access)
        TypeContracts._registry[$(esc(abstract_sym))] = TypeContracts.MethodSpec[$(spec_exprs...)]
        # Method definitions for everything else (precompilation-safe across packages)
        function TypeContracts._contract_specs(::Type{$(esc(abstract_sym))})
            return TypeContracts.MethodSpec[$(spec_exprs...)]
        end
        function TypeContracts._contract_desc(::Type{$(esc(abstract_sym))})
            $desc
        end
        TypeContracts._attach_contract_doc($(esc(abstract_sym)))
        nothing
    end
end

"""
    @verify ConcreteType

Assert at module-load / precompile time that `ConcreteType` satisfies all
mandatory contracts for its supertype chain. Checks both method existence
and declared return types.

Must be placed after all method definitions for the type.
"""
macro verify(T)
    return quote
        TypeContracts.check_contract($(esc(T)))
    end
end

"""
    @verify_all

Assert at module-load / precompile time that **every** concrete subtype
of a registered contract type, defined in the calling module, satisfies
its mandatory contracts.

Place once at the end of your module, after all type and method definitions.
Replaces the need for individual `@verify T` calls.

# Example
```julia
module Shapes
using TypeContracts

abstract type AbstractShape end
@contract AbstractShape begin
    area(::Self)
end

struct Circle <: AbstractShape ... end
area(c::Circle) = ...

struct Square <: AbstractShape ... end
area(s::Square) = ...

@verify_all   # checks Circle AND Square
end
```
"""
macro verify_all()
    return quote
        TypeContracts._verify_all_in_module(@__MODULE__)
    end
end

function _verify_all_in_module(mod::Module)
    checked = Type[]

    for name in names(mod, all = true)
        isdefined(mod, name) || continue
        val = getfield(mod, name)
        val isa Type || continue
        isabstracttype(val) && continue
        parentmodule(val) === mod || continue
        any(S -> !isempty(_contract_specs(_registry_key(S))), supertypes(val)) || continue
        val in checked && continue
        check_contract(val)
        push!(checked, val)
    end

    return (types = checked, passed = true)
end

"""
    @invariants AbstractType begin
        "description" => x -> predicate(x)
        :optional
        "optional check" => x -> other_check(x)
    end

Register behavioral invariants for a type. These are tested at test time
via `test_behavior`, not at compile time. The `:optional` separator works
the same as in `@contract`.
"""
macro invariants(T, block)
    block isa Expr && block.head == :block ||
        error("@invariants requires a begin...end block")

    spec_exprs = Expr[]
    is_optional = false

    for ex in block.args
        ex isa LineNumberNode && continue
        if ex isa QuoteNode && ex.value === :optional
            is_optional = true
            continue
        end

        ex isa Expr && ex.head == :call && length(ex.args) >= 3 && ex.args[1] === :(=>) ||
            error("Expected \"description\" => predicate, got: $ex")

        desc = ex.args[2]
        desc isa String || error("Invariant description must be a string literal, got: $desc")

        push!(
            spec_exprs, :(
                TypeContracts.BehaviorSpec($desc, $(esc(ex.args[3])), $is_optional)
            )
        )
    end

    return quote
        function TypeContracts._behavior_specs(::Type{$(esc(T))})
            return TypeContracts.BehaviorSpec[$(spec_exprs...)]
        end
        TypeContracts._attach_contract_doc($(esc(T)))
        nothing
    end
end

# ── Macro internals ───────────────────────────────────────────────────

function _parse_contract_header(expr)
    if expr isa Symbol
        return expr, Dict{Symbol, Int}()
    elseif expr isa Expr && expr.head == :curly
        abstract_sym = expr.args[1]
        abstract_sym isa Symbol ||
            error("@contract: abstract type name must be a symbol, got $abstract_sym")
        type_vars = Dict{Symbol, Int}()
        for (i, tv) in enumerate(expr.args[2:end])
            tv isa Symbol ||
                error("@contract: type parameter must be a plain symbol, got $tv")
            type_vars[tv] = i
        end
        return abstract_sym, type_vars
    else
        error("@contract expects AbstractType or AbstractType{T,...}, got: $expr")
    end
end

function _resolve_arg_expr(t, type_vars::Dict{Symbol, Int}, abstract_sym::Symbol)
    t isa Symbol && t === :Self && return :(TypeContracts.Self)
    if t isa Symbol && haskey(type_vars, t)
        idx = type_vars[t]
        return :(TypeContracts.TypeParamRef($(esc(abstract_sym)), $idx))
    end
    return esc(t)
end

function _resolve_rtype_exprs(rtype, type_vars::Dict{Symbol, Int}, abstract_sym::Symbol)
    if rtype === :Any
        return :(Any), :(Any)
    elseif rtype isa Symbol && haskey(type_vars, rtype)
        idx = type_vars[rtype]
        return :(Any), :(TypeContracts.TypeParamRef($(esc(abstract_sym)), $idx))
    else
        e = esc(rtype)
        return e, e
    end
end

function _parse_block(block::Expr)
    specs = Tuple{Any, Vector{Any}, Any, Bool, String}[]
    is_optional = false
    for ex in block.args
        ex isa LineNumberNode && continue
        if ex isa QuoteNode && ex.value === :optional
            is_optional = true
            continue
        end
        # Optional per-method prose: `signature => "description"`.
        # `::` binds tighter than `=>`, so `f(::Self)::T => "doc"` parses as
        # Pair(signature_with_rettype, "doc") — signature parsing is untouched.
        sig_ex = ex
        mdoc = ""
        if ex isa Expr && ex.head == :call && length(ex.args) >= 3 && ex.args[1] === :(=>)
            rhs = ex.args[3]
            rhs isa String ||
                error("@contract: method description must be a string literal, got: $rhs")
            mdoc = rhs
            sig_ex = ex.args[2]
        end
        push!(specs, (_parse_sig(sig_ex)..., is_optional, mdoc))
    end
    return specs
end

function _parse_sig(ex)
    call_ex, rtype = _split_ret(ex)
    call_ex isa Expr && call_ex.head == :call ||
        error("Expected function call signature, got: $(ex)")
    fname = call_ex.args[1]
    atypes = Any[_arg_type(call_ex.args[i]) for i in 2:length(call_ex.args)]
    return (fname, atypes, rtype)
end

function _split_ret(ex)
    if ex isa Expr && ex.head == :(::) && length(ex.args) == 2
        inner = ex.args[1]
        if inner isa Expr && inner.head == :call
            return inner, ex.args[2]
        end
    end
    return (ex, :Any)
end

function _arg_type(arg)
    arg isa Expr && arg.head == :(::) ||
        error("Expected typed argument (::T or name::T), got: $(arg)")
    return length(arg.args) == 1 ? arg.args[1] : arg.args[2]
end

function _fmt(fname, atypes, rtype)
    args = join(["::$t" for t in atypes], ", ")
    sig = "$fname($args)"
    return rtype === :Any ? sig : "$sig :: $rtype"
end

# ── @delegate helpers ─────────────────────────────────────────────────

function _wrapper_base_sym(T_expr)
    T_expr isa Symbol && return T_expr
    T_expr isa Expr && T_expr.head == :curly && return T_expr.args[1]
    error("@delegate: expected TypeName or TypeName{T,...}, got: $T_expr")
end

function _fn_name_expr(f::Function)
    fmod = parentmodule(f)
    fname = nameof(f)
    parts = Base.fullname(fmod)
    length(parts) == 1 && parts[1] === :Main && return fname
    expr::Any = parts[1]::Symbol
    for part in parts[2:end]
        expr = Expr(:., expr, QuoteNode(part))
    end
    return Expr(:., expr, QuoteNode(fname))
end

function _forwarder_expr(wrapper_sym::Symbol, field::Symbol, spec::MethodSpec)
    n = length(spec.arg_types)
    names = [Symbol(:_x, i) for i in 1:n]
    sig_args = Any[]
    fwd_args = Any[]
    for (name, at) in zip(names, spec.arg_types)
        if at === Self
            push!(sig_args, :($name::$(esc(wrapper_sym))))
            push!(fwd_args, :(getfield($name, $(QuoteNode(field)))))
        elseif at isa TypeParamRef
            push!(sig_args, name)   # Any dispatch — safe, gets passed through
            push!(fwd_args, name)
        else
            push!(sig_args, :($name::$at))
            push!(fwd_args, name)
        end
    end
    fn_expr = esc(_fn_name_expr(spec.f))
    return :($fn_expr($(sig_args...)) = $fn_expr($(fwd_args...)))
end

"""
    @delegate WrapperType :field InterfaceType

Generate forwarding methods for every mandatory method in `InterfaceType`'s
contract, routing calls to `getfield(wrapper, :field)`. Equivalent to writing
each forwarding method manually, but driven by the registered `@contract`.

After emitting the forwarders, `satisfies(WrapperType, InterfaceType)` is called
automatically and throws `InterfaceError` on failure.

The generated forwarding methods are plain concrete method definitions — no closures,
no runtime dispatch on abstract types. They are fully trim-safe and pass `juliac --trim`.

# Example
```julia
using TypeContracts, BaseTypeContracts

struct LoggedArray{T} <: AbstractArray{T,1}
    data::Vector{T}
    n_reads::Ref{Int}
end
LoggedArray(v::Vector{T}) where T = LoggedArray{T}(v, Ref(0))

# Replaces explicit size/getindex/setindex! forwarding:
@delegate LoggedArray :data AbstractArray

LoggedArray([1, 2, 3])[2]                    # 2
satisfies(LoggedArray{Int}, AbstractArray)   # (satisfied = true, ...)
```

# Limitations
- Only methods in `@contract InterfaceType` are forwarded. Add to the contract first.
- `@contract` (or `using` the package that registers it) must precede `@delegate`.
- Arguments typed as interface type parameters are forwarded untyped (`Any` dispatch).
"""
macro delegate(T_expr, field_expr, I_expr)
    field_expr isa QuoteNode ||
        error("@delegate: second argument must be a quoted field name like :data")
    field = field_expr.value::Symbol
    wrapper_sym = _wrapper_base_sym(T_expr)

    I = Core.eval(__module__, I_expr)
    I isa Type || error("@delegate: $I_expr does not evaluate to a type")

    specs = _contract_specs(_registry_key(I))
    isempty(specs) && error(
        "@delegate: no contract registered for $I — call @contract first"
    )

    I_val = I   # captured for embedding
    body = Any[
        _forwarder_expr(wrapper_sym, field, spec)
            for spec in specs if !spec.optional
    ]
    push!(
        body, quote
            let _res = TypeContracts.satisfies($(esc(wrapper_sym)), $I_val)
                _res.satisfied || throw(
                    TypeContracts.InterfaceError(
                        string(
                            $(esc(wrapper_sym)), " does not satisfy ", $I_val,
                            " after @delegate:\n", join(_res.missing_methods, "\n")
                        )
                    )
                )
            end
        end
    )
    push!(body, :nothing)
    return Expr(:block, body...)
end

end # module TypeContracts
