function _print_method_line(io::IO, s::MethodSpec)
    _print_sig_highlighted(io, s.description)
    return if !isempty(s.doc)
        printstyled(io, " — "; color = :light_black)
        printstyled(io, s.doc; color = :light_black)
    end
end

"""
    describe(T::Type; io::IO=stdout, all::Bool=!isabstracttype(T))

Pretty-print the contract for `T`.

- `all=true` — walks the full supertype chain and shows every inherited
  contract (equivalent to `describe(T, Val(:all))`).
- `all=false` — shows only what `T` itself registers: the methods and
  invariants declared directly in `@contract T` and `@invariants T`.

The default is `true` for concrete types (since contracts live on abstract supertypes,
not on the concrete type itself) and `false` for abstract types (showing only what
that level adds). Pass `all=true` on an abstract type to see the full chain:

```julia
describe(AbstractFloat)             # own invariants only
describe(AbstractFloat; all=true)   # + Real + Number
describe(Float64)                   # full chain (default for concrete)
describe(Float64; all=false)        # (no contract registered)
```
"""
function describe(::Type{T}; io::IO = stdout, all::Bool = !isabstracttype(T)) where {T}
    all && return describe(T, Val(:all); io)
    printstyled(io, "Interface contract for "; bold = true)
    printstyled(io, T; bold = true, color = :cyan)
    println(io)
    printstyled(io, "─"^40; color = :light_black)
    println(io)

    specs = _contract_specs(T)
    behaviors = _behavior_specs(T)
    desc = _contract_desc(T)

    if isempty(specs) && isempty(behaviors)
        printstyled(io, "  (no contract registered)\n"; color = :light_black)
        return nothing
    end

    if !isempty(desc)
        printstyled(io, "  ", desc; color = :light_black)
        println(io); println(io)
    end

    if !isempty(specs)
        mandatory = filter(s -> !s.optional, specs)
        optional = filter(s -> s.optional, specs)

        if !isempty(mandatory)
            printstyled(io, "  Mandatory methods:\n"; bold = true, color = :green)
            for s in mandatory
                print(io, "    ")
                _print_method_line(io, s)
                println(io)
            end
        end
        if !isempty(optional)
            printstyled(io, "  Optional methods:\n"; bold = true, color = :yellow)
            for s in optional
                print(io, "    ")
                _print_method_line(io, s)
                println(io)
            end
        end
    end

    if !isempty(behaviors)
        mandatory_b = filter(b -> !b.optional, behaviors)
        optional_b = filter(b -> b.optional, behaviors)

        if !isempty(mandatory_b)
            printstyled(io, "  Behavioral invariants:\n"; bold = true, color = :magenta)
            for b in mandatory_b
                print(io, "    ")
                printstyled(io, b.description; color = :light_black)
                println(io)
            end
        end
        if !isempty(optional_b)
            printstyled(io, "  Optional invariants:\n"; bold = true, color = :yellow)
            for b in optional_b
                print(io, "    ")
                printstyled(io, b.description; color = :light_black)
                println(io)
            end
        end
    end

    return nothing
end

"""
    describe(T::Type, Val(:all); io::IO=stdout)

Pretty-print contracts for `T`'s full supertype chain.
Equivalent to `describe(T; all=true)`.
"""
function describe(::Type{T}, ::Val{:all}; io::IO = stdout) where {T}
    printstyled(io, "Full interface contract for "; bold = true)
    printstyled(io, T; bold = true, color = :cyan)
    println(io)
    printstyled(io, "="^40; color = :light_black)
    println(io)

    found = false
    for S in supertypes(T)
        key = _registry_key(S)
        specs = _contract_specs(key)
        behaviors = _behavior_specs(key)
        (isempty(specs) && isempty(behaviors)) && continue
        found = true

        println(io)
        print(io, "  From ")
        printstyled(io, S; bold = true, color = :cyan)
        println(io, ":")

        if !isempty(specs)
            mandatory = filter(s -> !s.optional, specs)
            optional = filter(s -> s.optional, specs)
            for s in mandatory
                print(io, "    ")
                _print_method_line(io, s)
                println(io)
            end
            for s in optional
                print(io, "    ")
                printstyled(io, "[optional] "; color = :yellow)
                _print_method_line(io, s)
                println(io)
            end
        end

        if !isempty(behaviors)
            for b in behaviors
                print(io, "    ")
                if b.optional
                    printstyled(io, "[optional invariant] "; color = :yellow)
                else
                    printstyled(io, "[invariant] "; color = :magenta)
                end
                printstyled(io, b.description; color = :light_black)
                println(io)
            end
        end
    end

    found || printstyled(io, "  (no contracts registered)\n"; color = :light_black)
    return nothing
end

"""
    contract_md_string(T::Type) -> String

Return a Markdown-formatted string describing the contract and behavioral
invariants registered for `T`. Suitable for Documenter `@eval` blocks —
a `String` return value is rendered as Markdown by Documenter.

Returns an empty string when no contract or invariants are registered for `T`.
"""
function contract_md_string(::Type{T}) where {T}
    specs = _contract_specs(T)
    behaviors = _behavior_specs(T)
    isempty(specs) && isempty(behaviors) && return ""

    io = IOBuffer()
    println(io, "# TypeContracts Interface")
    println(io)
    desc = _contract_desc(T)
    isempty(desc) || (println(io, desc); println(io))

    if !isempty(specs)
        _cmd_md_method_block(io, "**Mandatory methods**", filter(s -> !s.optional, specs))
        _cmd_md_method_block(io, "**Optional methods**", filter(s -> s.optional, specs))
    end
    if !isempty(behaviors)
        _cmd_md_behavior_block(io, "**Behavioral invariants**", filter(b -> !b.optional, behaviors))
        _cmd_md_behavior_block(io, "**Optional invariants**", filter(b -> b.optional, behaviors))
    end
    return String(take!(io))
end

function _cmd_md_method_block(io, title, specs)
    isempty(specs) && return
    println(io, title)
    println(io)
    for s in specs
        line = "  - `$(s.description)`"
        isempty(s.doc) || (line *= " — $(s.doc)")
        println(io, line)
    end
    return println(io)
end

function _cmd_md_behavior_block(io, title, behaviors)
    isempty(behaviors) && return
    println(io, title)
    println(io)
    for b in behaviors
        println(io, "  - $(b.description)")
    end
    return println(io)
end

# Dispatch hook for contract_md. TypeContractsDocumenterExt adds a method
# specialised on `_MdRenderHook`. The no-op fallback here ensures contract_md
# returns nothing in non-Documenter contexts without pulling in Markdown.
struct _MdRenderHook end
const _MD_RENDER_HOOK = _MdRenderHook()
_contract_md_impl(::Any, @nospecialize(::Type)) = nothing

"""
    contract_md(T::Type)

Return a `Markdown.MD` object for the contract registered on `T`.
Requires the `TypeContractsDocumenterExt` extension, which loads automatically
when `using Documenter` is in scope. Returns `nothing` when the extension is absent.
"""
function contract_md(::Type{T}) where {T}
    return _contract_md_impl(_MD_RENDER_HOOK, T)
end
