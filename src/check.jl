# Shared by check_contract/satisfies: warn when `spec.f` has a method for `T` whose
# argument types are more specific than the contract's (so `hasmethod` on the exact
# contract signature fails even though an implementation clearly exists). The probe
# has the contract's arity, with `T` where the contract has `Self` and `Any` elsewhere,
# so a method of the same function that takes `T` in some other position (an unrelated
# package's untyped method, say) does not match it.
function _warn_if_more_specific(spec::MethodSpec, T::Type)
    probe = Any[
        _mentions(==(Self), at) ? _substitute(at, T, T) :
            at isa Core.TypeofVararg ? Vararg{Any} : Any
            for at in spec.arg_types
    ]
    any(at -> _mentions(==(Self), at), spec.arg_types) || return nothing
    isempty(methods(spec.f, Tuple{probe...})) && return nothing
    @warn "$(nameof(spec.f)) is defined for $T but its argument " *
        "types are more specific than the contract requires — " *
        "contract: $(spec.description). Widen the implementation's " *
        "argument types to match, or tighten the contract."
    return nothing
end

# Shared by check_contract/satisfies: infer `spec.f`'s return type for `sig`,
# widening to a Union across all applicable methods (mirrors Base.return_types).
function _inferred_return_type(spec::MethodSpec, sig)
    inferred_rts = Base.return_types(spec.f, sig)
    return isempty(inferred_rts) ? Union{} :
        length(inferred_rts) == 1 ? inferred_rts[1] :
        Union{inferred_rts...}
end

# Check one mandatory spec against `T`. Returns `nothing` on success, else an
# error line naming the requiring type `required_by` (an abstract type or interface).
# With `return_types = false` only method existence is checked, and no inference runs.
# Type parameters are resolved from `params` (see `_substitute`).
function _check_spec(
        T::Type, spec::MethodSpec, required_by::Type; return_types::Bool = true, params = T
    )
    sig = _build_sig(spec.arg_types, T, params)
    if !hasmethod(spec.f, sig)
        _warn_if_more_specific(spec, T)
        return "  $(spec.description)  [required by $required_by]"
    end
    return_types || return nothing
    expected_rt = _resolve_rt_spec(T, spec, params)
    expected_rt === Any && return nothing
    inferred_rt = _inferred_return_type(spec, sig)
    inferred_rt <: expected_rt && return nothing
    return "  $(spec.description) — return $(inferred_rt) ⊄ $(expected_rt)  [required by $required_by]"
end

"""
    check_contract(T::Type) -> NamedTuple{(:type, :contracts, :passed)}

Verify that `T` satisfies all **mandatory** contracts for its supertype chain.
Checks both method existence and declared return types (via Julia's type inferencer).
Optional methods are skipped. Throws `InterfaceError` on failure.

Uses `Base.return_types` internally. Do not call from functions that run at
binary runtime — use `@verify` / `@verify_all` at module top level instead,
where the trimmer eliminates it before the binary is produced.
"""
check_contract(T::Type) = _check_contract(T, true)

function _check_contract(T::Type, return_types::Bool)
    errors = String[]
    checked = Type[]

    for S in supertypes(T)
        specs = _contract_specs(_registry_key(S))
        isempty(specs) && continue
        push!(checked, _registry_key(S))
        for spec in specs
            spec.optional && continue
            err = _check_spec(T, spec, S; return_types)
            isnothing(err) || push!(errors, err)
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
    check_contract(T::Type, I::Type) -> NamedTuple{(:type, :contracts, :passed)}

Structural variant: verify that `T` satisfies the mandatory contract for `I` without
requiring `T <: I`. Useful for structural (Holy Trait) protocols where the implementing
type does not and cannot subtype the interface type.

For a parametric interface, pass its parameters (`check_contract(T, I{Int})`): when `T`
does not subtype `I`, they are taken from `I`, and a bare `I` resolves them to `Any`.

