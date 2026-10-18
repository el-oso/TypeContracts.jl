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
    # A qualified name refers to a type defined elsewhere, so it gets no stub.
    type_stub = abstract_sym isa Symbol && !isdefined(mod, abstract_sym) ?
        :(abstract type $(esc(T_expr)) end) : nothing

    # Auto-generate function stubs for unqualified names not yet defined.
    # Qualified names (Base.length, etc.) are skipped — they already exist.
    func_stubs = Expr[
        :(function $(esc(fname)) end)
            for (fname, _, _, _, _) in parsed
            if fname isa Symbol && !isdefined(mod, fname)
    ]

    spec_exprs = Expr[]
    # For the generated `interface_trait` method: argument-type markers and the function
    # object for each *mandatory* method. `_build_trait_expr` consumes these at
    # specialization time, resolving `Self`/`TypeParamRef` against the concrete type.
    trait_arg_lists = Expr[]
    trait_fns = Any[]

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

        if !opt
            push!(trait_arg_lists, :(Any[$(aexprs...)]))
            push!(trait_fns, esc(fname))
        end
    end

    # `interface_trait` for this interface is a `@generated` method emitted by `@contract`
    # (not a Dict mutation): being a method definition, it is serialized into the
    # registering package's precompile cache and survives reloads, and it dispatches under
    # the caller's world age. The generator runs at specialization time with the concrete
    # type `T` bound, so `_build_trait_expr` bakes in concrete `hasmethod(f, Tuple{…})`
    # calls — no runtime registry lookup, trim-safe for both plain and parametric contracts.
    trait_method = :(
        @generated function TypeContracts.interface_trait(::Type{$(esc(abstract_sym))}, ::Type{T}) where {T}
            return TypeContracts._build_trait_expr(
                $(esc(abstract_sym)), T, Any[$(trait_arg_lists...)], Any[$(trait_fns...)]
            )
        end
    )

    return quote
        $(isnothing(type_stub) ? :() : type_stub)
        $(func_stubs...)
        isabstracttype($(esc(abstract_sym))) ||
            error("@contract requires an abstract type, got $($(esc(abstract_sym)))")
        TypeContracts._check_header($(esc(abstract_sym)), $(length(type_vars)))
        TypeContracts._check_reregistration(
            TypeContracts._contract_specs, $(esc(abstract_sym)), "@contract", "contract"
        )
        function TypeContracts._contract_specs(::Type{$(esc(abstract_sym))})
            return TypeContracts.MethodSpec[$(spec_exprs...)]
        end
        $trait_method
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
    @verify AbstractType subtypes=true
    @verify AbstractType subtypes=true trim_compat=true
    @verify ConcreteType for_contract=InterfaceType
    @verify ConcreteType for_contract=InterfaceType trim_compat=true

Assert at module-load / precompile time that a type satisfies all mandatory
contracts for its supertype chain. Checks both method existence and declared
return types (via `Base.return_types`).

**juliac / trim binaries:** `@verify` at module top level is safe. It runs
during Julia's precompilation step (before the native binary is produced) and
is not re-executed at binary runtime. The trimmer eliminates it automatically
because it is unreachable from any entry point. Do not call `@verify` (or
`check_contract`) inside a function that runs at binary runtime — that would
embed a `Base.return_types` call in the runtime call graph.

With `trim_compat=true`, also runs `check_trim_compat` to scan the typed IR
of each mandatory method for known trim-unsafe calls (`Base.return_types`,
`invokelatest`, etc.) and emits `@warn` for any found. This is a shallow,
heuristic check — use `TrimCheck.@validate` for exhaustive verification.

With `subtypes=true`, verifies every concrete subtype of the given abstract
type rather than the type itself. Equivalent to calling `@verify` on each
concrete subtype individually, and self-maintaining as new subtypes are added.

With `for_contract=I`, performs a **structural** check against the contract
registered for `I` without requiring `T <: I`. Useful for Holy Trait / structural
protocols where user types satisfy a contract's method signatures but do not and
cannot subtype the interface type. Combining with `trim_compat=true` also checks
that `T`'s implementations of `I`'s methods are juliac `--trim` compatible.

Option values may be literals or names in the calling module, except `subtypes`,
which must be the literal `true` or `false`. Any other option name is an error.

A bare parametric name (`@verify Bucket` for `struct Bucket{T}`) is checked for
method existence only, since its type parameters are unknown; return types are
checked by `@verify Bucket{Int}`.

