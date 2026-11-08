# Windows and scripts read the items of a workspace from its *table `items`*, a value of type
# `Items` that the workspace holds, with one row for each item, groups included, as in a
# spreadsheet. The cells of the table come from the catalog, the table of the computations of the
# workspace, with one row for each function call, such as a `read` or a `process` of the project.
# Several rows of the catalog can give an item with the same id, such as the `read` and the
# `process` of a measurement, and the last of them, here the `process`, gives the *latest version*
# of the item. For a measurement `a2`:
#
# ```text
#     the catalog                     the table items
#     row 17: read of a2      ──┐     the row of a2: label, type and metadata from row 42 once it
#     row 42: process of a2   ──┴──▶  has its result, and from row 17 before;
#                                     readiness: that of row 42, the latest version of a2
# ```
#
# So the row of an item holds its id, the groups that hold it, the row of the catalog that gives its
# latest version, and the label, type and metadata of its latest version that has a result. Besides,
# the table holds cells for each row of the catalog, such as its *readiness*, whether its result is
# ready (`CURRENT`), waits to run or runs (`WORKING`), is not asked for yet (`UNPROCESSED`) or
# failed (`FAILED`), and the message of its failure. The readiness of an item is that of the row of
# its latest version.
#
# The workers, the tasks that run the rows of the catalog, change the catalog under its lock. To
# read without waiting for them, windows and scripts read *versions of the table*, copies of type
# `Version` that the workspace *publishes* and never changes afterwards. Besides the table, windows
# and scripts read the *shared state*, which holds the items selected in the browser, the tags and
# the order of the items. Each time the workspace publishes a version of the table or of the shared
# state, it gives the published copy the next *generation*, a number that increases by one each
# time, so that `select(workspace, f)` can wait for an answer that shows a given change. The section
# [How windows and scripts read the
# workspace](../../../../../ARCHITECTURE.md#How-windows-and-scripts-read-the-workspace) of the
# architecture shows how these parts fit together.
#
# Windows and scripts *ask for* an item when they need its result: a window for the items that it
# shows, through `select(workspace, ids)`, and a script with `select(workspace, ids)` or with
# `evaluate`, which gives the value of a `Computation`, a function call with its inputs. The
# publishing task `keep!` then moves the rows of these items to the front of the background work, so
# that the workers run them first. The workers and `keep!` write the next version of the table, the
# *draft*, and `keep!` publishes it. A second task, `answer!`, updates the answers of
# `select(workspace, f)`:
#
# ```text
#     workers ── run rows ──▶ the catalog
#        │                     ▲   │
#        │    adds rows, and   │   │ the rows
#        │    runs them first  │   │ that changed
#        │                     │   ▼
#        │                     keep! ◀── ask for items and results ── windows, evaluate,
#        │                       │                                    select(workspace, ids)
#        │ labels, metadata      │ readiness, failures
#        ▼                       │
#     the draft ◀────────────────┘
#        │
#        │ keep! publishes it, with the next generation
#        ▼
#     a version of the table items ── read by ──▶ items, haskey, label, metadata, readiness
#        │
#        │ read by answer!, together with the items that changed, which keep! gives it
#        ▼
#     answer! ◀── the shared state: selection, tags, order ◀── published by tag!, untag!, sort!,
#        │                                                     select!, with the next generation
#        ▼
#     the answers of select(workspace, f)
# ```
#
# ## The publishing task

