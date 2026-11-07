# What the browser, extensions and scripts read about the values of a workspace, by their ids, from
# the latest version of the table `items`, and the task that publishes those versions.

"""
    publish!(items, workspace)

The task that publishes the versions of the table `items` of `workspace`, until `close(items)`. At
each notification of `items.event`, and at most once each `PUBLISH_INTERVAL`, it requests in the
catalog the latest versions of the ids asked for by readers, ahead of background work. Then it
computes the readiness, failure and revision of the items of the catalog rows whose state, priority
or job changed, and of the items whose cells workers wrote. When a cell changed, it stores the draft as a
new version. All this happens under the catalog lock, in one take. An error stops the task, and
readers that wait throw from then on.
"""
function publish!(items::Items, workspace::Workspace)::Nothing
    catalog, columns, last = workspace.catalog, items.columns, 0.0
    try
        while true
            wait(items.event)
            items.closed && return nothing
            sleep(max(0.0, last + PUBLISH_INTERVAL - time()))
            last = time()
            requested = @lock items.lock collect(items.requested)
            ## TODO(scale): the items of every touched row are read in one take of the catalog lock.
            shown = @lock catalog.lock begin
                for x in requested
                    haskey(workspace.versions, x) && request!(catalog, workspace.versions[x][end], VIEWED_ITEM)
                end
                for row in catalog.touched
                    stage = get(workspace.stages, row, nothing)
                    stage === nothing && continue
                    expected = stage == SOURCE_READ ? id(catalog[row].args[3]) : catalog[row].args[2].id
                    for x in [expected; [output.id for output in get(workspace.outputs, row, Output[])]]
                        number = get(items.index, x, Int32(0))
                        number == 0 || push!(items.pending, number)
                    end
                end
                empty!(catalog.touched)
                for number in items.pending
                    version = columns.version[number]
                    current = version != Catalogs.NOWHERE && Catalogs.state(catalog, version) == Catalogs.CURRENT
                    readiness = version == Catalogs.NOWHERE ? UNPROCESSED : current ? CURRENT :
                        Catalogs.stuck(catalog, version) ? FAILED :
                        Catalogs.running(catalog, version) || Catalogs.wanted(catalog, version) ? WORKING : UNPROCESSED
                    write!(items, columns.readiness, number, readiness)
                    write!(items, columns.failure, number, readiness == FAILED ? failure(workspace, version) : "")
                    write!(items, columns.revision, number, version == Catalogs.NOWHERE ? UInt64(0) :
                        hash(version.index, hash(current, hash(Catalogs.changes(catalog, version)))))
                end
                empty!(items.pending)
                shown = Set{Int32}()
                if items.changed
                    @atomic items.version = Version(items.index, map(column -> Cells(column, items.count), columns),
                        Dict{Symbol,Cells}(name => Cells(column, items.count) for (name, column) in items.metadata))
                    items.draft, items.changed, shown, items.shown = items.draft + 1, false, items.shown, shown
                    ## A window reads the `revision` of its items again when `status_revision`
                    ## rises, and a view that keeps what it read, by `generation`, reads again.
                    Threads.atomic_add!(Catalogs.CHANGES, 1)
                    Threads.atomic_add!(workspace.generation, 1)
                end
                ## `wait_workspace_idle!` waits until the cells follow the catalog.
                notify(catalog.changed)
                shown
            end
            ## The requests end with this version, or with the last one when no cell changed.
            @lock items.lock (setdiff!(items.requested, requested); union!(items.changes, shown); notify(items.published))
            isempty(shown) || notify(items.asked)
        end
    catch error
        @error "The table of the items stopped following the workspace" exception = (error, catch_backtrace())
    finally
        close(items)
    end
    return nothing
end

"""
    close(items::Items)

Stop the tasks that keep the table `items`, [`publish!`](@ref) and [`keep!`](@ref), and wake the
calls that wait for them, such as `select(workspace, f)`: they throw.
"""
function Base.close(items::Items)::Nothing
    @lock items.lock (items.closed = true; notify(items.published))
    notify(items.event)
    notify(items.asked)
    return nothing
end

# The number of the item `x` in `version`, or 0 when `version` has no item `x`.
function number(version::Version, x::AbstractString)::Int32
    n = get(version.index, x, Int32(0))
    return n != 0 && version.columns.version[n] != Catalogs.NOWHERE ? n : Int32(0)
end

"""
    items(workspace) -> Vector{String}

The ids of the values of a workspace.
"""
function items(workspace::Workspace)::Vector{String}
    columns = (@atomic workspace.items.version).columns
    return [columns.id[number] for number in eachindex(columns.id) if columns.version[number] != Catalogs.NOWHERE]
end

"""
    haskey(workspace, id) -> Bool

Whether the workspace has an item with the id `id`, as [`select`](@ref) gives it. A selection or a
saved view can name items that the workspace does not have yet, or no longer has.
"""
Base.haskey(workspace::Workspace, x::AbstractString)::Bool = number((@atomic workspace.items.version), x) != 0

