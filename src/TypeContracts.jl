module TypeContracts

using InteractiveUtils: supertypes, subtypes
using Markdown: Markdown

export @contract, @verify, @verify_all, @invariants,
       check_contract, satisfies, list_contract, registered_contracts,
       test_behavior, list_behaviors, registered_behaviors,
       describe, interface_trait, disable_docs!, enable_docs!,
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
    print(io, s.description)
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
    print(io, b.description)
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

Base.show(io::IO, ::Implemented{I}) where {I}    = print(io, "Implemented{$I}()")
Base.show(io::IO, ::NotImplemented{I}) where {I} = print(io, "NotImplemented{$I}()")

# ── Registries ────────────────────────────────────────────────────────

const _registry     = Dict{Type, Vector{MethodSpec}}()
const _behaviors    = Dict{Type, Vector{BehaviorSpec}}()
const _descriptions = Dict{Type, String}()   # interface-level prose

"""
    registered_contracts() -> Dict{Type, Vector{MethodSpec}}

Return a copy of the global contract registry: every abstract type that has a
registered `@contract`, mapped to its `Vector{MethodSpec}`.
"""
registered_contracts()::Dict{Type, Vector{MethodSpec}}   = copy(_registry)

"""
    registered_behaviors() -> Dict{Type, Vector{BehaviorSpec}}

Return a copy of the global behavior registry: every type that has registered
`@invariants`, mapped to its `Vector{BehaviorSpec}`.
"""
registered_behaviors()::Dict{Type, Vector{BehaviorSpec}} = copy(_behaviors)

# Master switch for `?`-doc integration. Set to `false` (via `disable_docs!()`)
# before registering contracts in a juliac/`--trim` static-compilation context,
# so the `Markdown` + `Base.Docs` machinery is never entered at runtime. The
# structural/runtime path (`interface_trait`) does not touch this regardless.
const _DOCS_ENABLED = Ref(true)

"""
    disable_docs!()

Turn off the `?`-documentation integration. Call before registering contracts
in a statically compiled (juliac `--trim`) binary that runs `@contract` /
`@invariants` from `__init__`, so `Markdown` / `Base.Docs` are not pulled into
the runtime image. Has no effect on `check_contract`, `satisfies`,
`interface_trait`, or `describe`.

See also [`enable_docs!`](@ref).
"""
disable_docs!() = (_DOCS_ENABLED[] = false; nothing)

"""
    enable_docs!()

Re-enable `?`-documentation integration after a call to [`disable_docs!`](@ref).
"""
enable_docs!()  = (_DOCS_ENABLED[] = true;  nothing)

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
    base = ref.abstract_base
    while base isa UnionAll
        base = base.body
    end
    base_name = base.name
    for S in supertypes(concrete_type)
        S isa DataType || continue
        S.name === base_name || continue
        ref.param_index <= length(S.parameters) || return Any
        return S.parameters[ref.param_index]
    end
    Any
end

function _resolve_rt_spec(concrete_type::Type, spec::MethodSpec)
    spec.return_type_spec isa TypeParamRef ?
        _extract_param(concrete_type, spec.return_type_spec) :
        spec.return_type_spec
end

# For parameterized supertypes like AbstractBucket{Int}, return the UnionAll
# wrapper (AbstractBucket) so it matches registry entries from
# @contract AbstractBucket{T} begin ... end
function _registry_key(S::Type)
    S isa DataType && !isempty(S.parameters) && return S.name.wrapper
    S
end

function _build_sig(arg_types::Vector{Any}, T::Type)
    n = length(arg_types)
    resolved = Vector{Type}(undef, n)
    @inbounds for i in 1:n
        at = arg_types[i]
        resolved[i] = at === Self         ? T :
                      at isa TypeParamRef ? _extract_param(T, at) :
                      at
    end
    Tuple{resolved...}
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
    errors  = String[]
    checked = Type[]

    for S in supertypes(T)
        specs = get(_registry, _registry_key(S), nothing)
        isnothing(specs) && continue
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
                    inferred_rt  = isempty(inferred_rts) ? Union{} :
                                   length(inferred_rts) == 1 ? inferred_rts[1] :
                                   Union{inferred_rts...}
                    if !(inferred_rt <: expected_rt)
                        push!(errors,
                            "  $(spec.description) — return $(inferred_rt) ⊄ $(expected_rt)  [required by $S]")
                    end
                end
            end
        end
    end

    if !isempty(errors)
        throw(InterfaceError(
            "Type $T does not satisfy interface contract.\n" *
            "Missing or incorrect methods:\n" *
            join(errors, "\n")
        ))
    end

    (type=T, contracts=checked, passed=true)
