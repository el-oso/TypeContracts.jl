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

function Base.showerror(io::IO, e::InterfaceError)
    printstyled(io, "InterfaceError"; bold = true, color = :red)
    print(io, ": ")
    lines = split(e.msg, '\n')
    for (i, line) in enumerate(lines)
        i > 1 && println(io)
        if startswith(line, "  ")
            # method line: "  desc  [required by T]"
            m = match(r"^(  .+?)(\s{2,}\[required by .+\])$", line)
            if !isnothing(m)
                printstyled(io, m[1]; color = :yellow)
                printstyled(io, m[2]; color = :light_black)
            else
                printstyled(io, line; color = :yellow)
            end
        else
            printstyled(io, line; bold = (i == 1))
        end
    end
    return
end

# Colored method signature: function name in cyan, args normal, return type green.
# Defined here because Base.show(MethodSpec) uses it.
function _print_sig_highlighted(io::IO, desc::String)
    paren = findfirst('(', desc)
    if isnothing(paren)
        printstyled(io, desc; color = :cyan, bold = true)
        return
    end
    printstyled(io, desc[1:prevind(desc, paren)]; color = :cyan, bold = true)
    printstyled(io, "("; color = :light_black)

    close_paren = findlast(')', desc)
    args_str = desc[nextind(desc, paren):prevind(desc, close_paren)]
    first = true
    for arg in split(args_str, ", ")
        first || printstyled(io, ", "; color = :light_black)
        first = false
        arg = strip(String(arg))
        if startswith(arg, "::")
            printstyled(io, "::"; color = :light_black)
            tname = arg[3:end]
            printstyled(io, tname; color = tname == "Self" ? :cyan : :yellow)
        else
            print(io, arg)
        end
    end

    printstyled(io, ")"; color = :light_black)
    suffix = String(desc[nextind(desc, close_paren):end])
    m = match(r"^ :: (.+)$", suffix)
    return if !isnothing(m)
        printstyled(io, " :: "; color = :light_black)
        printstyled(io, m[1]; color = :green)
    end
end

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
    s.optional && printstyled(io, "[optional] "; color = :yellow)
    _print_sig_highlighted(io, s.description)
    return isempty(s.doc) || printstyled(io, " — $(s.doc)"; color = :light_black)
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
    b.optional && printstyled(io, "[optional] "; color = :yellow)
    return printstyled(io, b.description; color = :magenta)
end

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

Base.show(io::IO, ::Implemented{I}) where {I} = print(io, "Implemented{$I}()")
Base.show(io::IO, ::NotImplemented{I}) where {I} = print(io, "NotImplemented{$I}()")
