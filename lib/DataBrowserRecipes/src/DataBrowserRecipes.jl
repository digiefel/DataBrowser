"""
The registration dialect: `define_project`, `register_item!`, `register_collection!`.

This is a convenience layer written over ordinary `(data, metadata)` values, and nothing more. It
holds no privileged position in the engine: its recipes become methods of `read` and `process`,
the functions of `DataBrowserAPI` that any project implements, so a registered project and an
equivalent typed project run the same calls, cache on the same terms, and rehydrate the same way.

Being built purely on the public type API makes this package a living conformance test of that
extension surface — the role `DataBrowserPlots` plays for the GUI extension surface. If something
here needs a private hook, the type API is missing something.
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