"""
    keep!(items, workspace)

Internal. The publishing task of `workspace`: publish new versions of its table `items` until
`close(items)`. The workspace starts this task when it opens. The task writes the draft, the copy
of the table that becomes the next version, together with the workers: when a row of the catalog
finishes, its worker writes the cells of the items that the row gives, such as their labels and
metadata. The task wakes each time the catalog changes, or a function call asks for an item or a
result (through `items.event`), and then

1. adds a row to the catalog for each computation that a call of `evaluate` waits for, and moves
   these rows, and the rows of the latest versions of the items that windows and scripts ask for,
   to the front of the background work;
2. copies into the draft the cells of each changed row of the catalog, such as its readiness and
   the message of its failure. It copies 1000 rows each time it takes the lock of the catalog, so
   that a worker waits for 1000 rows at most;
3. when a cell of the draft changed, publishes the draft as the new version of the table, with the
   next generation, and gives [`answer!`](@ref) the items that were added or removed, and those
   whose label, groups or metadata changed, or that got a new result.

The task takes steps 2 and 3 immediately while a call such as `select(workspace, ids)` or
`evaluate` waits, or when the workspace scans no source and no computation waits or runs. Otherwise
it takes them at most once every `PUBLISH_INTERVAL`, which is 0.05 s, so that the results of many
computations come out in one version of the table.

When the task throws, it logs the error and closes the table, as `close(items)` does. From then
on, `select`, `evaluate` and `materialize_items` throw the error "The workspace was closed".
"""
function keep!(items::Items, workspace::Workspace)::Nothing
    catalog, columns, rows = workspace.catalog, items.columns, items.rows
    last, timer = 0.0, Timer(0)
    try
        while true
            wait(items.event)
            items.closed && return nothing
            ## The requests reach the catalog at once. While a scan or a job runs or waits, and no
            ## reader waits, the task waits for the end of the interval that the last version
            ## started: a timer wakes it then, and a reader that comes earlier wakes it at once.
            ## Once the work ends, its last changes follow at once.
            requested, readers = @lock items.lock (collect(items.requested), copy(items.readers))
            ## Code defined since the last check makes its results stale before a computation given
            ## to `evaluate` is read.
            any(reader -> reader isa Base.RefValue && reader[] isa Computation, readers) &&
                @lock(catalog.lock, any(code -> code.world != Base.get_world_counter(), values(workspace.code))) &&
                Base.invokelatest(check_code!, workspace)
            ## Each computation given to `evaluate` gets its row, which the workspace keeps until it
            ## closes. Its call gets the row, or the error of adding it, at the end of this pass.
            added = Pair{Base.RefValue{Any},Any}[]
            idle = @lock catalog.lock begin
                for x in filter(in(keys(workspace.versions)), requested)
                    request!(catalog, workspace.versions[x][end], VIEWED_ITEM)
                end
                for reader in filter(reader -> reader isa Base.RefValue, readers)
                    found = reader[] isa Computation ? try
                        row = add!(catalog, bound(workspace, reader[]))
                        row in workspace.evaluated || (hold!(catalog, row); push!(workspace.evaluated, row))
                        restore!(workspace, row)
                        row
                    catch error
                        error
                    end : reader[]
                    reader[] isa Computation && push!(added, reader => found)
                    found isa Row && request!(catalog, found, VIEWED_ITEM)
                end
                !source_scan_running(workspace) && workspace.running == 0 && queued(catalog) == 0
            end
            if isempty(readers) && !idle && time() < last + PUBLISH_INTERVAL
                isopen(timer) ||
                    (timer = Timer(_ -> notify(items.event), last + PUBLISH_INTERVAL - time()))
                continue
            end
            ## The cells of the catalog rows that changed follow the catalog, 1000 rows at a time,
            ## each part under the catalog lock, so that a worker waits for one part at most. The
            ## last part takes all that is left, and in the same take of the lock, the draft
            ## becomes the new version when a cell changed.
            done = false
            while !done
                done = @lock catalog.lock begin
                    part = length(catalog.touched) > 1000 ? 1000 : typemax(Int)
                    for row in [pop!(catalog.touched) for _ in 1:min(part, length(catalog.touched))]
                        ## `publish!` clears the cells of a removed row.
                        row in catalog || continue
                        readiness = Catalogs.state(catalog, row) == Catalogs.CURRENT ? CURRENT : Catalogs.stuck(catalog, row) ? FAILED :
                            Catalogs.running(catalog, row) || Catalogs.wanted(catalog, row) ? WORKING : UNPROCESSED
                        ## When its run ends, the row of a group keeps the rows of the versions of
                        ## its members that it took.
                        ## TODO(scale): this takes the time of the number of members at each run.
                        write!(items, rows.readiness, row.index, readiness) && readiness in (CURRENT, FAILED) &&
                            haskey(workspace.taken, row) &&
                            write!(items, rows.members, row.index, [at for (_, at) in member_values(workspace, row)])
                        write!(items, rows.failure, row.index, readiness == FAILED ? failure(workspace, row) : "")
                        write!(items, rows.changes, row.index, Catalogs.changes(catalog, row))
                        write!(items, rows.stored, row.index,
                            readiness == CURRENT ? (Catalogs.result_type(catalog, row), Catalogs.revision(catalog, row)) : nothing)
                        value = catalog[row]
                        rows.computation[row] === value || write!(items, rows.computation, row.index, value)
                        write!(items, rows.signature, row.index,
                            haskey(workspace.signatures, row) ? first(workspace.signatures[row]) : call_signature(workspace, row))
                    end
                    if isempty(catalog.touched) && (items.changed || workspace.errors !== (@atomic items.version).errors)
                        ## The counts change only together with cells.
                        counts = WorkspaceStageCounts(length(workspace.sources),
                            count(catalog, typeof(read), Catalogs.CURRENT) + count(catalog, typeof(read), Catalogs.FAILED),
                            length(workspace.versions), count(catalog, typeof(process), Catalogs.CURRENT))
                        ## `answer!` takes a version together with the items whose cells shown by
                        ## `select` changed up to it.
                        @lock items.lock begin
                            @atomic items.version = Version(items.index, map(column -> Cells(column, items.count), columns),
                                map(column -> Cells(column, BLOCK * length(column.blocks)), rows),
                                Dict{Symbol,Cells}(name => Cells(column, BLOCK * length(column.blocks)) for (name, column) in items.metadata),
                                workspace.errors, counts, Threads.atomic_add!(workspace.generation, 1) + 1, catalog)
                            isempty(items.answers) || (union!(items.pending, items.shown); notify(items.asking))
                        end
                        empty!(items.shown)
                        items.draft, items.changed = items.draft + 1, false
                        last = time()
                    end
                    ## A pass that ends after a call of `wait_workspace_idle!` and finds no work
                    ## left ends the call.
                    isempty(catalog.touched) && @lock items.lock begin
                        items.passes += 1
                        !source_scan_running(workspace) && !cache_work_running(workspace) && workspace.running == 0 &&
                            queued(catalog) == 0 && (items.idle = items.passes)
                    end
                    isempty(catalog.touched)
                end
            end
            ## The requests end with this version, or with the last one when no cell changed.
            @lock items.lock begin
                setdiff!(items.requested, requested)
                foreach(((reader, found),) -> reader[] = found, added)
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

