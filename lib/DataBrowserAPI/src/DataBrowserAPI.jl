"""
Payload-agnostic project and item contracts for DataBrowser.

The project contract, the calls of a project, the source and item contracts, and the
visualizer contract live here. The registration dialect lives in `DataBrowserRecipes`, plot registration and rendering in
`DataBrowserPlots`; both are ordinary clients of what this package declares.
"""
module DataBrowserAPI

using Dates

# `read` is the call that reads the source, which is exactly what `Base.read` means.
# Extending it keeps `using DataBrowser` from shadowing a function every Julia user already knows.
import Base: read

include("project_contract.jl")
include("metadata_types.jl")
include("source_contract.jl")
include("item_contract.jl")
include("computation_contract.jl")
include("storage_contract.jl")
include("pipeline_contract.jl")
include("visualizer_contract.jl")
include("timing_debug.jl")
include("errors.jl")

export AbstractProject,
    AbstractDataSource,
    AbstractDataSourceItem,
    AbstractDataItem,
    AbstractGroup,
    SourceGroup,
    AbstractVisualizer,
    Computation,
    ComputationExecution,
    last_execution,
    computation,
    inputs,
    evaluate,
    AbstractStore,
    storage,
    stored_size,
    cache_info,
    Setting,
    open_source,
    close_source!,
    watch_source,
    items,
    fingerprint,
    process,
    reconstruct,
    id,
    label,
    metadata,
    members,
    prepare!,
    settings,
    initial_size,
    draw_header!,
    export!,
    draw!,
    output,
    select!,
    selection

end