end

"""
    satisfies(T::Type, S::Type) -> NamedTuple

Non-throwing check. Returns `(satisfied, missing_methods, missing_optional)`.
`satisfied` is true when all mandatory methods are present and return types match.

Precompile-time tool — uses `Base.return_types` for return type checking.
"""
function satisfies(T::Type, S::Type)
    specs = get(_registry, _registry_key(S), nothing)
    isnothing(specs) && return (satisfied=true, missing_methods=String[], missing_optional=String[])

    missing_methods  = String[]
    missing_optional = String[]
    for spec in specs
        sig = _build_sig(spec.arg_types, T)
        if !hasmethod(spec.f, sig)
            push!(spec.optional ? missing_optional : missing_methods, spec.description)
        elseif !spec.optional
            expected_rt = _resolve_rt_spec(T, spec)
            if expected_rt !== Any
                inferred_rts = Base.return_types(spec.f, sig)
                inferred_rt  = isempty(inferred_rts) ? Union{} :
                               length(inferred_rts) == 1 ? inferred_rts[1] :
                               Union{inferred_rts...}
                if !(inferred_rt <: expected_rt)
                    push!(missing_methods,
                        "$(spec.description) [return: $(inferred_rt) ⊄ $(expected_rt)]")
                end
            end
        end
    end

    (satisfied=isempty(missing_methods), missing_methods=missing_methods, missing_optional=missing_optional)
end

"""
    list_contract(T::Type) -> Vector{MethodSpec}

Return method specs registered directly for type `T`.
"""
function list_contract(T::Type)::Vector{MethodSpec}
    get(_registry, T, MethodSpec[])
end

"""
    list_contract(T::Type, Val(:all)) -> Dict{Type, Vector{MethodSpec}}

Return all contracts applicable to `T` via its supertype chain.
"""
function list_contract(T::Type, ::Val{:all})::Dict{Type, Vector{MethodSpec}}
    result = Dict{Type, Vector{MethodSpec}}()
    for S in supertypes(T)
        key   = _registry_key(S)
        specs = get(_registry, key, nothing)
        !isnothing(specs) && (result[key] = specs)
    end
    result
end

"""
    list_behaviors(T::Type) -> Vector{BehaviorSpec}

Return behavioral invariants registered directly for type `T`.
"""
function list_behaviors(T::Type)::Vector{BehaviorSpec}
    get(_behaviors, T, BehaviorSpec[])
end

# ── Public API: Holy Trait Dispatch ───────────────────────────────────

"""
    interface_trait(::Type{I}, ::Type{T}) -> Implemented{I} | NotImplemented{I}

Check if `T` satisfies the mandatory contract for `I` (method existence only).
Returns a singleton trait type suitable for dispatch.

Juliac-compatible: uses only `hasmethod`, no type inferencer.

# Example
```julia
process(x) = _process(interface_trait(AbstractShape, typeof(x)), x)
_process(::Implemented{AbstractShape}, x) = area(x)
_process(::NotImplemented{AbstractShape}, x) = error("not a shape")
```
"""
function interface_trait(::Type{I}, ::Type{T}) where {I, T}
    specs = get(_registry, _registry_key(I), nothing)
    isnothing(specs) && return NotImplemented{I}()

    for spec in specs
        spec.optional && continue
        sig = _build_sig(spec.arg_types, T)
        hasmethod(spec.f, sig) || return NotImplemented{I}()
    end

    Implemented{I}()
end

# ── Public API: Behavioral Testing ────────────────────────────────────

