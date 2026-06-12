module TypeContractsREPLExt

using TypeContracts
using REPL
import Base.Docs

# REPL is the sole extension trigger. REPL always loads Markdown, so we reach
# Markdown through it rather than declaring a separate weakdep — Julia only lets
# an extension `using` the host's regular deps plus its own trigger packages,
# and a non-trigger weakdep (Markdown) would be rejected at precompile time.
const Markdown = REPL.Markdown

# Sentinel signature that coexists with any existing docstring for a type.
const _DOC_SIG = Tuple{Val{:TypeContractsContract}}

function _build_contract_markdown(::Type{T}) where {T}
    io = IOBuffer()
    println(io, "# TypeContracts Interface")
    println(io)

    desc = TypeContracts._contract_desc(T)
    isempty(desc) || (println(io, desc); println(io))

    specs = TypeContracts._contract_specs(T)
    if !isempty(specs)
        _md_method_block(io, "Mandatory methods", filter(s -> !s.optional, specs))
        _md_method_block(io, "Optional methods", filter(s -> s.optional, specs))
    end

    behaviors = TypeContracts._behavior_specs(T)
    if !isempty(behaviors)
        _md_behavior_block(io, "Behavioral invariants", filter(b -> !b.optional, behaviors))
        _md_behavior_block(io, "Optional invariants", filter(b -> b.optional, behaviors))
    end

    return Markdown.parse(String(take!(io)))
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
    return println(io)
end

function _md_behavior_block(io, title, behaviors)
    isempty(behaviors) && return
    println(io, "**", title, "**")
    println(io)
    for b in behaviors
        println(io, "  - ", b.description)
    end
    return println(io)
end

function _attach_doc(::Type{T}) where {T}
    try
        md = _build_contract_markdown(T)
        mod = parentmodule(T)
        binding = Base.Docs.Binding(mod, nameof(T))
        metadict = Base.Docs.meta(mod)
        if haskey(metadict, binding)
            multidoc = metadict[binding]
            if haskey(multidoc.docs, _DOC_SIG)
                delete!(multidoc.docs, _DOC_SIG)
                filter!(!=(_DOC_SIG), multidoc.order)
            end
        end
        docstr = Base.Docs.docstr(md, Dict{Symbol, Any}(:module => mod, :path => nothing, :linenumber => 0))
        Base.Docs.doc!(mod, binding, docstr, _DOC_SIG)
    catch
        # Documentation is best-effort; never fatal.
    end
    return nothing
end

# Provide the concrete doc-sync hook method. TypeContracts' macros call
# `_attach_contract_doc(_DOC_SYNC_HOOK, T)`, which resolves to a no-op in core and
# to this method once the extension is loaded — so future `@contract`/`@invariants`
# attach docs immediately, while a juliac-trim build (extension absent) hits only
# the no-op fallback.
TypeContracts._attach_contract_doc(::TypeContracts._DocSyncHook, ::Type{T}) where {T} =
    (_attach_doc(T); nothing)

function _registered_type(m::Method)
    p = m.sig.parameters
    length(p) == 2 || return nothing
    p[2] isa DataType && p[2].name.name === :Type || return nothing
    isempty(p[2].parameters) && return nothing
    T = p[2].parameters[1]
    return T isa Type ? T : nothing
end

function __init__()
    # Retroactively attach docs for every contract registered before this
    # extension loaded (e.g. package contracts registered at their own load time).
    seen = Set{Type}()
    for m in methods(TypeContracts._contract_specs)
        T = _registered_type(m)
        T === nothing && continue
        push!(seen, T)
        _attach_doc(T)
    end
    for m in methods(TypeContracts._behavior_specs)
        T = _registered_type(m)
        T === nothing && continue
        T in seen || _attach_doc(T)
    end
    return
end

end # module TypeContractsREPLExt
