"""
The types and functions that connect projects, sources, stores and visualizers to the workspace.

A project defines methods of `read` and `process` for its item types, a source lists its source
items with `items`, a store saves the results of the workspace, and a visualizer shows a value in a
window of the browser. `DataBrowserCore` calls these functions. `DataBrowserSources`,
`DataBrowserCache`, `DataBrowserRecipes`, `DataBrowserGUI` and `DataBrowserPlots` define methods of
them, as a project does.
"""
module DataBrowserAPI

using Dates

# A project reads a source item with a method of `Base.read`, the function that Julia users know
# for reading files. Extending it keeps `using DataBrowser` from hiding `Base.read` behind a
# function of the same name.
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
