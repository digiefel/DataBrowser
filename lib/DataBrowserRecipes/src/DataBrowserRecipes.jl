"""
The registration dialect: `define_project`, `register_item!`, `register_collection!`.

This is a convenience layer written over ordinary `(data, metadata)` values, and nothing more. It
holds no privileged position in the engine: its recipes become methods of the same typed stage
contract in `DataBrowserAPI` that any project implements, so a registered project and an equivalent
typed project traverse the same stages, cache on the same terms, and rehydrate the same way.

Being built purely on the public type API makes this package a living conformance test of that
extension surface — the role `DataBrowserPlots` plays for the GUI extension surface. If something
here needs a private hook, the type API is missing something.
"""
module DataBrowserRecipes

using CSV: CSV
using DataFrames: DataFrame
using DataBrowserAPI
using DataBrowserAPI:
    AbstractCollection,
    AbstractDataItem,
    AbstractDataSource,
    AbstractDataSourceItem,
    AbstractProject,
    @timed_dbg
import DataBrowserAPI:
    expand,
    has_stage,
    stage_roots,
    collection,
    id,
    data,
    label,
    metadata,
    process,
    project_description,
    project_name,
    read,
    reconstruct
using DataBrowserAPI: MetadataDict, metadata_dict
using DataBrowserSources: SourceFile
using DataBrowserCache: DuckDBStore

include("carriers.jl")
include("recipes.jl")
include("registration.jl")
include("stages.jl")
include("premade.jl")

export define_project,
    register_collection!,
    register_csv!,
    register_item!

end