# TODO(query model): an internal stand-in for the browser, until the query model of roadmap 0.5.0 has
# "it holds the value `id`" as a condition.
"""
    groups(workspace, id) -> Vector{String}

Internal. The ids of the groups that hold the value `id` among their members, as [`select`](@ref)
gives them.
"""
function groups(workspace::Workspace, x::AbstractString)::Vector{String}
    version = @atomic workspace.items.version
    n = number(version, x)
    return n == 0 ? String[] : copy(version.columns.groups[n])
end

"""A sort key that orders text with embedded integers by the value of those integers."""
natural_key(text::AbstractString)::Tuple = Tuple(
    all(isdigit, part.match) ? (1, parse(Int, part.match)) : (0, lowercase(part.match))
    for part in eachmatch(r"\d+|\D+", String(text)))

"""
    SortKeys(keys)

Internal. An order of the items by keys of their rows, to give as both `by` and `lt` to
[`sort!`](@ref): `keys` holds `key => reverse` pairs, where `key` is `:label`, `:id` or a metadata
key. The items sort by the first key, then by the second where the first is equal, and so on. Text
sorts with the numbers in it by their value, and an item without a key sorts after the items with
it, in both directions. The workspace sorts by `SortKeys([:label => false])` until a call to
`sort!`, and the Sort menu of the browser makes one.
"""
struct SortKeys
    keys::Vector{Pair{Symbol,Bool}}
end

# As `by`: the value of each key of the row, and for text its `natural_key`. A key that the
# workspace does not have, such as one saved with the browser's view, is `missing`.
(order::SortKeys)(row) = Tuple(
    (value = hasproperty(row, key) ? getproperty(row, key) : missing; value isa AbstractString ? natural_key(value) : value)
    for (key, _) in order.keys)

# As `lt`: the first key where the rows differ decides, in its direction.
function (order::SortKeys)(a::Tuple, b::Tuple)::Bool
    for (x, y, (_, reverse)) in zip(a, b, order.keys)
        isequal(x, y) && continue
        (ismissing(x) || ismissing(y)) && return ismissing(y)
        return reverse ? isless(y, x) : isless(x, y)
    end
    return false
end

"""
    sort!(workspace; by, lt=isless, rev=false) -> workspace

Set the order of the items that [`select`](@ref) gives for a function, with the keywords of `sort`.
The browser shows the members of each group in this order. `by` takes a row as `select` gives it:
`row.id`, `row.label`, `row.groups`, `row.tags`, and one field for each metadata key of the
workspace, `missing` where the item has none. Before a call to `sort!`, the items sort by their
labels, with the numbers in them by their value: `a2` comes before `a10`.

```julia
using NaturalSort
sort!(workspace; by=row -> row.label, lt=natural)
sort!(workspace; by=row -> row.timestamp, rev=true)  # the latest first
```

When `by` or `lt` throws, the items sort by their labels again, and the error is logged once.
"""
function Base.sort!(workspace::Workspace; by, lt=isless, rev::Bool=false)::Workspace
    items = workspace.items
    @lock items.lock items.order = (; by, order=Base.Order.ord(lt, identity, rev))
    notify(items.asked)
    return workspace
end

"""
    order(workspace)

Internal. The `by` of the last call to [`sort!`](@ref), or the `SortKeys` of the labels before one.
"""
order(workspace::Workspace) = @lock workspace.items.lock workspace.items.order.by

"""
The label of a value, as [`select`](@ref) gives it: the one given by its latest version, or its id
before it has one.
"""
function label(workspace::Workspace, x::AbstractString)::String
    version = @atomic workspace.items.version
    n = number(version, x)
    return n == 0 ? String(x) : version.columns.label[n]
end

"""
The type of the latest version of an item, or `Any` before it has one.
"""
function valuetype(workspace::Workspace, x::AbstractString)::Type
    version = @atomic workspace.items.version
    n = number(version, x)
    return n == 0 ? Any : version.columns.type[n]
end

"""
    source_item_id(workspace, id) -> String

The public id of the source item that the value `id` comes from.
"""
source_item_id(workspace::Workspace, x::AbstractString)::String =
    @lock workspace.catalog.lock source(workspace, first(workspace.versions[x]))

"""
    metadata(workspace, id) -> Dict{Symbol,Any}

The metadata of a value, as [`select`](@ref) gives it, in a new dictionary: the metadata of its
latest version.
"""
function metadata(workspace::Workspace, x::AbstractString)::Dict{Symbol,Any}
    version, found = (@atomic workspace.items.version), Dict{Symbol,Any}()
    n = number(version, x)
    n == 0 && return found
    for (name, cells) in version.metadata
        value = cells[n]
        value === missing || (found[name] = value isa Vector ? copy(value) : value)
    end
    return found
end

"""
    metadata_keys(workspace) -> Vector{Symbol}

Internal. The metadata keys of the items of the workspace, in alphabetical order.
"""
metadata_keys(workspace::Workspace)::Vector{Symbol} = sort!(collect(keys((@atomic workspace.items.version).metadata)))

"""
    readiness(workspace, id) -> Readiness

How far the work is for an item, from the row of its latest version.
"""
function readiness(workspace::Workspace, x::AbstractString)::Readiness
    version = @atomic workspace.items.version
    n = number(version, x)
    return n == 0 ? UNPROCESSED : version.columns.readiness[n]
end
