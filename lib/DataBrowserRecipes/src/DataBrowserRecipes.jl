"""
The registration dialect: `define_project`, `register_item!`, `register_collection!` and
`register_csv!`, which describe a project with callbacks that take data and metadata.

Each registration defines methods of `read` and `process`, the functions of `DataBrowserAPI` that
every project implements. So a registered project runs the same calls as a project written with its
own types, keeps its results in the same stores, and rebuilds them from the cache with the same
`reconstruct`.

This package uses only the public API of `DataBrowserAPI`, as `DataBrowserPlots` does for the GUI.
So when it needs something that this API does not give, the API lacks it.
"""
module DataBrowserRecipes

using CSV: CSV
using DataFrames: DataFrame
using DataBrowserAPI
using DataBrowserAPI:
    AbstractDataItem,
    AbstractDataSource,
    AbstractDataSourceItem,
    AbstractGroup,
    AbstractProject,
    SourceGroup,
    @timed_dbg
import DataBrowserAPI:
    id,
    data,
    label,
    members,
    metadata,
    process,
    project_description,
    project_name,
    read,
    reconstruct
using DataBrowserAPI: metadata_dict
using DataBrowserSources: SourceFile
using DataBrowserCache: DuckDBStore

include("carriers.jl")
include("recipes.jl")
include("registration.jl")
include("callbacks.jl")
include("methods.jl")
include("premade.jl")

export define_project,
    register_collection!,
    register_csv!,
    register_item!

end