Throws `InterfaceError` on failure. Uses `Base.return_types` — precompile-time only.
"""
check_contract(T::Type, I::Type) = _check_contract(T, I, true)

# Type parameters come from `T` when it subtypes `I` (bare or with the parameters asked
# for), else from `I` itself.
_param_source(T::Type, I::Type) = T <: I ? T : I

function _check_contract(T::Type, I::Type, return_types::Bool)
    specs = _contract_specs(_registry_key(I))
    isempty(specs) && throw(ArgumentError("no contract registered for $I"))
    errors = String[]
    params = _param_source(T, I)
    for spec in specs
        spec.optional && continue
        err = _check_spec(T, spec, I; return_types, params)
        isnothing(err) || push!(errors, err)
    end
    if !isempty(errors)
        throw(
            InterfaceError(
                "Type $T does not satisfy interface contract $I.\n" *
                    "Missing or incorrect methods:\n" * join(errors, "\n")
            )
        )
    end
    return (type = T, contracts = [_registry_key(I)], passed = true)
end

function _concrete_subtypes(T::Type)
    result = Type[]
    for S in subtypes(T)
        if isabstracttype(S)
            append!(result, _concrete_subtypes(S))
        else
            push!(result, S)
        end
    end
    return result
end

# First registered contract in `T`'s supertype chain, or `nothing`.
function _first_contract(T::Type)
    for S in supertypes(T)
        K = _registry_key(S)
        isempty(_contract_specs(K)) || return K
    end
    return nothing
end

# True when `T`'s type constructor has a sealed `verified_trait(::Type{K}, ::Type{X})`
# method, for a concrete instance `X` or for the bare name itself (as sealed by
# `@delegate` on a parametric wrapper).
function _has_verified_instance(T::Type)
    name = Base.unwrap_unionall(T).name
    for m in methods(verified_trait)
        sig = Base.unwrap_unionall(m.sig)
        p = sig.parameters[3]
        p isa DataType && p <: Type || continue
        X = p.parameters[1]
        X isa DataType && isconcretetype(X) && X.name === name && return true
        X isa UnionAll && Base.unwrap_unionall(X).name === name && return true
    end
    return false
end

# Concrete types that `mod` sealed in `verified_trait`, by `@verify T` (including an
# instance such as `@verify Bucket{Int}`), `@verify_all` or `@delegate`. The seals are
# methods, so unlike a registry they survive precompilation.
function _sealed_types(mod::Module)
    result = Type[]
    for m in methods(verified_trait)
        m.module === mod || continue
        p = Base.unwrap_unionall(m.sig).parameters[3]
        p isa DataType && p <: Type || continue
        X = p.parameters[1]
        X isa DataType && isconcretetype(X) && !(X in result) && push!(result, X)
    end
    return result
end

# Example value for a type parameter in the skip warning: a common type within the
# parameter's bounds, else a concrete subtype of its upper bound.
function _example_param(v::TypeVar)
    for (C, s) in ((Int, "Int"), (Float64, "Float64"), (String, "String"), (Symbol, "Symbol"))
        v.lb <: C <: v.ub && return s
    end
    v.ub isa Type && for C in _concrete_subtypes(v.ub)
        v.lb <: C && return string(C)
    end
    return "<a concrete subtype of $(v.ub)>"
end

function _example_instance(T::UnionAll)
    vars = TypeVar[]
    U = T
    while U isa UnionAll
        push!(vars, U.var)
        U = U.body
    end
    return "$(U.name.name){" * join(map(_example_param, vars), ", ") * "}"
end

# A contract can be fully checked only against a concrete type. A bare parametric
# name (`Bucket` for `struct Bucket{T}`) is a `UnionAll`: its type parameters resolve
# to `Any`, so return types cannot be checked against it. Such types are not sealed.
# With a `context` (the calling form, for the message), the bare name is still checked
# for method existence, so a missing method throws, and the skip is reported unless
# some instance has already been verified. No return-type inference runs on the bare
# name: inferring at `Any` parameters reports false mismatches.
function _is_checkable(T::Type, context::Union{String, Nothing})
    isconcretetype(T) && return true
    if !isnothing(context)
        _check_contract(T, false)
        if !_has_verified_instance(T)
            name = Base.unwrap_unionall(T).name.name
            @warn """$context skipped $name: it is parametric, and its contract can only be
            checked for concrete parameters.
            To check it, add `@verify` for each instance your code uses, before `@verify_all`:
                @verify $(_example_instance(T))
            Any verified instance also silences this warning. If the contract does not depend
            on the parameter, one representative instance is enough.""" type = T contract = _first_contract(T)
        end
    end
    return false
end

# Types defined in `mod`, under any binding name, that carry a registered contract.
function _module_contract_types(mod::Module)
    result = Type[]
    for name in names(mod; all = true)
        isdefined(mod, name) || continue
        val = getfield(mod, name)
        val isa DataType || val isa UnionAll || continue
        isabstracttype(val) && continue
        # A parametric `Union` alias (`const U{T} = Union{A{T}, B{T}}`) is a `UnionAll`
        # whose body is not a `DataType`, and has no `parentmodule`.
        Base.unwrap_unionall(val) isa DataType || continue
        parentmodule(val) === mod || continue
        val in result && continue
        isnothing(_first_contract(val)) && continue
        push!(result, val)
    end
    return result
end

# The subset of `_module_contract_types(mod)` that can be checked and sealed.
_contract_types_in_module(mod::Module, context::Union{String, Nothing}) =
    filter(T -> _is_checkable(T, context), _module_contract_types(mod))

"""
    contract_signatures(mod::Module; optional = false) -> Vector{NamedTuple}

