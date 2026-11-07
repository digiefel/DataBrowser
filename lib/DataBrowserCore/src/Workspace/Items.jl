# What the browser, extensions and scripts read about the values of a workspace, by their ids, from
# the latest version of the table `items`, and the task that publishes those versions.

"""
    keep!(items, workspace)

The task that keeps the table `items` of `workspace` current, and the answers of
`select(workspace, f)`, until `close(items)`. At each notification of `items.event`, it requests
in the catalog the latest versions of the ids asked for by readers, ahead of background work. Then,
at most once each `PUBLISH_INTERVAL` unless an item that a reader waits for changed, it writes the
readiness, failure and changes of the catalog rows whose state, priority or job changed, 1000 at a
time, each part under the catalog lock. Once none is left and a cell changed, it stores the draft
as a new version. Then, without a lock, it runs each function given to `select` in the last 10
seconds on the rows of the items whose cells shown by `select` changed in that version, and merges
the items that pass into the order set by `sort!`. A new function runs on the row of every item,
and a new order sorts every item again. An error stops the task, and readers that wait throw from
then on.
"""
function keep!(items::Items, workspace::Workspace)::Nothing
    catalog, columns, rows, last = workspace.catalog, items.columns, items.rows, 0.0
    ## Owned by this task: the sort key of each item, by its number, the order of those keys, and
    ## for each function the sorted numbers of the items that pass it.
    keys_of, sorted_by, passed = Dict{Int32,Any}(), nothing, Dict{Any,Vector{Int32}}()
    try
        while true
            wait(items.event)
            items.closed && return nothing
            ## The requests reach the catalog at once. Only a publish starts the interval, and a
            ## change to an item that a reader waits for in `wait_processed` ends it.
            requested, readers = @lock items.lock (collect(items.requested), copy(items.readers))
            waited = @lock catalog.lock begin
                for x in requested
                    haskey(workspace.versions, x) && request!(catalog, workspace.versions[x][end], VIEWED_ITEM)
                end
                ## An item that a reader waits for changed when the row of its latest version did,
                ## or when its latest version is another row.
                published = (@atomic items.version).columns.version
                any(numbers -> any(n -> columns.version[n] in catalog.touched || columns.version[n] != published[n], numbers), readers)
            end
            waited || sleep(max(0.0, last + PUBLISH_INTERVAL - time()))
            ## The cells of the catalog rows whose state, priority or job changed follow the catalog,
            ## 1000 rows at a time, each part under the catalog lock, so that a worker waits for one
            ## part at most. The last part takes all that is left, and in the same take of the
            ## lock, the draft becomes the new version when a cell changed.
            changed = nothing
            while changed === nothing
                changed = @lock catalog.lock begin
                    part = length(catalog.touched) > 1000 ? 1000 : typemax(Int)
                    for row in [pop!(catalog.touched) for _ in 1:min(part, length(catalog.touched))]
                        ## `publish!` clears the cells of a removed row.
                        row in catalog || continue
                        readiness = Catalogs.state(catalog, row) == Catalogs.CURRENT ? CURRENT : Catalogs.stuck(catalog, row) ? FAILED :
                            Catalogs.running(catalog, row) || Catalogs.wanted(catalog, row) ? WORKING : UNPROCESSED
                        write!(items, rows.readiness, row.index, readiness)
                        write!(items, rows.failure, row.index, readiness == FAILED ? failure(workspace, row) : "")
                        write!(items, rows.changes, row.index, Catalogs.changes(catalog, row))
                    end
                    if isempty(catalog.touched)
                        shown = Set{Int32}()
                        if items.changed || workspace.errors !== (@atomic items.version).errors
                            ## The counts change only together with cells.
                            counts = WorkspaceStageCounts(length(workspace.sources),
                                count(catalog, typeof(read), Catalogs.CURRENT) + count(catalog, typeof(read), Catalogs.FAILED),
                                length(workspace.versions), count(catalog, typeof(process), Catalogs.CURRENT))
                            @atomic items.version = Version(items.index, map(column -> Cells(column, items.count), columns),
                                map(column -> Cells(column, BLOCK * length(column.blocks)), rows),
                                Dict{Symbol,Cells}(name => Cells(column, BLOCK * length(column.blocks)) for (name, column) in items.metadata),
                                workspace.errors, counts)
                            items.draft, items.changed, shown, items.shown = items.draft + 1, false, items.shown, shown
                            last = time()
                            ## A window reads the `revision` of its items again when
                            ## `status_revision` rises, and a view that keeps what it read, by
                            ## `generation`, reads again.
                            Threads.atomic_add!(CHANGES, 1)
                            Threads.atomic_add!(workspace.generation, 1)
                        end
                        ## `wait_workspace_idle!` waits until the cells follow the catalog.
                        notify(catalog.changed)
                        shown
                    end
                end
            end
            ## The requests end with this version, or with the last one when no cell changed. The
            ## answers that nobody asked for in the last 10 seconds are dropped.
            version = @atomic items.version
            order, functions = @lock items.lock begin
                setdiff!(items.requested, requested)
                notify(items.published)
                filter!(answer -> time() - answer.second.asked < 10, items.answers)
                items.order, collect(keys(items.answers))
            end
            filter!(found -> found.first in functions, passed)
            ## Without functions, the task keeps nothing, and the next function runs on every item.
            isempty(functions) && (empty!(keys_of); sorted_by = nothing; continue)
            ## With another order, every item counts as changed.
            present(n) = version.columns.version[n] != Catalogs.NOWHERE
            isequal(order, sorted_by) || union!(changed, Int32(1):Int32(length(version.columns.id)))
            foreach(n -> present(n) || delete!(keys_of, n), changed)
            ## The answers stay as they are when no item that `select` shows changed.
            isempty(changed) && all(f -> haskey(passed, f), functions) && continue
            ## The rows as `select` gives them, with `missing` for each metadata key that an item
            ## does not have: of the changed items, or of every item when a function is new.
            ## TODO(scale): a new function runs on the row of every item.
            asked = any(f -> !haskey(passed, f), functions) ? filter(present, Int32(1):Int32(length(version.columns.id))) :
                filter(present, collect(changed))
            table = Selection(workspace, version, asked; every=true)
            ## The functions of a script run in the latest world, so that they can call the code
            ## that the script defined after the workspace opened.
            remade = Any[]
            try
                for (n, row) in zip(asked, table)
                    n in changed && (keys_of[n] = Base.invokelatest(order.by, row))
                end
                for f in functions
                    before = get(passed, f, nothing)
                    moved = Int32[]
                    for (n, row) in zip(asked, table)
                        before === nothing || n in changed || continue
                        pass = try
                            Base.invokelatest(f, row) === true
                        catch error
                            @error("A function given to `select` failed: the items it fails on are left out",
                                item = version.columns.id[n], exception = (error, catch_backtrace()), _id = objectid(f), maxlog = 1)
                            false
                        end
                        pass && push!(moved, n)
                    end
                    Base.invokelatest(sort!, moved; by=n -> keys_of[n], order=order.order)
                    ## The items that did not change keep their order, and the others that pass are
                    ## merged in.
                    ## TODO(scale): this goes through all the items of the answer.
                    kept = before === nothing ? Int32[] : filter(!in(changed), before)
                    numbers, next = sizehint!(Int32[], length(kept) + length(moved)), 1
                    for n in moved
                        stop = Base.invokelatest(searchsortedlast, kept, n; by=m -> keys_of[m], order=order.order)
                        append!(numbers, @view kept[next:stop])
                        push!(numbers, n)
                        next = stop + 1
                    end
                    append!(numbers, @view kept[next:end])
                    passed[f] = numbers
                    (before === nothing || before != numbers || any(in(changed), numbers)) && push!(remade, f)
                end
                sorted_by = order
            catch error
                @error("The order that `sort!` set failed: the items sort by their labels",
                    exception = (error, catch_backtrace()), _id = objectid(order.by), maxlog = 1)
                labels = SortKeys([:label => false])
                sort!(workspace; by=labels, lt=labels)
                continue
            end
            ## The answers that are new, or whose items or cells changed, copy the cells of this
            ## version. Typed, so that a new function compiles nothing here.
            answers = Pair{Any,Any}[f => Selection(workspace, version, passed[f]) for f in remade]
            @lock items.lock begin
                for (f, selection) in answers
                    items.answers[f] = (; selection, items.answers[f].asked)
                end
                notify(items.published)
            end
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

