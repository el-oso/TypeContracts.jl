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

const _registry = Dict{Type, Vector{MethodSpecMin}}()

# Types and modules registered for live re-checking by the Revise extension.
const _revise_tracked_types = Set{Type}()
const _revise_tracked_modules = Set{Module}()

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

# Doc attachment: no-op fallback used in scripts and juliac binaries where REPL is absent.
# The REPL extension adds a method specialised on `_DocSyncHook`.
_attach_contract_doc(::Any, @nospecialize(::Type)) = nothing

# One-argument entry emitted by the macros. `::Type{T}` forces specialization so
# the dispatch stays statically resolvable under `juliac --trim`.
function _attach_contract_doc(::Type{T}) where {T}
    _attach_contract_doc(_DOC_SYNC_HOOK, T)
    return nothing
end

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

# ── Internal resolution helpers ───────────────────────────────────────

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

function _build_sig(arg_types::Tuple, T::Type)
    types = ntuple(length(arg_types)) do i
        at = arg_types[i]
        at === Self ? T : at isa TypeParamRef ? _extract_param(T, at) : at::Type
    end
    return Tuple{types...}
end