"""
    test_behavior(T::Type, objects) -> NamedTuple

Run all behavioral invariants registered for `T`'s supertype chain
against `deepcopy`'d test `objects`. Returns `(passed, results, mandatory_failures)`.

`passed` is true when all mandatory invariants hold for all objects.
"""
function test_behavior(::Type{T}, objects) where {T}
    results = NamedTuple{(:type, :description, :passed, :optional, :error),
                         Tuple{Type, String, Bool, Bool, String}}[]

    for S in supertypes(T)
        behaviors = get(_behaviors, _registry_key(S), nothing)
        isnothing(behaviors) && continue
        _run_behaviors!(results, S, behaviors, objects)
    end

    mandatory_failures = filter(r -> !r.passed && !r.optional, results)
    (passed=isempty(mandatory_failures), results=results, mandatory_failures=mandatory_failures)
end

"""
    test_behavior(T::Type, S::Type, objects) -> NamedTuple

Run behavioral invariants registered for `S` specifically against objects of type `T`.
"""
function test_behavior(::Type{T}, ::Type{S}, objects) where {T, S}
    results = NamedTuple{(:type, :description, :passed, :optional, :error),
                         Tuple{Type, String, Bool, Bool, String}}[]

    behaviors = get(_behaviors, S, nothing)
    !isnothing(behaviors) && _run_behaviors!(results, S, behaviors, objects)

    mandatory_failures = filter(r -> !r.passed && !r.optional, results)
    (passed=isempty(mandatory_failures), results=results, mandatory_failures=mandatory_failures)
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
            push!(results, (type=S, description=bspec.description,
                            passed=passed, optional=bspec.optional, error=errmsg))
        end
    end
end

# ── Public API: Describe ──────────────────────────────────────────────

"""
    describe(T::Type; io::IO=stdout)

Pretty-print the full contract for `T`: mandatory methods, optional methods,
and behavioral invariants.
"""
function describe(::Type{T}; io::IO=stdout) where {T}
    println(io, "Interface contract for $T")
    println(io, "─" ^ 40)

    specs     = get(_registry, T, nothing)
    behaviors = get(_behaviors, T, nothing)
    desc      = get(_descriptions, T, "")

    if isnothing(specs) && isnothing(behaviors)
        println(io, "  (no contract registered)")
        return nothing
    end

    isempty(desc) || (println(io, "  ", desc); println(io))

    if !isnothing(specs)
        mandatory = filter(s -> !s.optional, specs)
        optional  = filter(s -> s.optional, specs)

        if !isempty(mandatory)
            println(io, "  Mandatory methods:")
            for s in mandatory
                println(io, "    ", _method_line(s))
            end
        end
        if !isempty(optional)
            println(io, "  Optional methods:")
            for s in optional
                println(io, "    ", _method_line(s))
            end
        end
    end

    if !isnothing(behaviors)
        mandatory_b = filter(b -> !b.optional, behaviors)
        optional_b  = filter(b -> b.optional, behaviors)

        if !isempty(mandatory_b)
            println(io, "  Behavioral invariants:")
            for b in mandatory_b
                println(io, "    ", b.description)
            end
        end
        if !isempty(optional_b)
            println(io, "  Optional invariants:")
            for b in optional_b
                println(io, "    ", b.description)
            end
        end
    end

    nothing
end

"""
    describe(T::Type, Val(:all); io::IO=stdout)

Pretty-print contracts for `T`'s full supertype chain.
"""
function describe(::Type{T}, ::Val{:all}; io::IO=stdout) where {T}
    println(io, "Full interface contract for $T")
    println(io, "=" ^ 40)

    found = false
    for S in supertypes(T)
        key       = _registry_key(S)
        specs     = get(_registry, key, nothing)
        behaviors = get(_behaviors, key, nothing)
        (isnothing(specs) && isnothing(behaviors)) && continue
        found = true

        println(io)
        println(io, "  From $S:")

        if !isnothing(specs)
            mandatory = filter(s -> !s.optional, specs)
            optional  = filter(s -> s.optional, specs)
            for s in mandatory
                println(io, "    ", s.description)
            end
            for s in optional
                println(io, "    [optional] ", s.description)
            end
        end

        if !isnothing(behaviors)
            for b in behaviors
                prefix = b.optional ? "[optional invariant] " : "[invariant] "
                println(io, "    ", prefix, b.description)
            end
        end
    end

    found || println(io, "  (no contracts registered)")
    nothing
end

# ── Documentation integration ─────────────────────────────────────────
# Renders a contract to Markdown and attaches it to the target type's `?`-docs.
# A distinct sentinel signature lets our section coexist with any docstring the
# user (or Base) already wrote — `?T` shows both, separated by a rule. This
# works uniformly for owned types and retroactive contracts on foreign types.

