"""
The dialect's implementation of the typed stage contract.

Every registration callback runs through these adapter methods over the same stage runners and work
keys as a typed project's methods. Nothing here is privileged: the engine calls `read` and
`process`, and this file answers them. A registered `analyze` callback runs inside `process`.
"""

"""Split the documented `(data=..., metadata=Dict(...))` result form."""
function _data_and_metadata(value)::Tuple{Any,Dict{Symbol,Any}}
    if value isa NamedTuple && keys(value) == (:data, :metadata)
        return value.data, metadata_dict(value.metadata)
    end
    return value, Dict{Symbol,Any}()
end

function _with_data(item::RegisteredDataItem, data)::RegisteredDataItem
    return RegisteredDataItem(item, data)
end

# The item with `analysis` merged over its metadata.
_with_metadata(item::RegisteredDataItem{K}, analysis::Dict{Symbol,Any}) where {K} = RegisteredDataItem{K}(
    item.id, item.data, merge(item.metadata, analysis))


"""
Select the recipe registered under one name.

The one dynamic step in the dialect. Everything downstream takes the returned recipe by value, so
its concrete parameters specialize the rest of the call.
"""
_recipe(project::Project, kind::Symbol)::Union{Nothing,ItemRecipe} =
    (i = findfirst(r -> r.kind === kind, project.recipes); i === nothing ? nothing : project.recipes[i])

"""Select the first recipe whose `detect` accepts a source item; registration order decides ties."""
function _detect_recipe(
    project::Project,
    source_item::AbstractDataSourceItem,
)::Union{Nothing,ItemRecipe}
    for recipe in project.recipes
        _detects(recipe, source_item) && return recipe
    end
    return nothing
end

_detects(recipe::ItemRecipe, source_item::AbstractDataSourceItem)::Bool =
    recipe.detect(source_item)::Bool


"""
Adapt one registration callback result into a `RegisteredDataItem`.

This translates the registration dialect (entry tuples and callback-supplied keys) into the item
contract.

Identity is the dialect's job, not the engine's: `id(item)` is verbatim for every item type, so this
builds one from the source item, the registration, and either the `id` callback's value or the
entry's position. A `register_item!` user never supplies or sees it.
"""
function _registered_item(
    recipe::ItemRecipe{<:Any,<:Any,<:Any,<:Any,Label,Id},
    value,
    inherited_metadata::Dict{Symbol,Any},
    source_item_id::AbstractString,
    position::Integer,
)::RegisteredDataItem where {Label,Id}
    data, entry_metadata = _data_and_metadata(value)
    local_metadata = merge(copy(inherited_metadata), entry_metadata)
    supplied_key = recipe.id === nothing ? nothing : recipe.id(data, local_metadata)
    key = supplied_key === nothing || supplied_key == "" ?
        string(position) : string(supplied_key)
    item_id = "$(source_item_id)#$(recipe.kind):$(key)"
    return RegisteredDataItem{recipe.kind}(item_id, data, local_metadata)
end


project_name(project::Project)::String = project.name
project_description(project::Project)::String = project.description

function _processed_item(
    recipe::ItemRecipe,
    item::RegisteredDataItem,
)::RegisteredDataItem
    processed = recipe.process === nothing ? item : _with_data(item, recipe.process(item.data, item.metadata))
    recipe.analyze === nothing && return processed
    analysis = @timed_dbg "recipe.analyze" metadata_dict(recipe.analyze(processed.data, processed.metadata))
    return _with_metadata(processed, analysis)
end

"""
Process one registered item through its `process` callback, then its `analyze` callback, whose
metadata the processed item gets.
"""
function process(project::Project, item::RegisteredDataItem{K})::AbstractDataItem where {K}
    recipe = _recipe(project, K)
    recipe === nothing && error("Missing registration $K")
    return _processed_item(recipe, item)
end

"""Label one registered item through its `label` callback, or with its id when there is none."""
function label(project::Project, item::RegisteredDataItem{K})::String where {K}
    recipe = _recipe(project, K)
    recipe === nothing && error("Missing registration $K")
    recipe.label === nothing && return item.id
    return String(recipe.label(item.data, item.metadata))
end

# FIXME(rebuild): make the registration's items from what its `read` callback returns, as the
# deleted `expand` did with `_registered_item`; and a source item that no registration detects.
"""Run the matching registration's `read` callback and return its value unchanged."""
function read(project::Project, ::AbstractDataSource, item::AbstractDataSourceItem)
    recipe = @timed_dbg _detect_recipe(project, item)
    recipe === nothing && return nothing
    return @timed_dbg "read" _invoke_read(recipe, item)
end

_invoke_read(recipe::ItemRecipe, item::AbstractDataSourceItem) = recipe.read(item)

"""
The registered callbacks that run `stage`. Registering a name again replaces them, so an open
workspace sees the change. Every registration's `detect` decides which `read` runs, so reading
depends on all of them.
"""
function stage_roots(project::Project, stage::DataBrowserAPI.PipelineStage, type::Type)::Vector
    # The methods that apply, as for any project: typed items may have their own.
    roots = invoke(stage_roots, Tuple{AbstractProject,DataBrowserAPI.PipelineStage,Type}, project, stage, type)
    if stage == DataBrowserAPI.SOURCE_READ
        append!(roots, getfield(recipe, name) for recipe in project.recipes for name in (:detect, :read, :label, :id))
    else
        recipe = type <: RegisteredDataItem ? _recipe(project, label(type)) : nothing
        # Labels are made again after processing.
        recipe === nothing || append!(roots, (recipe.process, recipe.analyze, recipe.label))
    end
    return roots
end

# The code a stage runs is the registration of the recipe whose callback it calls.
function Base.which(project::Project, stage::DataBrowserAPI.PipelineStage, value)::Union{Method,LineNumberNode,Nothing}
    A = DataBrowserAPI
    if value isa AbstractDataSourceItem
        recipe = _detect_recipe(project, value)
        return recipe === nothing ? nothing : recipe.registered
    elseif value <: RegisteredDataItem && stage == A.ITEM_PROCESS
        recipe = _recipe(project, label(value))
        recipe === nothing && return nothing
        return recipe.process === nothing && recipe.analyze === nothing ? nothing : recipe.registered
    end
    # Typed items may have their own methods.
    return invoke(which, Tuple{AbstractProject,A.PipelineStage,Any}, project, stage, value)
end
