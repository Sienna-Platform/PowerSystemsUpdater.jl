using Documenter
import DataStructures: OrderedDict
using PowerSystemsUpdater
using DocumenterInterLinks


links = InterLinks(
    # "InfrastructureSystems" => "https://sienna-platform.github.io/InfrastructureSystems.jl/stable/"
)

# Explicitly defined fallbacks for external docstrings that fail to resolve
fallbacks = ExternalFallbacks(
    # "ComponentContainer" => "@extref InfrastructureSystems.ComponentContainer",
)

include(joinpath(@__DIR__, "make_tutorials.jl"))
make_tutorials()

pages = OrderedDict(
    "Welcome Page" => "index.md",
    "Tutorials" => Any["stub" => "tutorials/generated_stub.md"],
    "How to..." => Any["stub" => "how_to_guides/stub.md"],
    "Explanation" => Any[
        "PSY5 to PSY6 component changes" =>
            "explanation/psy5_to_psy6_component_changes.md",
        "stub" => "explanation/stub.md",
    ],
    "Reference" => Any[ 
        "Developers" => ["Developer Guidelines" => "reference/developer_guidelines.md",
        "Internals" => "reference/internal.md"],
        "Public API" => "reference/public.md",
        "Stub" => "reference/stub.md"
    ],
)

makedocs(
    modules = [PowerSystemsUpdater],
    format = Documenter.HTML(
        prettyurls = haskey(ENV, "GITHUB_ACTIONS"),
        size_threshold = nothing,),
    sitename = "github.com/Sienna-Platform/PowerSystemsUpdater.jl",
    authors = "Freddy Mercury",
    pages = Any[p for p in pages],
    draft = false,
    plugins = [links, fallbacks],
)

deploydocs(
    repo="github.com/Sienna-Platform/PowerSystemsUpdater.jl",
    target="build",
    branch="gh-pages",
    devbranch="main",
    devurl="dev",
    push_preview=true,
    versions=["stable" => "v^", "v#.#"],
)

