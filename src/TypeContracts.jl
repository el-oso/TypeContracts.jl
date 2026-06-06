module TypeContracts

using InteractiveUtils: supertypes, subtypes

export @contract, @verify, @verify_all, @invariants,
       check_contract, satisfies, list_contract, registered_contracts,
       test_behavior, list_behaviors, registered_behaviors,
       describe, interface_trait,
       Self, InterfaceError, MethodSpec, BehaviorSpec,
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
- `arg_types::Vector{Type}` — argument types (`Self` used as placeholder)
- `return_type::Type` — annotated return type (`Any` if unspecified)
- `description::String` — human-readable signature for error messages
- `optional::Bool` — whether this method is optional
"""
struct MethodSpec
    f::Function
    arg_types::Vector{Type}
    return_type::Type
    description::String
    optional::Bool
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

struct Implemented{I} end
struct NotImplemented{I} end

Base.show(io::IO, ::Implemented{I}) where {I}    = print(io, "Implemented{$I}()")
Base.show(io::IO, ::NotImplemented{I}) where {I} = print(io, "NotImplemented{$I}()")

# ── Registries ────────────────────────────────────────────────────────

const _registry  = Dict{Type, Vector{MethodSpec}}()
const _behaviors = Dict{Type, Vector{BehaviorSpec}}()

registered_contracts()::Dict{Type, Vector{MethodSpec}}   = copy(_registry)
registered_behaviors()::Dict{Type, Vector{BehaviorSpec}} = copy(_behaviors)

# ── Internal ──────────────────────────────────────────────────────────

function _build_sig(arg_types::Vector{Type}, T::Type)
    n = length(arg_types)
    resolved = Vector{Type}(undef, n)
    @inbounds for i in 1:n
        resolved[i] = arg_types[i] === Self ? T : arg_types[i]
    end
    Tuple{resolved...}
end

# ── Public API: Structural Checks ─────────────────────────────────────

"""
    check_contract(T::Type) -> NamedTuple{(:type, :contracts, :passed)}

Verify that `T` satisfies all **mandatory** contracts for its supertype chain.
Optional methods are skipped. Throws `InterfaceError` on failure.

Place `@verify T` at module top level to run this during precompilation.
"""
function check_contract(T::Type)
    errors  = String[]
    checked = Type[]

    for S in supertypes(T)
        specs = get(_registry, S, nothing)
        isnothing(specs) && continue
        push!(checked, S)
        for spec in specs
            spec.optional && continue
            sig = _build_sig(spec.arg_types, T)
            if !hasmethod(spec.f, sig)
                push!(errors, "  $(spec.description)  [required by $S]")
            end
        end
    end

    if !isempty(errors)
        throw(InterfaceError(
            "Type $T does not satisfy interface contract.\n" *
            "Missing methods:\n" *
            join(errors, "\n")
        ))
    end

    (type=T, contracts=checked, passed=true)
end

"""
    satisfies(T::Type, S::Type) -> NamedTuple

Non-throwing check. Returns `(satisfied, missing_methods, missing_optional)`.
`satisfied` is true when all mandatory methods are present.
"""
function satisfies(T::Type, S::Type)
    specs = get(_registry, S, nothing)
    isnothing(specs) && return (satisfied=true, missing_methods=String[], missing_optional=String[])

    missing_methods  = String[]
    missing_optional = String[]
    for spec in specs
        sig = _build_sig(spec.arg_types, T)
        if !hasmethod(spec.f, sig)
            push!(spec.optional ? missing_optional : missing_methods, spec.description)
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
        specs = get(_registry, S, nothing)
        !isnothing(specs) && (result[S] = specs)
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

Check if `T` satisfies the mandatory contract for `I`.
Returns a singleton trait type suitable for dispatch.

# Example
```julia
process(x) = _process(interface_trait(AbstractShape, typeof(x)), x)
_process(::Implemented{AbstractShape}, x) = area(x)
_process(::NotImplemented{AbstractShape}, x) = error("not a shape")
```
"""
function interface_trait(::Type{I}, ::Type{T}) where {I, T}
    specs = get(_registry, I, nothing)
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
        behaviors = get(_behaviors, S, nothing)
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

    specs = get(_registry, T, nothing)
    behaviors = get(_behaviors, T, nothing)

    if isnothing(specs) && isnothing(behaviors)
        println(io, "  (no contract registered)")
        return nothing
    end

    if !isnothing(specs)
        mandatory = filter(s -> !s.optional, specs)
        optional  = filter(s -> s.optional, specs)

        if !isempty(mandatory)
            println(io, "  Mandatory methods:")
            for s in mandatory
                println(io, "    ", s.description)
            end
        end
        if !isempty(optional)
            println(io, "  Optional methods:")
            for s in optional
                println(io, "    ", s.description)
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
        specs     = get(_registry, S, nothing)
        behaviors = get(_behaviors, S, nothing)
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

# ── Macros ────────────────────────────────────────────────────────────

"""
    @contract AbstractType begin
        method1(::Self, ::ArgType)
        method2(::Self) :: ReturnType
        :optional
        method3(::Self)
    end

Register a method contract for a type. Methods before `:optional` are
mandatory (enforced by `@verify`). Methods after `:optional` are recorded
but not enforced at compile time.

Functions must be in scope when `@contract` is evaluated. For new functions,
declare them first with `function name end`.
"""
macro contract(T, block)
    block isa Expr && block.head == :block ||
        error("@contract requires a begin...end block")

    parsed     = _parse_block(block)
    spec_exprs = Expr[]

    for (fname, atypes, rtype, opt) in parsed
        aexprs = Any[_self_or_esc(t) for t in atypes]
        rexpr  = rtype === :Any ? :(Any) : esc(rtype)
        desc   = _fmt(fname, atypes, rtype)

        push!(spec_exprs, :(
            TypeContracts.MethodSpec($(esc(fname)), Type[$(aexprs...)], $rexpr, $desc, $opt)
        ))
    end

    quote
        isabstracttype($(esc(T))) ||
            error("@contract requires an abstract type, got $($(esc(T)))")
        TypeContracts._registry[$(esc(T))] = TypeContracts.MethodSpec[$(spec_exprs...)]
        nothing
    end
end

"""
    @verify ConcreteType

Assert at module-load / precompile time that `ConcreteType` satisfies all
mandatory contracts for its supertype chain. Optional methods are not checked.

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
        nothing
    end
end

# ── Macro internals (called at macro-expansion time) ──────────────────

function _parse_block(block::Expr)
    specs = Tuple{Any, Vector{Any}, Any, Bool}[]
    is_optional = false
    for ex in block.args
        ex isa LineNumberNode && continue
        if ex isa QuoteNode && ex.value === :optional
            is_optional = true
            continue
        end
        push!(specs, (_parse_sig(ex)..., is_optional))
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

function _self_or_esc(t)
    (t isa Symbol && t == :Self) ? :(TypeContracts.Self) : esc(t)
end

function _fmt(fname, atypes, rtype)
    args = join(["::$t" for t in atypes], ", ")
    sig  = "$fname($args)"
    rtype === :Any ? sig : "$sig :: $rtype"
end

end # module TypeContracts