# ## The answers of `select(workspace, f)`
#
# `select(workspace, f)` gives the items for which `f(row)` returns `true`, such as the items with a
# tag, in the order set by `sort!` ([`Selection.jl`](Selection.md)). Its *answer* is a `Selection`,
# a table with one row for each of these items, as in a spreadsheet. The answer comes from a task of
# the workspace, which runs `f` again only on the items that change. For example, with
#
# ```julia
# checked(row) = "check" in row.tags
# ```
#
# a first call of `select(workspace, checked)` runs `checked` on every item. When a script then adds
# the tag `check` to the item `a2`, `tag!` publishes the shared state at the next generation, say
# 413, before it returns. The next call of `select(workspace, checked)` waits for an answer of
# generation 413 or later, which the task makes by running `checked` on the row of `a2` alone, and
# so the answer holds `a2`. Each call of `select(workspace, f)` waits in this way for an answer that
# shows every change published before the call. A new result counts once `keep!` publishes it.
#
# The task recognizes a function of an earlier call when the two are `===`, and runs a new function
# on every item. After that, an item changes when it is added or removed, when it gets a new result,
# or when its label, groups, metadata or tags change. So a function that reads anything other than
# the row, such as the readiness of the item or a global variable, can give an answer that is out of
# date.

"""
    answer!(items, workspace)

Internal. The task that updates the answers of `select(workspace, f)`, until `close(items)`. The
workspace starts this task when it opens. The task wakes each time `keep!` publishes a version of
the table, the shared state changes, or a call of `select` finds its answer out of date (through
`items.asking`), and then

1. finds the items that changed since it last woke: the items that `keep!` gave it, and the items
   whose tags changed;
2. runs each function on the rows of these items, and merges the items for which the function
   returns `true` into its answer, in the order set by `sort!`. A function that is new to the task,
   with no earlier function `===` to it, runs on every item, and a new order sorts every item again;
3. gives each answer the generation that it shows: the higher of two generations, that of the
   version of the table that it read, and that of the shared state.

When `f` throws on an item, the task leaves the item out, and logs the first error of `f`. When the
order set by `sort!` throws, the task logs the error and sets the order by labels again.

The task runs the functions one after another, so a slow function delays the answers of the others.
However, it takes no lock of the catalog, so a slow function delays neither the publishing task nor
the workers. The task holds the answer of each function until 10 seconds after the last call of
`select` with it, and then drops it, so that it stops running the functions that no window or script
uses any more. A later call with the function runs it on every item again.
"""
function answer!(items::Items, workspace::Workspace)::Nothing
    ## Owned by this task: the sort key of each item, by its number, the order of those keys, for
    ## each function the sorted numbers of the items that pass it, and the tags that it last read.
    keys_of, sorted_by, passed, tagged = Dict{Int32,Any}(), nothing, Dict{Any,Vector{Int32}}(), nothing
    try
        while true
            wait(items.asking)
            items.closed && return nothing
            ## The answers that nobody asked for in the last 10 seconds are dropped.
            version, shared, changed, functions = @lock items.lock begin
                filter!(answer -> time() - answer.second.asked < 10, items.answers)
                changed, items.pending = items.pending, Set{Int32}()
                (@atomic items.version), (@atomic workspace.shared), changed, collect(keys(items.answers))
            end
            order, generation = shared.order, max(version.generation, shared.generation)
            ## The items whose tags changed count as changed, and when the tags were defined again,
            ## every item with a tag, whose tags may sort in another order.
            if tagged !== nothing && shared.tags !== tagged
                before, after, defined = tagged.assignments, shared.tags.assignments, isequal(tagged.catalog, shared.tags.catalog)
                for x in union(keys(before), keys(after))
                    defined && isequal(get(before, x, nothing), get(after, x, nothing)) && continue
                    n = number(version, x)
                    n == 0 || push!(changed, n)
                end
            end
            tagged = shared.tags
            filter!(found -> found.first in functions, passed)
            ## Without functions, the task keeps nothing, and the next function runs on every item.
            isempty(functions) && (empty!(keys_of); sorted_by = nothing; continue)
            ## With another order, every item counts as changed.
            present(n) = version.columns.version[n] != Catalogs.NOWHERE
            isequal(order, sorted_by) || union!(changed, Int32(1):Int32(length(version.columns.id)))
            foreach(n -> present(n) || delete!(keys_of, n), changed)
            ## The answers stay as they are when no item that `select` shows changed.
            remade = Any[]
            if !isempty(changed) || any(f -> !haskey(passed, f), functions)
                ## The rows as `select` gives them, with `missing` for each metadata key that an
                ## item does not have: of the changed items, or of every item when a function is
                ## new.
                ## TODO(scale): a new function runs on the row of every item.
                asked = any(f -> !haskey(passed, f), functions) ? filter(present, Int32(1):Int32(length(version.columns.id))) :
                    filter(present, collect(changed))
                table = Selection(workspace, version, shared, asked; every=true)
                ## The functions of a script run in the latest world, so that they can call the code
                ## that the script defined after the workspace opened.
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
                        ## The items that did not change keep their order, and the others that pass
                        ## are merged in.
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
            end
            ## The answers that are new, or whose items or cells changed, copy the cells of this
            ## version. Typed, so that a new function compiles nothing here.
            answers = Dict{Any,Any}(f => Selection(workspace, version, shared, passed[f]) for f in remade)
            @lock items.lock begin
                for f in functions
                    answer = items.answers[f]
                    items.answers[f] = (; selection=get(answers, f, answer.selection), generation, answer.asked)
                end
                notify(items.published)
            end
        end
    catch error
        @error "The answers of `select` stopped following the workspace" exception = (error, catch_backtrace())
    finally
        close(items)
    end
    return nothing