Must be placed after all type and method definitions.
"""
macro verify(T, kwargs...)
    trim_compat = false
    check_subtypes = false
    for_contract = nothing
    for kw in kwargs
        if kw isa Expr && kw.head === :(=)
            if kw.args[1] === :trim_compat
                trim_compat = esc(kw.args[2])
            elseif kw.args[1] === :subtypes
                check_subtypes = kw.args[2]
                check_subtypes isa Bool ||
                    error("@verify: subtypes must be true or false, got $check_subtypes")
            elseif kw.args[1] === :for_contract
                for_contract = kw.args[2]
            else
                _unknown_option("@verify", kw)
            end
        else
            _unknown_option("@verify", kw)
        end
    end
    if check_subtypes
        return :(TypeContracts._verify_subtypes($(esc(T)), @__MODULE__; trim_compat = $(trim_compat)))
    end
    if !isnothing(for_contract)
        return quote
            let _verify_result = TypeContracts._verify_check($(esc(T)), $(esc(for_contract)))
                push!(TypeContracts._revise_tracked_types, (@__MODULE__, $(esc(T)), $(esc(for_contract))))
                TypeContracts._verify_hook(TypeContracts._VERIFY_HOOK, @__MODULE__, $(esc(T)), _verify_result)
                TypeContracts._seal_verified_checked!(@__MODULE__, $(esc(T)), $(esc(for_contract)))
                $(trim_compat) && TypeContracts.check_trim_compat($(esc(T)), $(esc(for_contract)))
                _verify_result
            end
        end
    end
    return quote
        let _verify_result = TypeContracts._verify_check($(esc(T)), nothing)
            push!(TypeContracts._revise_tracked_types, (@__MODULE__, $(esc(T)), nothing))
            TypeContracts._verify_hook(TypeContracts._VERIFY_HOOK, @__MODULE__, $(esc(T)), _verify_result)
            TypeContracts._seal_verified_checked!(@__MODULE__, $(esc(T)), nothing)
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
# Contracts are looked up by type name (`_registry_key`), so one registered on an alias
# (`AbstractVector`, which is `AbstractArray{T,1} where T`) would never be found. A
# header parameter past the type's own would resolve to `Any` at every check.
function _check_header(@nospecialize(T), n::Int)
    K = _registry_key(T)
    K === T || error(
        "@contract: $T is an alias of $K; register the contract on $K, " *
            "the type that subtypes are checked against"
    )
    available = length(Base.unwrap_unionall(T).parameters)
    n <= available || error(
        "@contract: the header names $n type parameters, but $T has $available"
    )
    return nothing
end

function _unknown_option(macro_name::String, kw)
    kw isa Expr && kw.head === :(=) ||
        error("$macro_name: options are written `name = value`, got `$kw`")
    valid = macro_name == "@verify" ? "trim_compat, subtypes, for_contract" : "trim_compat"
    return error("$macro_name: unknown option `$(kw.args[1])`; valid options are $valid")
end

macro verify_all(kwargs...)
    trim_compat = false
    for kw in kwargs
        if kw isa Expr && kw.head === :(=) && kw.args[1] === :trim_compat
            trim_compat = esc(kw.args[2])
        else
            _unknown_option("@verify_all", kw)
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
    checked = _contract_types_in_module(mod, "@verify_all")
    for T in checked
        result = check_contract(T)
        _verify_hook(_VERIFY_HOOK, mod, T, result)
        _seal_verified!(mod, T)
        trim_compat && check_trim_compat(T)
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

Invariants registered for a parameterized type, such as `AbstractBag{Int}`, apply
to the subtypes of that type only; those registered for `AbstractBag` apply to all
of its subtypes.
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
        TypeContracts._check_reregistration(
            TypeContracts._behavior_specs, $(esc(T)), "@invariants", "invariants"
        )
        function TypeContracts._behavior_specs(::Type{$(esc(T))})
            return TypeContracts.BehaviorSpec[$(spec_exprs...)]
        end
        TypeContracts._attach_contract_doc($(esc(T)))
        nothing
    end
end

# ── @contract parsing internals ───────────────────────────────────────

# A type name is a symbol or a qualified name (`Base.AbstractArray`).
_is_type_name(x) = x isa Symbol || (x isa Expr && x.head === :. && length(x.args) == 2)

function _parse_contract_header(expr)
    if _is_type_name(expr)
        return expr, Dict{Symbol, Int}()
    elseif expr isa Expr && expr.head == :curly
        abstract_sym = expr.args[1]
        _is_type_name(abstract_sym) ||
            error("@contract: abstract type name must be a name, got $abstract_sym")
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

# True when `t` mentions `Self` or a contract type parameter.
_mentions_placeholder(t, type_vars) =
    t === :Self || (t isa Symbol && haskey(type_vars, t)) ||
    (t isa Expr && t.head === :curly && any(a -> _mentions_placeholder(a, type_vars), t.args[2:end])) ||
    (_is_bound(t) && _mentions_placeholder(t.args[1], type_vars))

# A bound in a type parameter: `<:X` or `>:X`, as in `Type{<:Self}`.
_is_bound(t) = t isa Expr && t.head in (:<:, :>:) && length(t.args) == 1

# An argument or return type with `Self` and the contract's type parameters replaced:
# a bare `Self` or `T` by `Self` or a `TypeParamRef`, and one nested in `{…}`, such as
# `Vector{T}` or `Type{Self}`, by `Self` or a `_NestedParam`. Other names resolve in the
# calling module.
function _resolve_arg_expr(t, type_vars::Dict{Symbol, Int}, abstract_sym; nested::Bool = false)
    t === :Self && return :(TypeContracts.Self)
    if t isa Symbol && haskey(type_vars, t)
        idx = type_vars[t]
        return nested ? :(TypeContracts._NestedParam{$(esc(abstract_sym)), $idx}) :
            :(TypeContracts.TypeParamRef($(esc(abstract_sym)), $idx))
    end
    if t isa Expr && t.head === :curly && _mentions_placeholder(t, type_vars)
        args = Any[_resolve_arg_expr(a, type_vars, abstract_sym; nested = true) for a in t.args[2:end]]
        return Expr(:curly, esc(t.args[1]), args...)
    end
    nested && _is_bound(t) && _mentions_placeholder(t, type_vars) &&
        return Expr(t.head, _resolve_arg_expr(t.args[1], type_vars, abstract_sym; nested))
    return esc(t)
end

function _resolve_rtype_exprs(rtype, type_vars::Dict{Symbol, Int}, abstract_sym)
    rtype === :Any && return :(Any), :(Any)
    # `Self` and type parameters are resolved at check time, so the display type is `Any`.
    _mentions_placeholder(rtype, type_vars) &&
        return :(Any), _resolve_arg_expr(rtype, type_vars, abstract_sym)
    e = esc(rtype)
    return e, e
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

# The function as `Module.name`, with the module object spliced in, so the caller need
# not have the module's name in scope.
_fn_name_expr(f::Function) = Expr(:., parentmodule(f), QuoteNode(nameof(f)))

# True when `pred` holds for `t` or for any type nested in it.
function _mentions(pred, @nospecialize(t))
    pred(t) && return true
    t isa Core.TypeofVararg && return _mentions(pred, t.T)
    t isa Union && return _mentions(pred, t.a) || _mentions(pred, t.b)
    t isa DataType && return any(p -> _mentions(pred, p), t.parameters)
    t isa UnionAll && return _mentions(pred, t.var) || _mentions(pred, t.body)
    t isa TypeVar && return _mentions(pred, t.lb) || _mentions(pred, t.ub)
    return false
end

_is_nested_param(t) = t isa DataType && t.name === _NestedParam.body.body.name

function _forwarder_expr(wrapper_sym::Symbol, field::Symbol, spec::MethodSpec)
    n = length(spec.arg_types)
    names = [Symbol(:_x, i) for i in 1:n]
    sig_args = Any[]
    fwd_args = Any[]
    for (name, at) in zip(names, spec.arg_types)
        if at === Self
            push!(sig_args, :($name::$(esc(wrapper_sym))))
            push!(fwd_args, :(getfield($name, $(QuoteNode(field)))))
            continue
        end
        _mentions(==(Self), at) && error(
            "@delegate: cannot forward an argument of type " *
                "$(replace(string(at), "TypeContracts." => "")) in `$(spec.description)`: " *
                "only a bare `Self` argument is replaced by the field"
        )
        # Arguments typed by a contract type parameter are forwarded untyped.
        untyped = at isa TypeParamRef || _mentions(_is_nested_param, at)
        if at isa Core.TypeofVararg
            push!(sig_args, untyped ? :($name...) : :($name::$at))
            push!(fwd_args, :($name...))
        else
            push!(sig_args, untyped ? name : :($name::$at))
            push!(fwd_args, name)
        end
    end
    fn_expr = _fn_name_expr(spec.f)
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
- Arguments typed as interface type parameters, alone or inside another type
  (`::T`, `::Vector{T}`), are forwarded untyped (`Any` dispatch).
- Only a bare `::Self` argument is replaced by the field. A method with `Self` inside
  another argument type, such as `::Type{Self}`, cannot be forwarded, and `@delegate`
  throws an error naming it.
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
    push!(
        body, :(
            TypeContracts._verify_hook(
                TypeContracts._VERIFY_HOOK, @__MODULE__, $(esc(wrapper_sym)),
                (type = $(esc(wrapper_sym)), contracts = Type[TypeContracts._registry_key($I_val)], passed = true),
            )
        )
    )
    push!(body, :(TypeContracts._seal_verified!(@__MODULE__, $(esc(wrapper_sym)), $I_val)))
    push!(body, :nothing)
    return Expr(:block, body...)
end
