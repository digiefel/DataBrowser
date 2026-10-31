"""
The dialect's implementation of the typed stage contract.

Every registration callback runs through these adapter methods over the same stage runners and work
keys as a typed project's methods. Nothing here is privileged: the engine calls `read`, `expand` and
`process`, and this file answers them. A registered `analyze` callback runs inside `process`.
"""

"""Split the documented `(data=..., metadata=Dict(...))` result form."""
function _data_and_metadata(value)::Tuple{Any,MetadataDict}
    if value isa NamedTuple && keys(value) == (:data, :metadata)
        return value.data, metadata_dict(value.metadata)
    end
    return value, MetadataDict()
end

function _with_data(item::RegisteredDataItem, data)::RegisteredDataItem
    return RegisteredDataItem(item, data)
end

# The item with `analysis` merged over its metadata.
_with_metadata(item::RegisteredDataItem{K}, analysis::MetadataDict) where {K} = RegisteredDataItem{K}(
    item.id, item.label, item.collection, item.data, merge(item.metadata, analysis))


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


"""The collections that the result of a `collection` callback names, from the top level down."""
function _registration_collections(value)::Vector{AbstractCollection}
    value isa NamedTuple || throw(ArgumentError(
        "a register_item! collection callback must return a named tuple that names each level, " *
        "such as (wafer = \"W1\", device = \"A\"); got $(repr(value))",
    ))
    return AbstractCollection[
        NamedCollection{level}(string(name)) for (level, name) in pairs(value)]
end


"""
Adapt one registration callback result into a `RegisteredDataItem`.

This translates the registration dialect (entry tuples, callback-supplied keys, labels, and
named collection levels) into the item contract. A recipe without a `collection` callback leaves the path
empty, and the engine applies the source's default placement afterwards — the same rule typed items
get.

Identity is the dialect's job, not the engine's: `id(item)` is verbatim for every item type, so this
builds one from the source item, the registration, and either the `id` callback's value or the
entry's position. A `register_item!` user never supplies or sees it.
"""
function _registered_item(
    recipe::ItemRecipe{<:Any,<:Any,<:Any,<:Any,<:Any,Label,Collection,Id},
    value,
    inherited_metadata::MetadataDict,
    source_item_id::AbstractString,
    position::Integer,
)::RegisteredDataItem where {Label,Collection,Id}
    data, entry_metadata = _data_and_metadata(value)
    local_metadata = merge(copy(inherited_metadata), entry_metadata)
    collection_path = recipe.collection === nothing ? AbstractCollection[] :
        _registration_collections(recipe.collection(data, local_metadata))
    supplied_key = recipe.id === nothing ? nothing : recipe.id(data, local_metadata)
    key = supplied_key === nothing || supplied_key == "" ?
        string(position) : string(supplied_key)
    item_id = "$(source_item_id)#$(recipe.kind):$(key)"
    return RegisteredDataItem{recipe.kind}(
        item_id,
        item_id,
        collection_path,
        data,
        local_metadata,
    )
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

"""
Run the matching registration's `read` callback and return its value unchanged. Expansion has
its source item and resolves its registration there; no recipe tag is attached to user data.
"""
function read(project::Project, ::AbstractDataSource, item::AbstractDataSourceItem)
    recipe = @timed_dbg _detect_recipe(project, item)
    recipe === nothing && return nothing
    return @timed_dbg "read" _invoke_read(recipe, item)
end

_invoke_read(recipe::ItemRecipe, item::AbstractDataSourceItem) = recipe.read(item)

function expand(project::Project, source_item::AbstractDataSourceItem, loaded)::Vector{AbstractDataItem}
    recipe = @timed_dbg _detect_recipe(project, source_item)
    recipe === nothing && return AbstractDataItem[]
    return @timed_dbg "expand" _expand_recipe(recipe, source_item, loaded)
end

function _expand_recipe(recipe::ItemRecipe, source_item::AbstractDataSourceItem, loaded)
    data, read_metadata = _data_and_metadata(loaded)
    inherited_metadata = merge(metadata_dict(metadata(source_item)), read_metadata)
    values = recipe.expand === nothing ? Any[data] : recipe.expand(data, inherited_metadata)
    values isa AbstractVector || error(
        "expand callback for registration $(recipe.kind) must return a vector; got $(typeof(values))")
    return AbstractDataItem[
        _registered_item(recipe, value, inherited_metadata, id(source_item), position)
        for (position, value) in pairs(values)]
