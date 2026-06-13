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

# Non-throwing variant used by the Revise extension after live edits.
function _check_contract_warn(T::Type)
    return try
        check_contract(T)
    catch e
        e isa InterfaceError &&
            @warn "Contract violation detected by Revise" type = T msg = e.msg
    end
end

# Re-check all concrete subtypes of registered contracts in `mod`, warning on failure.
function _revise_check_module(mod::Module)
    for name in names(mod; all = true)
        isdefined(mod, name) || continue
        val = getfield(mod, name)
        val isa Type || continue
        isabstracttype(val) && continue
        parentmodule(val) === mod || continue
        any(S -> !isempty(_contract_specs(_registry_key(S))), supertypes(val)) || continue
        _check_contract_warn(val)
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