Stop the task that keeps the table `items`, [`keep!`](@ref), and wake the calls that wait for it,
such as `select(workspace, f)`: they throw.
"""
function Base.close(items::Items)::Nothing
    @lock items.lock (items.closed = true; notify(items.published))
    notify(items.event)
    return nothing
end

# The number of the item `x` in `version`, or 0 when `version` has no item `x`.
number(version::Version, x::AbstractString)::Int32 = get(version.index, x, Int32(0))

# The cell of the item `x` in the column `name` of a version, by default the latest one, or
# `default` when that version has no item `x`. The type of the cell follows from a constant `name`.
Base.@constprop :aggressive function cell(version::Version, x::AbstractString, name::Symbol, default)
    n = number(version, x)
    return n == 0 ? default : getfield(version.columns, name)[n]
end
Base.@constprop :aggressive cell(workspace::Workspace, x::AbstractString, name::Symbol, default) =
    cell((@atomic workspace.items.version), x, name, default)

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
groups(workspace::Workspace, x::AbstractString)::Vector{String} = copy(cell(workspace, x, :groups, String[]))

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
    notify(items.event)
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
label(workspace::Workspace, x::AbstractString)::String = cell(workspace, x, :label, String(x))

"""
The type of the latest version of an item, or `Any` before it has one.
"""
valuetype(workspace::Workspace, x::AbstractString)::Type = cell(workspace, x, :type, Any)

"""
    source_item_id(workspace, id) -> String

The public id of the source item that the value `id` comes from, or `""` when the workspace has no
value `id`.
"""
source_item_id(workspace::Workspace, x::AbstractString)::String = cell(workspace, x, :source, "")

"""
    metadata(workspace, id) -> Dict{Symbol,Any}

The metadata of a value, as [`select`](@ref) gives it, in a new dictionary: the metadata of its
latest version that a row gave, such as the value of its read when its `process` fails.
"""
function metadata(workspace::Workspace, x::AbstractString)::Dict{Symbol,Any}
    version, found = (@atomic workspace.items.version), Dict{Symbol,Any}()
    key = cell(version, x, :key, Int64(0))
    for (name, cells) in version.metadata
        value = cells[key]
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
readiness(workspace::Workspace, x::AbstractString)::Readiness = readiness((@atomic workspace.items.version), x)
readiness(version::Version, x::AbstractString)::Readiness = version.rows.readiness[cell(version, x, :version, Catalogs.NOWHERE)]