List the resolved signature of every contract method, for each concrete type in `mod`
that `@verify_all` would check, and for each instance of a parametric type that `mod`
verified, such as `@verify Bucket{Int}`. Bare parametric names are left out (see
[`@verify_all`](@ref)). Each entry is

    (f, sig, return_type, T, contract, mandatory)

with one entry per `(T, contract in supertypes(T), method)`. `sig` is the
`Tuple{…}` with `Self` and type parameters resolved against `T`, and `return_type`
is the declared return type resolved the same way (`Any` when none is declared).
Both are exactly what [`check_contract`](@ref) checks, so `hasmethod(f, sig)` and
`Base.return_types(f, sig)` apply directly. Optional methods are included only with
`optional = true`.

Dev/precompile-time only: reads `names`, `supertypes` and the contract registry, and
is not `juliac --trim` safe.
"""
function contract_signatures(mod::Module; optional::Bool = false)
    entries = @NamedTuple{
        f::Function, sig::Type{<:Tuple}, return_type::Type,
        T::Type, contract::Type, mandatory::Bool,
    }[]
    types = _contract_types_in_module(mod, nothing)
    for T in _sealed_types(mod)
        T in types || push!(types, T)
    end
    for T in types
        for S in supertypes(T)
            K = _registry_key(S)
            for spec in _contract_specs(K)
                spec.optional && !optional && continue
                push!(
                    entries, (
                        f = spec.f, sig = _build_sig(spec.arg_types, T),
                        return_type = _resolve_rt_spec(T, spec),
                        T = T, contract = K, mandatory = !spec.optional,
                    )
                )
            end
        end
    end
    return entries
end

# The check run by `@verify T` (`I === nothing`) and `@verify T for_contract=I`. A bare
# parametric name is checked for method existence only, as in `_is_checkable`.
_verify_check(T::Type, ::Nothing) = _check_contract(T, !(T isa UnionAll))
_verify_check(T::Type, I::Type) = _check_contract(T, I, !(T isa UnionAll))

function _verify_subtypes(T::Type, mod::Module; trim_compat::Bool = false)
    candidates = _concrete_subtypes(T)
    # A skipped parametric subtype reports itself, so warn only when there are none.
    isempty(candidates) && @warn "@verify subtypes=true: no concrete subtypes found for $T"
    concrete = filter(S -> _is_checkable(S, "@verify $T subtypes=true"), candidates)
    for S in concrete
        result = check_contract(S)
        _verify_hook(_VERIFY_HOOK, mod, S, result)
        _seal_verified!(mod, S)
        trim_compat && check_trim_compat(S)
    end
    return (type = T, subtypes_checked = concrete, passed = true)
end

# Non-throwing variant used by the Revise extension after live edits. Runs the
# verify hook too (unless `hook = false`, used for bare parametric names, which are
# never sealed); any exception, from the check or the hook, becomes a warning. A bare
# parametric name is checked for method existence only, as in `_is_checkable`.
function _check_contract_warn(mod::Module, T::Type, I = nothing; hook::Bool = true)
    return try
        result = isnothing(I) ? _check_contract(T, isconcretetype(T)) :
            _check_contract(T, I, isconcretetype(T))
        hook && _verify_hook(_VERIFY_HOOK, mod, T, result)
        result
    catch e
        if e isa InterfaceError
            @warn "Contract violation detected by Revise" type = T msg = e.msg
        else
            @warn "Contract re-check failed" type = T exception = (e, catch_backtrace())
        end
    end
end

# Re-check all concrete subtypes of registered contracts in `mod`, warning on failure.
function _revise_check_module(mod::Module)
    for T in _module_contract_types(mod)
        _check_contract_warn(mod, T; hook = isconcretetype(T))
    end
    return
end

"""
    satisfies(T::Type, S::Type) -> NamedTuple

