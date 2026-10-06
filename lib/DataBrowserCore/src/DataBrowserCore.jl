"""
Headless workspace engine: the catalog of rows and jobs, and the workspace lifecycle over it and
the `DataBrowserCache` store.
"""
module DataBrowserCore

using DataBrowserAPI
using DataBrowserAPI: source_item_path
using DataBrowserSources
using DataBrowserAPI: @timed_dbg

include("project_engine.jl")
include("Catalogs.jl")
include("Workspace.jl")

end