const _DOC_SIG = Tuple{Val{:TypeContractsContract}}

"""
    _contract_markdown(T::Type) -> Markdown.MD

Build the `?`-visible contract section for `T` from the registered prose
description, method specs, and behavioral invariants.
"""
function _contract_markdown(::Type{T}) where {T}
    io = IOBuffer()
    println(io, "# TypeContracts Interface")
    println(io)

    desc = get(_descriptions, T, "")
    if !isempty(desc)
        println(io, desc)
        println(io)
    end

    specs = get(_registry, T, nothing)
    if !isnothing(specs)
        mandatory = filter(s -> !s.optional, specs)
        optional  = filter(s -> s.optional, specs)
        _md_method_block(io, "Mandatory methods", mandatory)
        _md_method_block(io, "Optional methods", optional)
    end

    behaviors = get(_behaviors, T, nothing)
    if !isnothing(behaviors)
        mandatory_b = filter(b -> !b.optional, behaviors)
        optional_b  = filter(b -> b.optional, behaviors)
        _md_behavior_block(io, "Behavioral invariants", mandatory_b)
        _md_behavior_block(io, "Optional invariants", optional_b)
    end

    Markdown.parse(String(take!(io)))
end

# Plain-text method line for `describe`: "sig — doc" when prose is present.
function _method_line(s::MethodSpec)
    isempty(s.doc) ? s.description : string(s.description, " — ", s.doc)
end

function _md_method_block(io, title, specs)
    isempty(specs) && return
    println(io, "**", title, "**")
    println(io)
    for s in specs
        line = "  - `" * s.description * "`"
        isempty(s.doc) || (line *= " — " * s.doc)
        println(io, line)
    end
    println(io)
    return
end

function _md_behavior_block(io, title, behaviors)
    isempty(behaviors) && return
    println(io, "**", title, "**")
    println(io)
    for b in behaviors
        println(io, "  - ", b.description)
    end
    println(io)
    return
end

"""
    _attach_contract_doc(T::Type)

Attach (or refresh) the contract's Markdown section to `T`'s documentation,
making it visible via `?T`. Called from `@contract` and `@invariants` so the
doc always reflects the latest registered state.

Load-time only — never reached from the `interface_trait` runtime path. A no-op
when `_DOCS_ENABLED[]` is false, and any failure is swallowed so a stripped doc
system can never break module loading or a compiled binary.
"""
function _attach_contract_doc(::Type{T}) where {T}
    _DOCS_ENABLED[] || return nothing
    try
        md      = _contract_markdown(T)
        mod     = parentmodule(T)
        binding = Base.Docs.Binding(mod, nameof(T))
        # Drop any prior contract entry under our sentinel signature first, so
        # re-registration (e.g. @contract then @invariants) doesn't emit the
        # "Replacing docs" warning. Leaves the user's/Base's own docstring intact.
        metadict = Base.Docs.meta(mod)
        if haskey(metadict, binding)
            multidoc = metadict[binding]
            if haskey(multidoc.docs, _DOC_SIG)
                delete!(multidoc.docs, _DOC_SIG)
                filter!(!=(_DOC_SIG), multidoc.order)
            end
        end
        docstr = Base.Docs.docstr(md, Dict{Symbol,Any}(:module => mod, :path => nothing, :linenumber => 0))
        Base.Docs.doc!(mod, binding, docstr, _DOC_SIG)
    catch
        # Documentation is best-effort; never fatal.
    end
    nothing
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
    _build_contract_expr(T_expr, "", block)
end

macro contract(T_expr, desc, block)
    desc isa String ||
        error("@contract: interface description must be a string literal, got: $desc")
    _build_contract_expr(T_expr, desc, block)
end

