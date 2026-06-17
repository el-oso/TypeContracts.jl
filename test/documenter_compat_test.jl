@testitem "contract marker docstring :path is String, not Nothing (REPL ext)" begin
    # Regression: @contract attached marker docstrings with :path => nothing.
    # Documenter's DocTestContext constructor rejects Nothing and throws MethodError
    # before running any real doctest in packages that use @contract + doctest=true.
    # Fix: :path => "" in both extensions.
    using TypeContracts
    using Test
    import REPL        # triggers TypeContractsREPLExt
    import Base.Docs

    abstract type DocPathREPLShape end
    function dpr_area end
    @contract DocPathREPLShape begin
        dpr_area(::Self) :: Float64
    end

    sig = Tuple{Val{:TypeContractsContract}}
    mod = parentmodule(DocPathREPLShape)
    binding = Base.Docs.Binding(mod, :DocPathREPLShape)
    meta = Base.Docs.meta(mod; autoinit = false)

    if meta !== nothing && haskey(meta, binding) && haskey(meta[binding].docs, sig)
        ds = meta[binding].docs[sig]
        @test ds.data[:path] isa AbstractString
        @test ds.data[:path] !== nothing
    else
        @test_skip "REPL extension not active in this environment"
    end
end

@testitem "contract marker docstring :path is String, not Nothing (Documenter ext)" begin
    using TypeContracts
    using Test
    using Documenter    # triggers TypeContractsDocumenterExt
    import Base.Docs

    abstract type DocPathDocShape end
    function dpd_area end
    @contract DocPathDocShape begin
        dpd_area(::Self) :: Float64
    end

    sig = Tuple{Val{:TypeContractsContract}}
    mod = parentmodule(DocPathDocShape)
    binding = Base.Docs.Binding(mod, :DocPathDocShape)
    meta = Base.Docs.meta(mod; autoinit = false)

    if meta !== nothing && haskey(meta, binding) && haskey(meta[binding].docs, sig)
        ds = meta[binding].docs[sig]
        @test ds.data[:path] isa AbstractString
        @test ds.data[:path] !== nothing
    else
        @test_skip "Documenter extension not active in this environment"
    end
end
