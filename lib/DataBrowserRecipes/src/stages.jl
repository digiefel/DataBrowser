"""
The dialect's implementation of the typed stage contract.

Every registration callback runs through these adapter methods over the same stage runners and work
keys as a typed project's methods. Nothing here is privileged: the engine calls `read` and
`process`, and this file answers them. A registered `analyze` callback runs inside `process`, and
`expand` in the `process` of what `read` gave. The `process` of the group of the source folder makes
the collections and runs their callbacks, and the member `process` of each collection gives the
items below it their new data and metadata.
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
_recipe(project::Project, ::Type{<:Union{RegisteredDataItem{K},ReadData{K}}}) where {K} = _recipe(project, K)

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
    recipe::ItemRecipe,
    value,
    inherited_metadata::Dict{Symbol,Any},
    source_item_id::AbstractString,
    position::Integer,
)::RegisteredDataItem
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

"""
Make the items of a registration with `expand` from what its `read` callback gave, and process each
of them as above.
"""
function process(project::Project, value::ReadData{K})::Vector{RegisteredDataItem{K}} where {K}
    recipe = _recipe(project, K)
    recipe === nothing && error("Missing registration $K")
    entries = @timed_dbg "expand" recipe.expand(value.data, value.metadata)
    entries isa AbstractVector || error(
        "expand callback for registration $K must return a vector; got $(typeof(entries))")
    return RegisteredDataItem{K}[_processed_item(recipe, _registered_item(recipe, entry, value.metadata, value.id, position))
        for (position, entry) in pairs(entries)]
end

"""Label one registered item through its `label` callback, or with its id when there is none."""
function label(project::Project, item::RegisteredDataItem{K})::String where {K}
    recipe = _recipe(project, K)
    recipe === nothing && error("Missing registration $K")
    recipe.label === nothing && return item.id
    return String(recipe.label(item.data, item.metadata))
end

"""
Run the `read` callback of the registration that detects the source item. Without `expand`, the
result is the item of the source item; with `expand`, it is what `process` makes the items from. A
source item that no registration detects gives no value.
"""
function read(project::Project, ::AbstractDataSource, source_item::AbstractDataSourceItem)
    recipe = @timed_dbg _detect_recipe(project, source_item)
    recipe === nothing && return AbstractDataItem[]
    data, read_metadata = _data_and_metadata(@timed_dbg "read" _invoke_read(recipe, source_item))
    carrier = recipe.expand === nothing ? RegisteredDataItem{recipe.kind} : ReadData{recipe.kind}
    return carrier(id(source_item), data, merge(metadata_dict(metadata(source_item)), read_metadata))
end

_invoke_read(recipe::ItemRecipe, item::AbstractDataSourceItem) = recipe.read(item)

"""
Make the collections that the `collection` callbacks name for the items below the source folder,
and run the callbacks registered for the level of each collection over the items below it. The id
of a collection names its levels from the top down, as `wafer:W1/device:A`. Other groups make
nothing.
"""
# TODO: only the group of the folder of a `DirectorySource` has the id "."; the items of other
# sources are in no collection.
function process(project::Project, folder::SourceGroup, items::AbstractVector{RegisteredDataItem})::Vector{NamedCollection}
    id(folder) == "." || return NamedCollection[]
    # Each collection, by id in the order they are named, with the items below it.
    found, below, order = Dict{String,NamedCollection}(), Dict{String,Vector{RegisteredDataItem}}(), String[]
    for item in items
        recipe = _recipe(project, typeof(item))
        (recipe === nothing || recipe.collection === nothing) && continue
        path = recipe.collection(item.data, item.metadata)
        path isa NamedTuple || throw(ArgumentError(
            "a register_item! collection callback must return a named tuple that names each level, " *
            "such as (wafer = \"W1\", device = \"A\"); got $(repr(path))"))
        x = ""
        for (level, name) in pairs(path)
            above, x = x, (isempty(x) ? "" : x * "/") * "$level:$name"
            if !haskey(found, x)
                found[x], below[x] = NamedCollection{level}(x, string(name)), RegisteredDataItem[]
                push!(order, x)
                isempty(above) || push!(found[above].members, x)
            end
            push!(below[x], item)
        end
        isempty(x) || push!(found[x].members, item.id)
    end
    for x in order, recipe in project.collections
        collection = found[x]
        recipe.level === label(typeof(collection)) || continue
        group = recipe.members === nothing ? below[x] : filter(item -> label(typeof(item)) === recipe.members, below[x])
        isempty(group) && continue
        outputs = data.(group)
        if recipe.process !== nothing
            outputs = recipe.process(outputs, metadata.(group))
            outputs isa AbstractVector && length(outputs) == length(group) || error(
                "collection process for level $(recipe.level) must return a vector with one value per member; " *
                "got $(typeof(outputs)) for $(length(group)) members")
            for (item, output) in zip(group, outputs)
                collection.data[item.id] = output
            end
        end
        recipe.analyze === nothing ||
            merge!(collection.metadata, metadata_dict(recipe.analyze(outputs, metadata.(group))))
    end
    return NamedCollection[found[x] for x in order]
end

"""A registered item gets its new data and the metadata of its collection."""
process(::Project, member::RegisteredDataItem, collection::NamedCollection)::RegisteredDataItem =
    _with_metadata(_with_data(member, get(collection.data, id(member), member.data)), metadata(collection))

"""A collection gets the new data and the metadata of the collection above it, for the items below it."""
process(::Project, member::NamedCollection, collection::NamedCollection)::NamedCollection =
    typeof(member)(member.id, member.name, member.members,
        merge(member.data, collection.data), merge(member.metadata, collection.metadata))

"""
The registered callbacks that run `stage`. Registering a name again replaces them, so an open
workspace sees the change. Every registration's `detect` decides which `read` runs, and its
`expand` whether the result is an item, so reading depends on all of them.
"""
function stage_roots(project::Project, stage::DataBrowserAPI.PipelineStage, type::Type)::Vector
    A = DataBrowserAPI
    # The methods that apply, as for any project: typed items may have their own.
    roots = invoke(stage_roots, Tuple{AbstractProject,A.PipelineStage,Type}, project, stage, type)
    if stage == A.SOURCE_READ
        append!(roots, getfield(recipe, name) for recipe in project.recipes for name in (:detect, :read, :expand, :label))
    elseif stage == A.GROUP_PROCESS && type <: SourceGroup
        append!(roots, recipe.collection for recipe in project.recipes)
        append!(roots, getfield(recipe, name) for recipe in project.collections for name in (:process, :analyze))
    elseif stage == A.ITEM_PROCESS && type <: Union{RegisteredDataItem,ReadData}
        recipe = _recipe(project, type)
        # Labels are made again after processing.
        names = type <: ReadData ? (:expand, :id, :process, :analyze, :label) : (:process, :analyze, :label)
        recipe === nothing || append!(roots, getfield(recipe, name) for name in names)
    end
    return roots
end

# The code a stage runs is the registration of the recipe whose callback it calls.
function Base.which(project::Project, stage::DataBrowserAPI.PipelineStage, value)::Union{Method,LineNumberNode,Nothing}
    A = DataBrowserAPI
    if value isa AbstractDataSourceItem
        recipe = _detect_recipe(project, value)
        return recipe === nothing ? nothing : recipe.registered
    elseif value <: Union{RegisteredDataItem,ReadData} && stage == A.ITEM_PROCESS
        recipe = _recipe(project, value)
        recipe === nothing && return nothing
        return value <: RegisteredDataItem && recipe.process === nothing && recipe.analyze === nothing ? nothing : recipe.registered
    elseif value <: SourceGroup && stage == A.GROUP_PROCESS
        registered = [[recipe.registered for recipe in project.collections];
            [recipe.registered for recipe in project.recipes if recipe.collection !== nothing]]
        return isempty(registered) ? nothing : first(registered)
    elseif value <: NamedCollection
        index = findfirst(recipe -> recipe.level === label(value), project.collections)
        return index === nothing ? nothing : project.collections[index].registered
    end
    # Typed items may have their own methods.
    return invoke(which, Tuple{AbstractProject,A.PipelineStage,Any}, project, stage, value)
end
