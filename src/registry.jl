# All contract state is stored as *method definitions*, never mutable globals.
# `@contract` emits:
#   - a concrete `interface_trait(::Type{I}, ::Type{T})` method (runtime dispatch key)
#   - `_contract_specs` / `_contract_desc` methods (used by check_contract, satisfies,
#     describe, list_contract, check_trim_compat)
# `@invariants` emits `_behavior_specs` methods.
#
# Method definitions are code, not mutable state: they are serialized into the
# registering package's precompile cache and survive precompilation and reloads.
# This is what makes multi-package coexistence safe under Julia's precompilation
# model — there is no shared dict to be reset out from under a dependent package.

# Types and modules registered for live re-checking by the Revise extension. Each type
# entry is `(module that verified it, type, interface)`; the interface is `nothing` for
# a check against the supertype chain and `I` for `@verify T for_contract=I`.
const _revise_tracked_types = Set{Tuple{Module, Type, Any}}()
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

# Verification hook, same dispatch pattern. Every path that verifies a type —
# `@verify`, `@verify T for_contract=I`, `@verify T subtypes=true`, `@verify_all`,
# `@delegate` — calls `_verify_hook(_VERIFY_HOOK, mod, T, result)` once per type,
# after the contract check passes and before `verified_trait` is sealed, so a hook
# that throws fails the verification and leaves the type unsealed. `result` has the
# shape of `check_contract`'s return value. Another package adds a method
# specialized on `_VerifyHook` (optionally restricted to its own types) to run
# extra checks; the fallback does nothing. The fallback is untyped so that a method
# written as `(::_VerifyHook, ::Module, ::Type, ::Any)` is strictly more specific
# and adds to it; an identical signature would replace it, which is an error during
# precompilation.
struct _VerifyHook end
const _VERIFY_HOOK = _VerifyHook()

_verify_hook(::Any, ::Any, @nospecialize(T), result) = nothing

# Doc attachment: no-op fallback used in scripts and juliac binaries where REPL is absent.
# The REPL extension adds a method specialised on `_DocSyncHook`.
_attach_contract_doc(::Any, @nospecialize(::Type)) = nothing

# One-argument entry emitted by the macros. `::Type{T}` forces specialization so
# the dispatch stays statically resolvable under `juliac --trim`.
function _attach_contract_doc(::Type{T}) where {T}
    _attach_contract_doc(_DOC_SYNC_HOOK, T)
    return nothing
end

# Called before `@contract`/`@invariants` defines `f(::Type{T})` (`f` is `_contract_specs`
# or `_behavior_specs`). Redefining that method is an error during precompilation, so a
# second registration for `T` throws there, naming the module that holds the first.
# Interactively the new registration replaces the old one, with a warning.
function _check_reregistration(f, @nospecialize(T), macro_name::String, what::String)
    m = which(f, Tuple{Type{T}})
    m.sig === Tuple{typeof(f), Type{T}} || return nothing
    iszero(ccall(:jl_generating_output, Cint, ())) || error(
        "$macro_name: $T already has $what registered in module $(m.module), and a " *
            "method cannot be redefined during precompilation. Register a type's " *
            "$what once, in the package that owns the type."
    )
    @warn "$macro_name: overwriting existing $what for $T — " *
        "check for a conflicting $macro_name registration in another package"
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

# Invariants that apply through supertype `S`: those registered for its type name
# (`@invariants AbstractBag`) and, for a parameterized `S`, those registered for `S`
# itself (`@invariants AbstractBag{Int}`).
function _behaviors_for(S::Type)
    K = _registry_key(S)
    K === S && return _behavior_specs(K)
    return vcat(_behavior_specs(K), _behavior_specs(S))
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

# Stands for the type parameter at index `I` of contract `B` inside another type, as in
# `::Vector{T}` (a bare `T` is a `TypeParamRef`). A placeholder must be a type, because it
# is a parameter of the enclosing type.
struct _NestedParam{B, I} end

# Replace `Self` and `_NestedParam` placeholders anywhere inside type `t`. Type parameters
# are taken from `P`'s supertype chain: `P` is the checked type, or the interface for a
# structural check (`for_contract = I{Int}`). A type without placeholders is returned as is.
# `vars` maps a type variable whose bounds contained a placeholder (`Type{<:Self}`) to
# its replacement.
function _substitute(@nospecialize(t), T::Type, @nospecialize(P), vars::IdDict = IdDict())
    t === Self && return T
    if t isa TypeVar
        return get(vars, t, t)
    elseif t isa UnionAll
        v = t.var
        lb, ub = _substitute(v.lb, T, P, vars), _substitute(v.ub, T, P, vars)
        nv = lb === v.lb && ub === v.ub ? v : TypeVar(v.name, lb, ub)
        inner = nv === v ? vars : (d = copy(vars); d[v] = nv; d)
        body = _substitute(t.body, T, P, inner)
        return nv === v && body === t.body ? t : UnionAll(nv, body)
    elseif t isa Core.TypeofVararg
        V = _substitute(t.T, T, P, vars)
        return isdefined(t, :N) ? Vararg{V, _substitute(t.N, T, P, vars)} : Vararg{V}
    elseif t isa Union
        return Union{_substitute(t.a, T, P, vars), _substitute(t.b, T, P, vars)}
    elseif t isa DataType
        t.name === _NestedParam.body.body.name &&
            return _extract_param(P, TypeParamRef(t.parameters[1], t.parameters[2]))
        isempty(t.parameters) && return t
        params = Any[_substitute(p, T, P, vars) for p in t.parameters]
        all(i -> params[i] === t.parameters[i], eachindex(params)) && return t
        return t.name.wrapper{params...}
    end
    return t
end

function _resolve_rt_spec(concrete_type::Type, spec::MethodSpec, params = concrete_type)
    spec.return_type_spec isa TypeParamRef &&
        return _extract_param(params, spec.return_type_spec)
    return _substitute(spec.return_type_spec, concrete_type, params)
end

# For parameterized supertypes like AbstractBucket{Int}, return the UnionAll
# wrapper (AbstractBucket) so it matches registry entries from
# @contract AbstractBucket{T} begin ... end
#
# A supertype of a bare parametric name with a bounded parameter is itself a
# `UnionAll` (`AbstractBucket{T} where T<:Real`), so it is unwrapped first.
function _registry_key(S::Type)
    U = Base.unwrap_unionall(S)
    U isa DataType && !isempty(U.parameters) && return U.name.wrapper
    return S
end

# `Any`, not `Type`, elements: a `Vararg` is not a `Type`.
function _build_sig(arg_types::Vector{Any}, T::Type, params = T)
    n = length(arg_types)
    resolved = Vector{Any}(undef, n)
    @inbounds for i in 1:n
        at = arg_types[i]
        resolved[i] = at isa TypeParamRef ? _extract_param(params, at) :
            _substitute(at, T, params)
    end
    return Tuple{resolved...}
end
