"""
Payload-agnostic project and item contracts for DataBrowser.

The project contract, the typed pipeline stage contract, and the source and item contracts live
here. The registration dialect lives in `DataBrowserRecipes`, plot registration and rendering in
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
include("timing_debug.jl")

export AbstractProject,
    AbstractDataSource,
    AbstractDataSourceItem,
    AbstractDataItem,
    AbstractCollection,
    open_source,
    close_source!,
    watch_source,
    source_id,
    source_label,
    source_items,
    source_item_path,
    source_item_timestamp,
    fingerprint,
    expand,
    process,
    analyze,
    reconstruct,
    id,
    label,
    collection,
    metadata,
    item_data

end