end


"""
Give a collection the metadata of each kind's registered collection `analyze`, computed from its
members of that kind. A collection that a `collection` callback did not name falls through to its
typed `process`.
"""
function process(
    project::Project,
    collection_value::AbstractCollection,
    items::AbstractVector,
)::AbstractCollection
    collection_value isa NamedCollection || return process(collection_value, items)
    analysis = MetadataDict()
    for positions in _group_positions_by_kind(items)
        group = items[positions]
        recipe = first(group) isa RegisteredDataItem ?
            get(project.collections, label(typeof(first(group))), nothing) : nothing
        recipe === nothing && continue
        merge!(analysis, metadata_dict(recipe.analyze(item_data.(group), metadata.(group))))
    end
    return typeof(collection_value)(collection_value.name, merge(metadata(collection_value), analysis))
end

"""A registered item gets the metadata of each collection above it."""
process(::Project, member::RegisteredDataItem, collection_value::NamedCollection)::RegisteredDataItem =
    _with_metadata(member, metadata(collection_value))

"""
The registered callbacks that run `stage`. Registering a name again replaces them, so an open
workspace sees the change. Every registration's `detect` decides which `read` runs, so reading
depends on all of them.
"""
function stage_roots(project::Project, stage::DataBrowserAPI.PipelineStage, type::Type)::Vector
    # The methods that apply, as for any project: typed items and collections may have their own.
    roots = invoke(stage_roots, Tuple{AbstractProject,DataBrowserAPI.PipelineStage,Type}, project, stage, type)
    if stage == DataBrowserAPI.SOURCE_READ
        append!(roots, getfield(recipe, name) for recipe in project.recipes
            for name in (:detect, :read, :expand, :label, :collection, :id))
    elseif stage == DataBrowserAPI.ITEM_PROCESS
        recipe = type <: RegisteredDataItem ? _recipe(project, label(type)) : nothing
        # Labels are made again after processing.
        recipe === nothing || append!(roots, (recipe.process, recipe.analyze, recipe.label))
    else
        append!(roots, recipe.analyze for recipe in values(project.collections))
    end
    return roots
end

# The code a stage runs is the registration of the recipe whose callback it calls.
function Base.which(project::Project, stage::DataBrowserAPI.PipelineStage, value)::Union{Method,LineNumberNode,Nothing}
    A = DataBrowserAPI
    if value isa AbstractDataSourceItem
        recipe = _detect_recipe(project, value)
        recipe === nothing && return nothing
        return stage == A.SOURCE_READ || recipe.expand !== nothing ? recipe.registered : nothing
    elseif value <: RegisteredDataItem && stage == A.ITEM_PROCESS
        recipe = _recipe(project, label(value))
        recipe === nothing && return nothing
        return recipe.process === nothing && recipe.analyze === nothing ? nothing : recipe.registered
    elseif stage in (A.COLLECTION_PROCESS, A.MEMBER_PROCESS) && length(project.collections) == 1
        # TODO: a collection recipe belongs to the kind of its members, which the collection type
        # does not say; with several, the browser shows none.
        return only(values(project.collections)).registered
    end
    # Typed items and collections may have their own methods.
    return invoke(which, Tuple{AbstractProject,A.PipelineStage,Any}, project, stage, value)
end

"""
A collection stage is defined when any kind registered a collection recipe, or the collection type
has a method.
"""
has_stage(project::Project, collection_value::AbstractCollection, stage::DataBrowserAPI.PipelineStage)::Bool =
    !isempty(project.collections) || has_stage(collection_value, stage)

"""Group item positions by kind, preserving first-seen kind order."""
function _group_positions_by_kind(items::AbstractVector)::Vector{Vector{Int}}
    groups = Dict{Tuple{Bool,Symbol},Vector{Int}}()
    order = Tuple{Bool,Symbol}[]
    for (position, item) in pairs(items)
        key = (item isa RegisteredDataItem, label(typeof(item)))
        haskey(groups, key) || push!(order, key)
        push!(get!(() -> Int[], groups, key), position)
    end
    return Vector{Int}[groups[key] for key in order]
end
