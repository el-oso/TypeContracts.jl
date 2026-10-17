# Shared by check_contract/satisfies: warn when `spec.f` has a method for `T` whose
# argument types are more specific than the contract's (so `hasmethod` on the exact
# contract signature fails even though an implementation clearly exists).
function _warn_if_more_specific(spec::MethodSpec, T::Type)
    isempty(methods(spec.f, Tuple{T, Vararg{Any}})) && return nothing
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
function _check_spec(T::Type, spec::MethodSpec, required_by::Type)
    sig = _build_sig(spec.arg_types, T)
    if !hasmethod(spec.f, sig)
        _warn_if_more_specific(spec, T)
        return "  $(spec.description)  [required by $required_by]"
    end
    expected_rt = _resolve_rt_spec(T, spec)
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
function check_contract(T::Type)
    errors = String[]
    checked = Type[]

    for S in supertypes(T)
        specs = _contract_specs(_registry_key(S))
        isempty(specs) && continue
        push!(checked, _registry_key(S))
        for spec in specs
            spec.optional && continue
            err = _check_spec(T, spec, S)
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

Throws `InterfaceError` on failure. Uses `Base.return_types` — precompile-time only.
"""
function check_contract(T::Type, I::Type)
    specs = _contract_specs(_registry_key(I))
    isempty(specs) && throw(ArgumentError("no contract registered for $I"))
    errors = String[]
    for spec in specs
        spec.optional && continue
        err = _check_spec(T, spec, I)
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
# `@delegate` on a parametric wrapper or an explicit `@verify` of the bare name).
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

# A contract can be checked only against a concrete type. A bare parametric name
# (`Bucket` for `struct Bucket{T}`) is a `UnionAll`: its type parameters resolve to
# `Any`, so return types would go unchecked. Such types are skipped; with a
# `context` (the calling form, for the message) the skip is reported unless some
# concrete instance has already been verified.
function _is_checkable(T::Type, context::Union{String, Nothing})
    isconcretetype(T) && return true
    if !isnothing(context) && !_has_verified_instance(T)
        body = Base.unwrap_unionall(T)
        name = body.name.name
        ex = "$name{" * join(fill("Int", length(body.parameters)), ", ") * "}"
        @warn """$context skipped $name: it is parametric, and its contract can only be
        checked for concrete parameters.
        To check it, add `@verify` for each instance your code uses, before `@verify_all`:
            @verify $ex
        Any verified instance also silences this warning. If the contract does not depend
        on the parameter, one representative instance is enough.""" type = T contract = _first_contract(T)
    end
    return false
end

# Types defined in `mod` that carry a registered contract and can be checked.
function _contract_types_in_module(mod::Module, context::Union{String, Nothing})
    result = Type[]
    for name in names(mod; all = true)
        isdefined(mod, name) || continue
        val = getfield(mod, name)
        val isa Type || continue
        isabstracttype(val) && continue
        parentmodule(val) === mod || continue
        isnothing(_first_contract(val)) && continue
        val in result && continue
        _is_checkable(val, context) || continue
        push!(result, val)
    end
    return result
end

"""
    contract_signatures(mod::Module; optional = false) -> Vector{NamedTuple}

List the resolved signature of every contract method, for each concrete type in `mod`
that `@verify_all` would check (see [`@verify_all`](@ref): bare parametric names are
left out). Each entry is

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
    for T in _contract_types_in_module(mod, nothing)
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

function _verify_subtypes(T::Type, mod::Module; trim_compat::Bool = false)
    concrete = filter(S -> _is_checkable(S, "@verify $T subtypes=true"), _concrete_subtypes(T))
    isempty(concrete) && @warn "@verify subtypes=true: no concrete subtypes found for $T"
    for S in concrete
        result = check_contract(S)
        _verify_hook(_VERIFY_HOOK, mod, S, result)
        _seal_verified!(mod, S)
        trim_compat && check_trim_compat(S)
    end
    return (type = T, subtypes_checked = concrete, passed = true)
end

# Non-throwing variant used by the Revise extension after live edits. Runs the
# verify hook too; any exception, from the check or the hook, becomes a warning.
function _check_contract_warn(mod::Module, T::Type)
    return try
        result = check_contract(T)
        _verify_hook(_VERIFY_HOOK, mod, T, result)
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
    for T in _contract_types_in_module(mod, nothing)
        _check_contract_warn(mod, T)
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
    for spec in specs
        sig = _build_sig(spec.arg_types, T)
        if !hasmethod(spec.f, sig)
            spec.optional || _warn_if_more_specific(spec, T)
            push!(spec.optional ? missing_optional : missing_methods, spec.description)
        elseif !spec.optional
            expected_rt = _resolve_rt_spec(T, spec)
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