end

"""
    close(items::Items)

Internal. Stop the two tasks of the table `items`, [`keep!`](@ref) and [`answer!`](@ref), and wake
the calls that wait for them:

- `select`, `evaluate` and `materialize_items`, which reads items from their stores, throw the error
  "The workspace was closed";
- `wait_workspace_idle!`, which waits until the workspace has no work left, returns.

The functions that read an item by its id keep reading the version of the table published last. The
workspace calls `close` when it closes, and when `modify_workspace!` rebuilds it with a new table.
"""
function Base.close(items::Items)::Nothing
    @lock items.lock (items.closed = true; notify(items.published))
    notify(items.event)
    notify(items.asking)
    return nothing
end

# ## Reading an item by its id
#
# The functions below read one item from the version of the table published last, without a lock and
# without waiting. A change of the item shows in them once the publishing task publishes it:
# immediately while a call waits or when no work is left, and otherwise within about
# `PUBLISH_INTERVAL`, 0.05 s. To wait until an item is computed, call `select(workspace, ids)`
# instead, which also asks for the item.
#
# The *number* of the item `x` in `version` is the position of its row in that version of the
# table, or 0 when `version` does not have the item.
number(version::Version, x::AbstractString)::Int32 = get(version.index, x, Int32(0))

# The cell of the item `x` in the column `name` of `version`, or `default` when `version` does not
# have the item. The second method reads the version of the table published last. When `name` is a
# literal symbol, such as `:label`, the compiler knows the type of the cell.
Base.@constprop :aggressive function cell(version::Version, x::AbstractString, name::Symbol, default)
    n = number(version, x)
    return n == 0 ? default : getfield(version.columns, name)[n]
