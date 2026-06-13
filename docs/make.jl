using Documenter, DocumenterVitepress
using TypeContracts

DocMeta.setdocmeta!(TypeContracts, :DocTestSetup, :(using TypeContracts); recursive = true)

makedocs(;
    modules = [TypeContracts],
    authors = "el-oso",
    sitename = "TypeContracts.jl",
    remotes = nothing,
    format = DocumenterVitepress.MarkdownVitepress(
        repo = "github.com/el-oso/TypeContracts.jl",
        devbranch = "master",
        devurl = "dev",
        description = "Statically-checked interface contracts for Julia abstract types.",
        sidebar_drawer = true,
    ),
    pages = [
        "Home" => "index.md",
        "Guide" => [
            "Getting Started" => "guide/getting-started.md",
            "Defining Contracts" => "guide/contracts.md",
            "Verification" => "guide/verification.md",
            "Behavioral Testing" => "guide/behavioral.md",
            "Testing" => "guide/testing.md",
            "Trait Dispatch" => "guide/traits.md",
            "Introspection" => "guide/introspection.md",
            "Documentation Integration" => "guide/documentation.md",
            "Revise Integration" => "guide/revise.md",
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
    repo = "github.com/el-oso/TypeContracts.jl",
    devbranch = "master",
    push_preview = true,
)
