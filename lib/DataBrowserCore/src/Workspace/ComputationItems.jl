"""
The workspace whose kept results `data` and `metadata` of a `Computation` read. Outside of it, `data`
runs the call and its inputs directly.
"""
const CURRENT_WORKSPACE = ScopedValue{Union{Nothing,Workspace}}(nothing)

# A computation is an item whose data is its result. The workspace in scope keeps the result, and
# knows the row whose value a computation gives.
function evaluate_in_scope(value::Computation)
    workspace = CURRENT_WORKSPACE[]
    return workspace === nothing ? evaluate(value) : evaluate(workspace, value)
end
function row_key(value::Computation)::Union{Nothing,RowKey}
    workspace = CURRENT_WORKSPACE[]
    workspace === nothing && return nothing
    target = @lock workspace.catalog.lock get(workspace.catalog.computation_targets, value, nothing)
    return target === nothing ? nothing : first(current_target(workspace, target))
end

function data(value::Computation)
    result = evaluate_in_scope(value)
    return result isa AbstractDataItem ? data(result) : result
end

# The metadata of a row, or else the named parts of the result, on top of the metadata of the one
# item the computation reads.
function metadata(value::Computation)
    key = row_key(value)
    key isa ItemKey && return Dict{Symbol,Any}(metadata(CURRENT_WORKSPACE[], key))
    read = [x for x in value.args if x isa AbstractDataItem]
    given = length(read) == 1 ? metadata_dict(metadata(only(read))) : MetadataDict()
    return Dict{Symbol,Any}(merge(given, parts(evaluate_in_scope(value))))
end

DataBrowserAPI.members(value::Computation) = AbstractDataItem[x for x in value.args if x isa AbstractDataItem]

"""
    select(workspace, items::AbstractVector) -> Selection

The items as a [`Selection`](@ref), without adding them to the workspace: computations, each an item
whose data is its result, or the items that functions returned. The results of the computations are
computed now, and the workspace keeps them.
"""
function select(workspace::Workspace, items::AbstractVector)::Selection
    with(CURRENT_WORKSPACE => workspace) do
        names = [x isa Computation ? computed_name(workspace, x) : (id(x), label(x)) for x in items]
        Selection(ItemData(workspace, items), first.(names), last.(names), metadata.(items))
    end
end

# The id and the label of a computation in a selection: those of its row, or of the item it gives,
# such as the selected rows of an item; or else its function, then each argument, the rows by their
# ids, then its settings.
function computed_name(workspace::Workspace, value::Computation)
    key, catalog = row_key(value), workspace.catalog
    key === nothing || return @lock catalog.lock (id(catalog, key), key isa SourceKey ? id(catalog, key) : label(catalog, key))
    result = evaluate(workspace, value)
    result isa AbstractDataItem && return (id(result), label(result))
    name = stored_id(workspace, value)
    return (name, name)
end

"""The revision of a computation and the inputs it reads, without evaluating them."""
revision(workspace::Workspace, value::Computation) =
    @lock workspace.catalog.lock something(computation_revision(workspace.catalog, value), UInt(0))

"""
    computation(selection, index) -> Computation

The computation producing one selected item. This reads its reference without loading its data.
"""
function computation(selection::Selection, index::Integer)
    data = selection.data::ItemData
    item = getfield(data, :items)[index]
    return item isa Computation ? item : computation(getfield(data, :workspace), item)
end

computation_inputs(selection::Selection) = Computation[computation(selection, i) for i in eachindex(selection)]
# A function of a whole selection reads its items' data through the workspace, when it uses it.
evaluate_argument(selection::Selection, _, _, _) = selection