end
Base.@constprop :aggressive cell(workspace::Workspace, x::AbstractString, name::Symbol, default) =
    cell((@atomic workspace.items.version), x, name, default)

"""
    items(workspace) -> Vector{String}

The ids of the items of the workspace, groups included, in the order of their rows in the table: the
ids for which `haskey` is true. To read the label, tags and metadata of many items, call
[`select`](@ref).
"""
function items(workspace::Workspace)::Vector{String}
    columns = (@atomic workspace.items.version).columns
    return [columns.id[number] for number in eachindex(columns.id) if columns.version[number] != Catalogs.NOWHERE]
end

"""
    haskey(workspace, id) -> Bool

Whether the workspace has an item with the id `id`, so that [`select`](@ref) can give it. The ids
that come from the browser, such as the items selected in it or a view that it saved, can include
items that the workspace does not have yet, or no longer has. `select(workspace, ids)` throws for
such an id, so check these ids with `haskey` first.
"""
Base.haskey(workspace::Workspace, x::AbstractString)::Bool = number((@atomic workspace.items.version), x) != 0

# TODO(query model): the browser reads the groups that hold an item with the internal `groups`,
# until `select` can find them with the query model planned in the roadmap (0.5.0).
"""
    groups(workspace, id) -> Vector{String}

Internal. The ids of the groups that hold the item `id` among their members, as in the column
`groups` of a [`Selection`](@ref).
"""
groups(workspace::Workspace, x::AbstractString)::Vector{String} = copy(cell(workspace, x, :groups, String[]))

# ## The order of the items
#
# `sort!` sets the order of the items in the answers of `select(workspace, f)`, and so in the tree
# of the browser. The order is part of the shared state, and `answer!` sorts by it.

"""
    natural_key(text) -> Tuple

Internal. A sort key for text that compares each run of digits in it as a whole number, so that
`"a2"` comes before `"a10"`, and the rest of the text without regard to case. A decimal point or a
minus sign counts as text, so `"1.5"` comes before `"1.25"`.
"""
natural_key(text::AbstractString)::Tuple = Tuple(
    all(isdigit, part.match) ? (1, parse(Int, part.match)) : (0, lowercase(part.match))
    for part in eachmatch(r"\d+|\D+", String(text)))

"""
    SortKeys(keys)

Internal. The order that the Sort menu of the browser sets, with
`sort!(workspace; by=order, lt=order)` for `order = SortKeys(keys)`. `keys` holds `key => reverse`
pairs, where `key` is `:label`, `:id` or a metadata key, and `reverse` is `true` for a descending
order. The items sort by the first key, then by the second where the first is equal, and so on, and
last by their ids. Text sorts with the numbers in it by their value (see `natural_key`), and an item
that lacks a key sorts after the items that have it, whether the order of the key is ascending or
descending. With `SortKeys([:gap => true])`, the items with a metadata key `gap` come first, the
largest gap first, and the items without one follow. Before the first call to `sort!`, the workspace
sorts by `SortKeys([:label => false])`. A `SortKeys` serves as both `by`, which turns the row of an
item into a tuple, and `lt`, which compares two such tuples.
"""
struct SortKeys
    keys::Vector{Pair{Symbol,Bool}}
end

# Called with a row, as `by`, a `SortKeys` gives a tuple: the field of each of its keys in the row,
# with text as its `natural_key`, then the `natural_key` of the id together with the id. A key that
# the workspace does not have, such as one in a view that the browser saved, gives `missing`.
(order::SortKeys)(row) = (Tuple(
    (value = hasproperty(row, key) ? getproperty(row, key) : missing; value isa AbstractString ? natural_key(value) : value)
    for (key, _) in order.keys)..., (natural_key(row.id), row.id))

# Called with two such tuples, as `lt`, a `SortKeys` compares them key by key: the first key where
# they differ decides, in the direction of that key, with `missing` last. When every key is equal,
# the ids decide, so that no two items tie.
function (order::SortKeys)(a::Tuple, b::Tuple)::Bool
    for (x, y, (_, reverse)) in zip(a, b, order.keys)
        isequal(x, y) && continue
        (ismissing(x) || ismissing(y)) && return ismissing(y)
        return reverse ? isless(y, x) : isless(x, y)
    end
    return isless(last(a), last(b))
