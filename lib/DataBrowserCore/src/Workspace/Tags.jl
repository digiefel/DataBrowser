# Tags on the items and collections of a workspace.
#
# The tags live in `tags.txt` in the source root, and every change is written to that file at once.
# A source without a root folder keeps its tags in memory. The file names an item by its public id
# and a collection by its labels from the top level down, joined with `/`.

"""The folder that holds `tags.txt`, or `""` for a source without a root folder."""
tag_root(source::AbstractDataSource)::String =
    hasproperty(source, :root_path) ? source.root_path : ""

function WorkspaceTags(source::AbstractDataSource)::WorkspaceTags
    root = tag_root(source)
    isempty(root) && return WorkspaceTags(TagState(), "", 0)
    state = try
        Tags.load(root)
    catch error
        error isa Union{Tags.TagsParseError,Base.IOError} || rethrow()
        return WorkspaceTags(TagState(), sprint(showerror, error), 0)
    end
    # A name that the file assigns without defining it becomes a tag with the default properties.
    assigned = Set{String}()
    foreach(names -> union!(assigned, names), values(state.assignments))
    defined = Set(tag.name for tag in state.catalog)
    append!(state.catalog, Tag.(sort!(collect(setdiff(assigned, defined)))))
    return WorkspaceTags(state, "", 0)
end

"""
    tags(workspace) -> Vector{Tag}
    tags(workspace, key; inherited=true) -> Vector{Tag}

The tags defined in a workspace, or the tags of one item or collection. Give an item as one of
the values that [`items`](@ref) returns, as its public id, or as a data item.

The tags of an item or collection are its own and those of every collection above it, with the
highest priority first. With `inherited=false` they are only its own.
"""
tags(workspace::Workspace)::Vector{Tag} = copy(workspace.tags.state.catalog)

tags(workspace::Workspace, item::Union{AbstractString,AbstractDataItem}; inherited::Bool=true)::Vector{Tag} =
    tags(workspace, key(workspace, item); inherited)

function tags(
    workspace::Workspace, key::Union{ItemKey,CollectionKey}; inherited::Bool=true,
)::Vector{Tag}
    assignments = workspace.tags.state.assignments
    isempty(assignments) && return Tag[]
    names = Set{String}()
    if inherited
        path = ""
        for collection in ancestors(workspace, key)
            path = isempty(path) ? label(workspace, collection) : string(path, '/', label(workspace, collection))
            union!(names, get(assignments, path, ()))
        end
    end
    union!(names, get(assignments, tag_key(workspace, key), ()))
    isempty(names) && return Tag[]
    return sort!(filter(tag -> tag.name in names, workspace.tags.state.catalog); by=tag -> -tag.priority)
end

"""
    items(workspace, tag::Tag) -> Vector{ItemKey}
    items(workspace, !tag) -> Vector{ItemKey}

The items of a workspace that have a tag, or with `!`, the items that do not have it. An item has
the tags of the collections above it.

    items(workspace, !Tag("bad"))
"""
function items(workspace::Workspace, tag::Tag)::Vector{ItemKey}
    name = tag_name(workspace, tag)
    return filter(key -> any(found -> found.name == name, tags(workspace, key)), items(workspace))
end

function items(workspace::Workspace, condition::Untagged)::Vector{ItemKey}
    name = tag_name(workspace, condition.tag)
    return filter(key -> !any(found -> found.name == name, tags(workspace, key)), items(workspace))
end

"""
The name of an item or a collection in `tags.txt`. An item is given as its key, its public id, or
a data item.
"""
tag_key(workspace::Workspace, item::ItemKey)::String = id(workspace, item)
tag_key(workspace::Workspace, item::Union{AbstractString,AbstractDataItem})::String =
    id(workspace, key(workspace, item))
tag_key(workspace::Workspace, collection::CollectionKey)::String =
    join((label(workspace, key) for key in [ancestors(workspace, collection); collection]), '/')

"""The name of a defined tag, given the tag or its name."""
function tag_name(workspace::Workspace, tag::Union{Tag,AbstractString})::String
    name = tag isa Tag ? tag.name : String(tag)
    defined = [tag.name for tag in workspace.tags.state.catalog]
    name in defined || error(
        "This workspace has no tag named \"$name\". Define it with `tag!(workspace, Tag(\"$name\"))`." *
        (isempty(defined) ? "" : " Its tags are: " * join(defined, ", ") * "."))
    return name
end

"""Apply `change` to the tags of a workspace and write them to `tags.txt`."""
function change_tags!(change::Function, workspace::Workspace)::Nothing
    isempty(workspace.tags.error) ||
        error("Tags cannot change until tags.txt is fixed: $(workspace.tags.error)")
    lock(workspace.lifecycle_lock) do
        change(workspace.tags.state)
        root = tag_root(workspace.source)
        isempty(root) || Tags.save(root, workspace.tags.state)
        workspace.tags.revision += 1
    end
    return nothing
end

"""
    tag!(workspace, tag::Tag)
    tag!(workspace, keys, tag)

Define a tag in a workspace, or put a defined tag on items and collections.

`tag!(workspace, Tag("leaky"; color="ffaa00"))` defines the tag, or replaces the colour and
priority of the tag with that name.

`tag!(workspace, keys, tag)` puts the tag on one item or collection, or on each one of a list. Give
an item as one of the values that [`items`](@ref) returns, as its public id, or as a data item.
Give the tag or its name. A tag on a collection also applies to everything below it.
"""
function tag!(workspace::Workspace, tag::Tag)::Nothing
    change_tags!(workspace) do state
        index = findfirst(defined -> defined.name == tag.name, state.catalog)
        index === nothing ? push!(state.catalog, tag) : (state.catalog[index] = tag)
    end
end

function tag!(workspace::Workspace, keys::AbstractVector, tag::Union{Tag,AbstractString})::Nothing
    name = tag_name(workspace, tag)
    change_tags!(workspace) do state
        for key in keys
            push!(get!(() -> Set{String}(), state.assignments, tag_key(workspace, key)), name)
        end
    end
end

tag!(
    workspace::Workspace, key::Union{ItemKey,CollectionKey,AbstractString,AbstractDataItem},
    tag::Union{Tag,AbstractString},
)::Nothing = tag!(workspace, [key], tag)

"""
    untag!(workspace, keys, tag)
    untag!(workspace, tag)

Take a tag off items and collections, or remove a tag from a workspace.

`untag!(workspace, keys, tag)` takes the tag off one key or off each key of a list. A tag that an
item has from a collection above it stays; take it off that collection.

`untag!(workspace, tag)` removes the definition of the tag and takes it off everything.
"""
function untag!(workspace::Workspace, keys::AbstractVector, tag::Union{Tag,AbstractString})::Nothing
    name = tag_name(workspace, tag)
    change_tags!(workspace) do state
        for key in keys
            row = tag_key(workspace, key)
            names = get(state.assignments, row, nothing)
            names === nothing && continue
            delete!(names, name)
            isempty(names) && delete!(state.assignments, row)
        end
    end
end

untag!(
    workspace::Workspace, key::Union{ItemKey,CollectionKey,AbstractString,AbstractDataItem},
    tag::Union{Tag,AbstractString},
)::Nothing = untag!(workspace, [key], tag)

function untag!(workspace::Workspace, tag::Union{Tag,AbstractString})::Nothing
    name = tag_name(workspace, tag)
    change_tags!(workspace) do state
        filter!(defined -> defined.name != name, state.catalog)
        foreach(names -> delete!(names, name), values(state.assignments))
        filter!(row -> !isempty(last(row)), state.assignments)
    end
end
