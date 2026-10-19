"""
Payload-agnostic project and item contracts for DataBrowser.

The project contract, the typed pipeline stage contract, the source and item contracts, and the
visualizer contract live here. The registration dialect lives in `DataBrowserRecipes`, plot registration and rendering in
`DataBrowserPlots`; both are ordinary clients of what this package declares.
"""
module DataBrowserAPI

using Dates

# `read` is the pipeline's source-touching stage, and that is exactly what `Base.read` means.
# Extending it keeps `using DataBrowser` from shadowing a function every Julia user already knows.
import Base: read

include("project_contract.jl")
include("metadata_types.jl")
include("source_contract.jl")
include("item_contract.jl")
include("stage_contract.jl")
include("visualizer_contract.jl")
include("timing_debug.jl")
include("errors.jl")

export AbstractProject,
    AbstractDataSource,
    AbstractDataSourceItem,
    AbstractDataItem,
    AbstractCollection,
    AbstractVisualizer,
    Setting,
    open_source,
    close_source!,
    watch_source,
    items,
    fingerprint,
    expand,
    process,
    analyze,
    has_stage,
    stage_roots,
    reconstruct,
    id,
    label,
    collection,
    metadata,
    item_data,
    prepare!,
    settings,
    draw_header!,
    export!,
    draw!,
    output

end
