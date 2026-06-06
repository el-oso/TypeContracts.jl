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

    desc = get(TypeContracts._descriptions, T, "")
    isempty(desc) || (println(io, desc); println(io))

    specs = get(TypeContracts._registry, T, nothing)
    if !isnothing(specs)
        _md_method_block(io, "Mandatory methods", filter(s -> !s.optional, specs))
        _md_method_block(io, "Optional methods",  filter(s ->  s.optional, specs))
    end

    behaviors = get(TypeContracts._behaviors, T, nothing)
    if !isnothing(behaviors)
        _md_behavior_block(io, "Behavioral invariants", filter(b -> !b.optional, behaviors))
        _md_behavior_block(io, "Optional invariants",   filter(b ->  b.optional, behaviors))
    end

    Markdown.parse(String(take!(io)))
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
end

function _md_behavior_block(io, title, behaviors)
    isempty(behaviors) && return
    println(io, "**", title, "**")
    println(io)
    for b in behaviors
        println(io, "  - ", b.description)
    end
    println(io)
end

function _attach_doc(::Type{T}) where {T}
    try
        md      = _build_contract_markdown(T)
        mod     = parentmodule(T)
        binding = Base.Docs.Binding(mod, nameof(T))
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

function __init__()
    TypeContracts._attach_doc_impl[] = _attach_doc
    # Retroactively attach docs for all contracts registered at precompile time.
    seen = Set{Type}()
    for T in keys(TypeContracts._registry)
        push!(seen, T)
        _attach_doc(T)
    end
    for T in keys(TypeContracts._behaviors)
        T in seen || _attach_doc(T)
    end
end

end # module TypeContractsREPLExt
