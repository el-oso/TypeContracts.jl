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

"""
    check_trim_compat(T::Type, I::Type) -> NamedTuple{(:type, :contracts, :issues, :passed)}

Structural variant of [`check_trim_compat`](@ref): scan the typed IR of each mandatory
method of contract `I` implemented by `T`, without requiring `T <: I`. Useful for
structural (Holy Trait) protocols where user types never subtype the interface type —
`check_trim_compat(T)` is a no-op in that case because `I` is absent from `supertypes(T)`.

Emits `@warn` for each finding; does not throw. Call after `check_contract(T, I)` so
method existence is already guaranteed.
"""
function check_trim_compat(T::Type, I::Type)
    specs = _contract_specs(_registry_key(I))
    isempty(specs) && return (
        type = T, contracts = Type[], issues = Dict{Type, Vector{String}}(), passed = true,
    )
    contract_issues = String[]
    for spec in specs
        spec.optional && continue
        sig = _build_sig(spec.arg_types, T)
        hasmethod(spec.f, sig) || continue
        for issue in _trim_issues(spec.f, sig)
            push!(contract_issues, "  $(spec.description): $issue (trim-unsafe)")
        end
    end
    issues_by_contract = Dict{Type, Vector{String}}()
    if !isempty(contract_issues)
        issues_by_contract[_registry_key(I)] = contract_issues
        @warn "Trim-compatibility issues in $T (contract $I):\n" *
            join(contract_issues, "\n")
    end
    return (
        type = T,
        contracts = collect(keys(issues_by_contract)),
        issues = issues_by_contract,
        passed = isempty(contract_issues),
    )
end

# ── Proactive entry-point scan (trim_report) ──────────────────────────────────
#
# A fast, *advisory* pre-build check: scan the optimized+typed IR of an entry function
# for the patterns juliac --trim=safe rejects, so the developer gets a readable warning
# before the slow juliac run. juliac remains authoritative; this is a heuristic and may
# miss issues (it doesn't replicate juliac's whole-program verifier) — so consumers
# should warn, not hard-fail, on its findings.

"""
    TrimReport(entry, findings, passed)

Result of [`trim_report`](@ref): `entry` describes the scanned function, `findings` are
human-readable likely-trim-unsafe sites (empty when clean), and `passed` is their absence.
`TrimReport <: Exception` so it can be thrown with a styled `showerror` when desired.
"""
struct TrimReport <: Exception
    entry::String
    findings::Vector{String}
    passed::Bool
end

_trim_truncate(s::AbstractString, n::Int = 140) =
    length(s) > n ? string(first(s, n), " …") : String(s)

# High-confidence dynamic-dispatch detection from optimized typed IR: a `:call` whose
# inferred result type is `Any` is exactly what juliac reports as "unresolved call …::Any".
# Resolved calls are lowered to `:invoke`; builtins/intrinsics with concrete results are
# not flagged. Also catches the reflection callees in `_TRIM_UNSAFE_CALLEES`.
function _dynamic_call_issues(f, @nospecialize(sig::Type{<:Tuple}))::Vector{String}
    # Reflection callees (return_types/invokelatest/which/methods) — handles both
    # :call and :invoke forms via the shared scanner.
    issues = copy(_trim_issues(f, sig))
    local results
    try
        results = Base.code_typed(f, sig; optimize = true)
    catch
        return unique!(issues)
    end
    isempty(results) && return unique!(issues)
    (ci, _rt) = first(results)
    types = ci.ssavaluetypes
    has_types = types isa AbstractVector
    # Dynamic dispatch: a :call whose result inferred to `Any` — exactly juliac's
    # "unresolved call …::Any". Resolved calls are :invoke; concrete builtins aren't Any.
    for (i, stmt) in enumerate(ci.code)
        isa(stmt, Expr) || continue
        stmt.head === :call || continue
        _is_trim_unsafe_callee(stmt.args[1]) && continue   # already covered above
        t = (has_types && i <= length(types)) ? types[i] : nothing
        t === Any && push!(issues, "dynamic dispatch (result inferred as `Any`): " *
                                    _trim_truncate(string(stmt)))
    end
    return unique!(issues)
end

"""
    trim_report(f, sig::Type{<:Tuple}) -> TrimReport

Statically scan the optimized, type-inferred IR of `f` called with argument tuple-type
`sig` for patterns `juliac --trim=safe` rejects — dynamic dispatch (a call whose result
infers to `Any`) and reflection (`return_types`, `invokelatest`, `which`, `methods`).

This is a fast, **advisory** pre-build check, not a substitute for juliac's verifier:
it inspects one function's IR (after inlining, so many transitive issues surface) but
does not run the whole-program trim analysis. Treat findings as warnings.

```julia
trim_report(myfunc, Tuple{Int64})          # → TrimReport(...; passed=true/false)
```
"""
function trim_report(f, @nospecialize(sig::Type{<:Tuple}))
    entry = string(nameof(f), "(", join(sig.parameters, ", "), ")")
    findings = _dynamic_call_issues(f, sig)
    return TrimReport(entry, findings, isempty(findings))
end

function Base.showerror(io::IO, r::TrimReport)
    printstyled(io, "TrimReport"; bold = true, color = r.passed ? :green : :red)
    if r.passed
        print(io, ": ", r.entry, " — no obvious trim-unsafe sites found.")
        return
    end
    print(io, ": ")
    printstyled(io, r.entry; color = :cyan, bold = true)
    println(io, " has ", length(r.findings),
            " likely trim-unsafe site(s) (juliac --trim=safe is authoritative):")
    for f in r.findings
        printstyled(io, "  ✗ "; color = :red)
        printstyled(io, f; color = :yellow)
        println(io)
    end
    printstyled(io, "  → make these calls statically resolvable (concrete types; avoid " *
                    "`Any`/abstract containers and runtime reflection).";
                color = :green)
    return
end
