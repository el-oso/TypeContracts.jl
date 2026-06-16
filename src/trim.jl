# Functions whose presence in a method body signals juliac --trim incompatibility.
const _TRIM_UNSAFE_CALLEES = Any[
    Base.return_types,
    Base.invokelatest,
    Base.which,
    Base.methods,
]

# In unoptimized CodeInfo, callees are usually GlobalRef, not function objects.
# Resolve a GlobalRef to its value and check membership.
function _is_trim_unsafe_callee(callee)::Bool
    callee in _TRIM_UNSAFE_CALLEES && return true
    if callee isa GlobalRef
        try
            return getproperty(callee.mod, callee.name) in _TRIM_UNSAFE_CALLEES
        catch
        end
    end
    return false
end

function _callee_str(callee)::String
    return callee isa GlobalRef ? "$(callee.mod).$(callee.name)" : string(callee)
end

function _scan_trim_stmt!(issues::Vector{String}, stmt)
    isa(stmt, Expr) || return
    if stmt.head === :call
        callee = stmt.args[1]
        if _is_trim_unsafe_callee(callee)
            push!(issues, "dynamic dispatch to $(_callee_str(callee))")
        end
    elseif stmt.head === :invoke
        # In optimized IR, :invoke args are: (MethodInstance, callee, arg...)
        # Keyword functions pass the wrapped fn as a plain argument; scan all args.
        for arg in stmt.args
            if arg in _TRIM_UNSAFE_CALLEES || _is_trim_unsafe_callee(arg)
                push!(issues, "static call to $(_callee_str(arg))")
            end
        end
    end
    for arg in stmt.args
        isa(arg, Expr) && _scan_trim_stmt!(issues, arg)
    end
    return
end

function _trim_issues(f, sig::Type{<:Tuple})::Vector{String}
    issues = String[]
    try
        # optimize=true: keyword fns pass the wrapped fn as a concrete arg in :invoke
        results = Base.code_typed(f, sig; optimize = true)
        isempty(results) && return issues
        (code_info, _) = first(results)
        for stmt in code_info.code
            _scan_trim_stmt!(issues, stmt)
        end
    catch
        # IR introspection unavailable (builtin, C function) — skip silently
    end
    return issues
end

"""
    check_trim_compat(T::Type) -> NamedTuple{(:type, :contracts, :issues, :passed)}

Precompile-time check that inspects the typed IR of each mandatory contract method
for `T` and warns if any known trim-unsafe functions are called directly in the method
body (e.g. `Base.return_types`, `invokelatest`, `Base.which`).

This is a **shallow, heuristic** scan — it detects obvious reflection in the top-level
method body but does not recurse into callees. Use `TrimCheck.@validate` for exhaustive
trim verification.

Emits `@warn` for each finding; does not throw. Call after `check_contract` or
`@verify` so method existence is already guaranteed.
"""
function check_trim_compat(T::Type)
    issues_by_contract = Dict{Type, Vector{String}}()
    all_clean = true

    for S in supertypes(T)
        specs = _contract_specs(_registry_key(S))
        isempty(specs) && continue
        contract_issues = String[]
        for spec in specs
            spec.optional && continue
            sig = _build_sig(spec.arg_types, T)
            hasmethod(spec.f, sig) || continue
            found = _trim_issues(spec.f, sig)
            for issue in found
                push!(contract_issues, "  $(spec.description): $issue (trim-unsafe)")
                all_clean = false
            end
        end
        if !isempty(contract_issues)
            issues_by_contract[_registry_key(S)] = contract_issues
            @warn "Trim-compatibility issues in $T (contract $S):\n" *
                join(contract_issues, "\n")
        end
    end

    return (
        type = T,
        contracts = collect(keys(issues_by_contract)),
        issues = issues_by_contract,
        passed = all_clean,
    )
end
