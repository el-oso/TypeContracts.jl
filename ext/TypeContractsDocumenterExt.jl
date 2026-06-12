module TypeContractsDocumenterExt

using TypeContracts, Documenter, Markdown
import Base.Docs

# Same sentinel signature as the REPL extension — coexists with any existing docstring.
const _DOC_SIG = Tuple{Val{:TypeContractsContract}}

# Provide the concrete contract_md implementation via the dispatch hook.
# TypeContracts.contract_md calls _contract_md_impl(_MD_RENDER_HOOK, T), which
# resolves to this method once the extension is loaded.
TypeContracts._contract_md_impl(::TypeContracts._MdRenderHook, ::Type{T}) where {T} =
    Markdown.parse(TypeContracts.contract_md_string(T))

function _attach_doc(::Type{T}) where {T}
    isempty(TypeContracts.contract_md_string(T)) && return
    try
        md = TypeContracts.contract_md(T)
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
        docstr = Base.Docs.docstr(
            md,
            Dict{Symbol, Any}(:module => mod, :path => nothing, :linenumber => 0),
        )
        Base.Docs.doc!(mod, binding, docstr, _DOC_SIG)
    catch
        # Documentation is best-effort; never fatal.
    end
    return nothing
end

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
    # extension loaded (e.g. all contracts from BaseTypeContracts, user packages).
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

end # module TypeContractsDocumenterExt