Non-throwing check. Returns `(satisfied, missing_methods, missing_optional)`.
`satisfied` is true when all mandatory methods are present and return types match.

Uses `Base.return_types` — do not call from functions that run at binary runtime.
"""
function satisfies(T::Type, S::Type)
    specs = _contract_specs(_registry_key(S))
    isempty(specs) && return (satisfied = true, missing_methods = String[], missing_optional = String[])

    missing_methods = String[]
    missing_optional = String[]
    params = _param_source(T, S)
    for spec in specs
        sig = _build_sig(spec.arg_types, T, params)
        if !hasmethod(spec.f, sig)
            spec.optional || _warn_if_more_specific(spec, T)
            push!(spec.optional ? missing_optional : missing_methods, spec.description)
        elseif !spec.optional
            expected_rt = _resolve_rt_spec(T, spec, params)
            if expected_rt !== Any
                inferred_rt = _inferred_return_type(spec, sig)
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

Return method specs registered directly for type `T`. A parameterized type such as
`AbstractBag{Int}` gives the contract registered for `AbstractBag`.
"""
function list_contract(T::Type)::Vector{MethodSpec}
    return _contract_specs(_registry_key(T))
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

"""
    implements(T::Type, S::Type; include_optional::Bool=false) -> Bool

Return `true` if `T` satisfies the structural contract for `S` (method existence
and return types). Errors if `S` has no registered contract. Designed for direct
use with `@test`:

```julia
@test implements(Circle, AbstractShape)
@test implements(Circle, AbstractShape; include_optional=true)
```

Pass `include_optional=true` to also require all optional methods.

See also: [`satisfies`](@ref) for the full diagnostic result, [`implements(T)`](@ref)
to check all applicable contracts at once.
"""
function implements(T::Type, S::Type; include_optional::Bool = false)::Bool
    isempty(_contract_specs(_registry_key(S))) &&
        throw(ArgumentError("no contract registered for $S"))
    r = satisfies(T, S)
    include_optional || return r.satisfied
    return r.satisfied && isempty(r.missing_optional)
end

"""
    implements(T::Type; include_optional::Bool=false) -> Bool

Return `true` if `T` satisfies all contracts in its supertype chain. Errors if
no contracts are found (likely a wrong type or a missing `@contract` call):

```julia
@test implements(Circle)
@test implements(Circle; include_optional=true)
```

Pass `include_optional=true` to also require all optional methods across every
applicable contract.

See also: [`implements(T, S)`](@ref) for a single contract, [`check_contract`](@ref)
for the compile-time throwing version.
"""
function implements(T::Type; include_optional::Bool = false)::Bool
    applicable_contracts = Type[]
    for S in supertypes(T)
        isempty(_contract_specs(_registry_key(S))) || push!(applicable_contracts, S)
    end
    isempty(applicable_contracts) &&
        throw(ArgumentError("no contracts registered for any supertype of $T"))
    for S in applicable_contracts
        implements(T, S; include_optional) || return false
    end
    return true
end
