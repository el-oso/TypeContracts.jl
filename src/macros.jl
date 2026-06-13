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

**Auto-generation:** if the abstract type or any unqualified function name is not
yet defined in the calling module, `@contract` defines it automatically. This means
the common boilerplate (`abstract type T end`, `function f end`) is no longer
required. Define the abstract type explicitly beforehand only when you need a
supertype constraint (e.g. `abstract type Animal <: LivingThing end`).

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
    return _build_contract_expr(__module__, T_expr, "", block)
end

macro contract(T_expr, desc, block)
    desc isa String ||
        error("@contract: interface description must be a string literal, got: $desc")
    return _build_contract_expr(__module__, T_expr, desc, block)
end

function _build_contract_expr(mod::Module, T_expr, desc::String, block)
    block isa Expr && block.head == :block ||
        error("@contract requires a begin...end block")

    abstract_sym, type_vars = _parse_contract_header(T_expr)

    parsed = _parse_block(block)

    # Auto-generate abstract type stub if not already defined in the calling module.
    type_stub = isdefined(mod, abstract_sym) ? nothing :
        :(abstract type $(esc(T_expr)) end)

    # Auto-generate function stubs for unqualified names not yet defined.
    # Qualified names (Base.length, etc.) are skipped — they already exist.
    func_stubs = Expr[
        :(function $(esc(fname)) end)
            for (fname, _, _, _, _) in parsed
            if fname isa Symbol && !isdefined(mod, fname)
    ]

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
        $(isnothing(type_stub) ? :() : type_stub)
        $(func_stubs...)
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
    @verify ConcreteType trim_compat=true

Assert at module-load / precompile time that `ConcreteType` satisfies all
mandatory contracts for its supertype chain. Checks both method existence
and declared return types (via `Base.return_types`).

**juliac / trim binaries:** `@verify` at module top level is safe. It runs
during Julia's precompilation step (before the native binary is produced) and
is not re-executed at binary runtime. The trimmer eliminates it automatically
because it is unreachable from any entry point. Do not call `@verify` (or
`check_contract`) inside a function that runs at binary runtime — that would
embed a `Base.return_types` call in the runtime call graph.

With `trim_compat=true`, also runs `check_trim_compat(ConcreteType)` to scan
the typed IR of each mandatory method for known trim-unsafe calls
(`Base.return_types`, `invokelatest`, etc.) and emits `@warn` for any found.
This is a shallow, heuristic check — use `TrimCheck.@validate` for exhaustive
verification.

Must be placed after all method definitions for the type.
"""
macro verify(T, kwargs...)
    trim_compat = false
    for kw in kwargs
        if kw isa Expr && kw.head === :(=) && kw.args[1] === :trim_compat
            trim_compat = kw.args[2]
        end
    end
    return quote
        let _verify_result = TypeContracts.check_contract($(esc(T)))
            push!(TypeContracts._revise_tracked_types, $(esc(T)))
            $(trim_compat) && TypeContracts.check_trim_compat($(esc(T)))
            _verify_result
        end
    end
end

"""
    @verify_all
    @verify_all trim_compat=true

Assert at module-load / precompile time that **every** concrete subtype
of a registered contract type, defined in the calling module, satisfies
its mandatory contracts.

Place once at the end of your module, after all type and method definitions.
Replaces the need for individual `@verify T` calls.

With `trim_compat=true`, also runs `check_trim_compat` on each type (see
`@verify` for details on what is checked).

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
macro verify_all(kwargs...)
    trim_compat = false
    for kw in kwargs
        if kw isa Expr && kw.head === :(=) && kw.args[1] === :trim_compat
            trim_compat = kw.args[2]
        end
    end
    return quote
        let _r = TypeContracts._verify_all_in_module(@__MODULE__; trim_compat = $(trim_compat))
            push!(TypeContracts._revise_tracked_modules, @__MODULE__)
            _r
        end
    end
end

function _verify_all_in_module(mod::Module; trim_compat::Bool = false)
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
        trim_compat && check_trim_compat(val)
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

# ── @contract parsing internals ───────────────────────────────────────

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

# ── @delegate internals ───────────────────────────────────────────────

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
