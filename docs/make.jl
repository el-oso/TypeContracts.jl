using Documenter, DocumenterVitepress
using TypeContracts

DocMeta.setdocmeta!(TypeContracts, :DocTestSetup, :(using TypeContracts); recursive = true)

makedocs(;
    modules = [TypeContracts],
    authors = "el_oso",
    sitename = "TypeContracts.jl",
    remotes = nothing,
    format = DocumenterVitepress.MarkdownVitepress(
        repo = "github.com/el_oso/TypeContracts.jl",
        devbranch = "main",
        devurl = "dev",
        description = "Statically-checked interface contracts for Julia abstract types.",
        sidebar_drawer = true,
    ),
    pages = [
        "Home" => "index.md",
        "Guide" => [
            "Getting Started"          => "guide/getting-started.md",
            "Defining Contracts"       => "guide/contracts.md",
            "Verification"             => "guide/verification.md",
            "Behavioral Testing"       => "guide/behavioral.md",
            "Trait Dispatch"           => "guide/traits.md",
            "Introspection"            => "guide/introspection.md",
            "Documentation Integration" => "guide/documentation.md",
        ],
        "Examples" => [
            "Nine Ways to Structure Interfaces" => "examples/nine-ways.md",
        ],
        "Reference" => [
            "API Reference" => "reference/api.md",
        ],
    ],
    checkdocs = :exports,
    warnonly = true,
)

DocumenterVitepress.deploydocs(;
    repo = "github.com/el_oso/TypeContracts.jl",
    push_preview = true,
)