function _build_contract_expr(T_expr, desc::String, block)
    block isa Expr && block.head == :block ||
        error("@contract requires a begin...end block")

    abstract_sym, type_vars = _parse_contract_header(T_expr)

    parsed     = _parse_block(block)
    spec_exprs = Expr[]

    for (fname, atypes, rtype, opt, mdoc) in parsed
        aexprs = Any[_resolve_arg_expr(t, type_vars, abstract_sym) for t in atypes]

        rtype_display_expr, rtype_spec_expr = _resolve_rtype_exprs(rtype, type_vars, abstract_sym)

        sigdesc = _fmt(fname, atypes, rtype)

        push!(spec_exprs, :(
            TypeContracts.MethodSpec(
                $(esc(fname)),
                Any[$(aexprs...)],
                $rtype_display_expr,
                $rtype_spec_expr,
                $sigdesc,
                $opt,
                $mdoc
            )
        ))
    end

    quote
        isabstracttype($(esc(abstract_sym))) ||
            error("@contract requires an abstract type, got $($(esc(abstract_sym)))")
        TypeContracts._registry[$(esc(abstract_sym))] = TypeContracts.MethodSpec[$(spec_exprs...)]
        TypeContracts._descriptions[$(esc(abstract_sym))] = $desc
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
    quote
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
    quote
        TypeContracts._verify_all_in_module(@__MODULE__)
    end
end

function _all_concrete_subtypes(T::Type)
    result = Type[]
    for S in subtypes(T)
        if isabstracttype(S)
            append!(result, _all_concrete_subtypes(S))
        else
            push!(result, S)
        end
    end
    result
end

function _verify_all_in_module(mod::Module)
    checked = Type[]

    for abstract_type in keys(_registry)
        for T in _all_concrete_subtypes(abstract_type)
            parentmodule(T) === mod || continue
            T in checked && continue
            check_contract(T)
            push!(checked, T)
        end
    end

    (types=checked, passed=true)
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

        push!(spec_exprs, :(
            TypeContracts.BehaviorSpec($desc, $(esc(ex.args[3])), $is_optional)
        ))
    end

    quote
        TypeContracts._behaviors[$(esc(T))] = TypeContracts.BehaviorSpec[$(spec_exprs...)]
        TypeContracts._attach_contract_doc($(esc(T)))
        nothing
    end
end

# ── Macro internals ───────────────────────────────────────────────────

function _parse_contract_header(expr)
    if expr isa Symbol
        return expr, Dict{Symbol,Int}()
    elseif expr isa Expr && expr.head == :curly
        abstract_sym = expr.args[1]
        abstract_sym isa Symbol ||
            error("@contract: abstract type name must be a symbol, got $abstract_sym")
        type_vars = Dict{Symbol,Int}()
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

function _resolve_arg_expr(t, type_vars::Dict{Symbol,Int}, abstract_sym::Symbol)
    t isa Symbol && t === :Self && return :(TypeContracts.Self)
    if t isa Symbol && haskey(type_vars, t)
        idx = type_vars[t]
        return :(TypeContracts.TypeParamRef($(esc(abstract_sym)), $idx))
    end
    esc(t)
end

function _resolve_rtype_exprs(rtype, type_vars::Dict{Symbol,Int}, abstract_sym::Symbol)
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
        mdoc   = ""
        if ex isa Expr && ex.head == :call && length(ex.args) >= 3 && ex.args[1] === :(=>)
            rhs = ex.args[3]
            rhs isa String ||
                error("@contract: method description must be a string literal, got: $rhs")
            mdoc   = rhs
            sig_ex = ex.args[2]
        end
        push!(specs, (_parse_sig(sig_ex)..., is_optional, mdoc))
    end
    specs
end

function _parse_sig(ex)
    call_ex, rtype = _split_ret(ex)
    call_ex isa Expr && call_ex.head == :call ||
        error("Expected function call signature, got: $(ex)")
    fname  = call_ex.args[1]
    atypes = Any[_arg_type(call_ex.args[i]) for i in 2:length(call_ex.args)]
    (fname, atypes, rtype)
end

function _split_ret(ex)
    if ex isa Expr && ex.head == :(::) && length(ex.args) == 2
        inner = ex.args[1]
        if inner isa Expr && inner.head == :call
            return inner, ex.args[2]
        end
    end
    (ex, :Any)
end

function _arg_type(arg)
    arg isa Expr && arg.head == :(::) ||
        error("Expected typed argument (::T or name::T), got: $(arg)")
    length(arg.args) == 1 ? arg.args[1] : arg.args[2]
end

function _fmt(fname, atypes, rtype)
    args = join(["::$t" for t in atypes], ", ")
    sig  = "$fname($args)"
    rtype === :Any ? sig : "$sig :: $rtype"
end

end # module TypeContracts
