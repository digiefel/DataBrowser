"""
Headless workspace engine: the catalog of rows and jobs, and the workspace lifecycle over it and
the `DataBrowserCache` store.
"""
module DataBrowserCore

using DataBrowserAPI
using DataBrowserSources
using DataBrowserAPI: @timed_dbg

include("project_engine.jl")
include("Catalogs.jl")
include("CodeRevisions.jl")
include("Workspace.jl")

using .Workspace:
    open_workspace,
    close_workspace!,
    wait_workspace_idle!,
    workspace_status,
    query_items,
    select_items!,
    select,
    Selection,
    materialize_items,
    read_item_data,
    Tag,
    tags,
    tag!,
    untag!

export items_for_file,
    open_workspace,
    close_workspace!,
    wait_workspace_idle!,
    workspace_status,
    query_items,
    select_items!,
    select,
    Selection,
    materialize_items,
    read_item_data,
    Tag,
    tags,
    tag!,
    untag!

end
