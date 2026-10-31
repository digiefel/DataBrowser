# A project whose items are given values, each with its data and metadata.
using DataBrowserCore: Workspace

struct ItemsProject <: DataBrowserAPI.AbstractProject end
struct ItemsSource <: DataBrowserAPI.AbstractDataSource
    entries::Vector
end
struct ItemsFile <: DataBrowserAPI.AbstractDataSourceItem end
struct Entry <: DataBrowserAPI.AbstractDataItem
    name::String
    data::Any
    metadata::Dict{Symbol,Any}
end
DataBrowserAPI.project_name(::ItemsProject) = "items"
DataBrowserAPI.id(::ItemsSource) = "items"
DataBrowserAPI.label(::ItemsSource) = "items"
DataBrowserAPI.items(::ItemsSource; kwargs...) = [ItemsFile()]
DataBrowserAPI.id(::ItemsFile) = "file"
DataBrowserAPI.label(::ItemsFile) = "file"
DataBrowserAPI.fingerprint(::ItemsFile) = 1
DataBrowserAPI.read(::ItemsProject, source::ItemsSource, ::ItemsFile) = source.entries
DataBrowserAPI.expand(::ItemsProject, ::ItemsFile, entries) = entries
DataBrowserAPI.id(entry::Entry) = entry.name
DataBrowserAPI.metadata(entry::Entry) = entry.metadata
DataBrowserAPI.data(entry::Entry) = entry.data

# The workspaces that `selection_of` opened, closed at the end of the file that includes this one.
const OPENED = Workspace.Workspace[]

# The items `(label, data, metadata)` as the selection of a workspace of their own.
function selection_of(entries...)
    workspace = Workspace.open_workspace(ItemsProject(),
        ItemsSource([Entry(label, data, Dict{Symbol,Any}(pairs(metadata))) for (label, data, metadata) in entries]); cache=false)
    push!(OPENED, workspace)
    Workspace.wait_workspace_idle!(workspace)
    return Workspace.select(workspace, String[label for (label, _, _) in entries])
end
