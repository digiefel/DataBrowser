module DataBrowserCoreDataFramesExt

using DataFrames: DataFrames, DataFrame
using DataBrowserCore: Workspace as W

"""
    DataFrame(workspace) -> DataFrame
    DataFrame(workspace, items) -> DataFrame

A table with one row per item: every item of a workspace, or the items given, in the same order.
Give the items as [`items`](@ref DataBrowserCore.Workspace.items) returns them, or as public ids.

The columns are `id`, `label`, `collection` (the labels of the collections that hold the item, from
the top level down, joined with `/`) and `tags` (the names of the tags of the item), then one
column for each metadata key. A row has `missing` where its item has no value for a key.

    using DataFrames
    DataFrame(workspace, items(workspace, !Tag("bad")))

The data of the items is not read.
"""
DataFrames.DataFrame(workspace::W.Workspace)::DataFrame = DataFrame(workspace, W.items(workspace))

function DataFrames.DataFrame(workspace::W.Workspace, items::AbstractVector)::DataFrame
    keys = [W.key(workspace, item) for item in items]
    table = DataFrame(
        id=[W.id(workspace, key) for key in keys],
        label=[W.label(workspace, key) for key in keys],
        collection=[join((W.label(workspace, above) for above in W.ancestors(workspace, key)), '/') for key in keys],
        tags=[[tag.name for tag in W.tags(workspace, key)] for key in keys],
    )
    rows = [W.metadata(workspace, key) for key in keys]
    # TODO: a metadata key named like one of the four columns above is left out.
    names = Set{Symbol}()
    foreach(row -> union!(names, Base.keys(row)), rows)
    for name in sort!(collect(setdiff(names, propertynames(table))))
        table[!, name] = [get(row, name, missing) for row in rows]
    end
    return table
end

end