end

"""
    sort!(workspace; by, lt=isless, rev=false) -> workspace

Set the order of the items in every answer of `select(workspace, f)`, with the keywords `by`, `lt`
and `rev`, as in `sort`. The tree of the browser shows its items in this order too. `by` takes the
row of an item, as [`select`](@ref) gives it to `f`: `row.id`, `row.label`, `row.groups`,
`row.tags`, and one field for each metadata key of the workspace, `missing` where the item does
not have the key.

Before the first call to `sort!`, the items sort by their labels, with the numbers in them by
their value: `a2` comes before `a10`. A `by` of your own compares with `isless`, which puts `a10`
before `a2`, and puts `missing` last, or first with `rev=true`:

```julia
using NaturalSort
sort!(workspace; by=row -> row.label, lt=natural)    # a2 before a10
sort!(workspace; by=row -> row.timestamp, rev=true)  # no timestamp first, then the latest
```

`sort!` returns immediately, and the workspace sorts the answers afterwards. When `by` or `lt`
throws later, the workspace logs the error and sets the order by labels again.
"""
function Base.sort!(workspace::Workspace; by, lt=isless, rev::Bool=false)::Workspace
    share!(_ -> (; order=(; by, order=Base.Order.ord(lt, identity, rev))), workspace)
    return workspace
end

"""
    order(workspace)

Internal. The `by` of the order set by [`sort!`](@ref): the `by` of its last call, or
`SortKeys([:label => false])` before the first call and after an order that threw.
"""
order(workspace::Workspace) = (@atomic workspace.shared).order.by

# ## The label, type, metadata and readiness of an item
#
# The label, the type and the metadata of an item come from its latest version that has a result,
# and its readiness from its latest version. So for a measurement that `read` gave and that
# `process` changes:
#
# | The `process` of the measurement | `label`, `valuetype`, `metadata` | `readiness`   |
# |:---------------------------------|:---------------------------------|:--------------|
# | is not asked for yet             | from its `read`                  | `UNPROCESSED` |
# | waits to run, or runs            | from its `read`                  | `WORKING`     |
# | failed                           | from its `read`                  | `FAILED`      |
# | finished                         | from its `process`               | `CURRENT`     |

"""
    label(workspace, id) -> String

The label of the item `id`, as in the column `label` of a [`Selection`](@ref), or the id itself
while no version of the item has a result, and for an id that the workspace does not have.
"""
label(workspace::Workspace, x::AbstractString)::String = cell(workspace, x, :label, String(x))

"""
    valuetype(workspace, id) -> Type

The type of the item `id`, a subtype of `AbstractDataItem` such as one that the project defines, or
`Any` while no version of the item has a result, and for an id that the workspace does not have.
"""
valuetype(workspace::Workspace, x::AbstractString)::Type = cell(workspace, x, :type, Any)

"""
    source_item_id(workspace, id) -> String

The id of the source item, such as a file, that the item `id` comes from, or `""` when the
workspace does not have the item.
"""
source_item_id(workspace::Workspace, x::AbstractString)::String = cell(workspace, x, :source, "")

"""
    metadata(workspace, id) -> Dict{Symbol,Any}

The metadata of the item `id`, as in the metadata columns of a [`Selection`](@ref), in a new
dictionary that the caller may change. The dictionary leaves out the keys that the item does not
have, where a `Selection` has `missing`. An id that the workspace does not have gives an empty
dictionary.
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

Internal. The metadata keys that have a column in the latest version of the table, in alphabetical
order.
"""
metadata_keys(workspace::Workspace)::Vector{Symbol} = sort!(collect(keys((@atomic workspace.items.version).metadata)))

"""
    readiness(workspace, id) -> Readiness

How far the work on the latest version of the item `id` is, as a value of the type
[`Readiness`](@ref):

- `CURRENT`: the latest version has its result;
- `WORKING`: the latest version waits to run, or runs;
- `UNPROCESSED`: the latest version has no current result, and nothing asks for it yet, as when the
  workspace runs `process` only for the items that windows and scripts ask for;
- `FAILED`: its computation failed, or one that it needs failed.

An id that the workspace does not have is `UNPROCESSED` too, and `haskey` tells the two apart.
"""
readiness(workspace::Workspace, x::AbstractString)::Readiness = readiness((@atomic workspace.items.version), x)
readiness(version::Version, x::AbstractString)::Readiness = version.rows.readiness[cell(version, x, :version, Catalogs.NOWHERE)]
