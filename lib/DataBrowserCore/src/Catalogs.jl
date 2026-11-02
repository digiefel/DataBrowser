# Each workspace has one *catalog*, which holds the computations of the workspace, decides which of
# them run, in which order, and which results are out of date. A computation,
# `Computation(f, args...; settings...)`, is a function call before it runs: a function with its
# arguments and its keyword arguments, which are called *settings*.
#
# The catalog is a table with one row for each computation. A row holds the computation, its state,
# the rows that it reads and the rows that read it, and its priority. The rest of the workspace
# refers to a row by its position in the table, as in a spreadsheet: `Row(3)` is the third row. A
# position is never given to another computation, even after its row is removed.
#
# The other two parts of the workspace that keep what it knows about a row are the stores, which keep
# the result of each row, and the cache, which keeps the error of each failed row (see
# [`Evaluate.jl`](Workspace/Evaluate.md)).
#
# When an argument is another computation, that computation is a row too: it is an *input* of the
# row, and the row is a *reader* of it. The rows and their inputs form a graph. There are no kinds of
# rows: the `process` of an item, the function of a plot window and a fit in a plot are rows alike.
#
# When a plot window draws a fit of the item `a/1`, which comes from the source item `a.csv`, the
# catalog has three rows:
#
# ```text
#     row 1   read_items(project, source, a.csv)      read the source item a.csv
#               │
#               ▼
#     row 2   process(project, Part(row 1, "a/1"))    process the item a/1, one part of row 1
#               │
#               ▼
#     row 3   fit(row 2)                              the fit that the plot window draws
#
#     ▼  the row below reads the result of the row above
# ```
#
# The workspace adds row 1 when it finds `a.csv`, and row 2 when row 1 gives the item `a/1`. It
# *holds* row 2 with `hold!` while `a/1` is in the workspace, so that the row stays in the catalog,
# and calls `release!` when `a/1` is removed.
#
# When the plot window opens, the workspace adds row 3, holds it, and *wants* it with `want!`, with
# the priority of what a window shows: a wanted row runs before the rows with a lower priority.
# Row 3 reads row 2, which reads row 1, so rows 1 and 2 get the same priority and run first. Each run
# of a row is a *job*, and the *workers*, tasks of the workspace, run the jobs.
#
# When the code of `process` changes, row 2 becomes *stale*: it ran with code that is no longer
# current. Row 3 reads row 2, so it becomes stale too, and both run again.
#
# Two computations are one row when their functions, arguments and settings are equal with
# `isequal`, as the keys of a `Dict` are. When two windows draw the same fit of the same item, the
# fit runs once. Two closures that capture other values are other computations, and a vector given
# as an argument must not change afterwards.
#
# ## States
#
# A row is in one of five states:
#
# ```text
#     MISSING ──┐                                  ┌──▶ CURRENT ──┐
#               ├── take! … finish!, or restore! ──┤              │
#     STALE ────┘                                  └──▶ FAILED ───┤
#       ▲                                                         │
#       └── invalidate! or replace!, or an input lost its result ──┘
#
#     any state ──▶ REMOVED, when its last hold goes while no row reads it, or its last
#                   reader goes while it has no hold. REMOVED is final.
#
#     While a job runs, from take! to finish!, the row stays MISSING or STALE.
# ```
#
# A row becomes stale when its code, something that it reads outside the catalog, such as a file, or
# its computation changes (`invalidate!` and `replace!`), or when one of its inputs loses its result.
# A failed row is finished, as a current row is: it runs again only when it becomes stale.
# *Stuck* is not a state: a row is stuck when it failed, or when it reads a failed row, directly or
# through other rows. A stuck row that did not fail cannot run until the failed row runs again.
# Three rules decide what happens to a row:
#
# - **Current.** A row is current when it was computed with the current code of its function and
#   the current results of its inputs. When a row loses its result, every row that reads it,
#   directly or through other rows, becomes stale.
# - **Compute.** A row runs when the workspace wants it, it is missing or stale, and its inputs are
#   current. A row that is wanted passes its priority on to its inputs, so that they run first. An
#   input keeps the highest priority that it inherited, even after its reader is no longer wanted.
# - **Hold.** A row stays while it has a hold, or while a row that stays reads it. It is removed when
#   `release!` takes its last hold while no row reads it, or when its last reader is removed while
#   it has no hold. A row that is added and never held is never removed by itself: the workspace
#   holds each row that it adds.
#
# Holding and wanting are separate. A row that is held stays, but it runs only when it is wanted.
# The workspace holds the row of each item while the item is in the workspace. It wants those rows
# in the background, or before everything else when a window shows the item. Its priorities go from
# `VIEWED_ITEM` (6), for what a window shows, down to `BACKGROUND_COLLECTION` (1), and 0 means that
# nothing wants the row (see "Workers" in [`Evaluate.jl`](Workspace/Evaluate.md)).
#
# ## Who calls what
#
# The catalog keeps the rows and applies the rules. It computes nothing itself:
#
# | Caller                      | Calls                                                              |
# | --------------------------- | ------------------------------------------------------------------ |
# | the workspace               | `add!`, `replace!`, `hold!`, `release!`, `want!`, `invalidate!`, `restore!`, `lost!` |
# | a worker                    | `take!`, then `finish!`                                            |
# | a task that waits for a row | `wait`, which gives the state of the row                           |
# | the progress display        | `count`, `queued`, `CHANGES`                                       |
#
# What a row computes, where its result and its error are kept, and which rows to add when one
# finishes belong to the workspace: see [`Evaluate.jl`](Workspace/Evaluate.md) and
# [`Pipeline.jl`](Workspace/Pipeline.md).
#
# Two numbers follow each row. Its *version* identifies its result: the workspace computes it from
# the code of the function, the versions of the inputs, and the other arguments and settings. The
# same version means the same result, even in another session. Its *revision* is a counter that
# rises whenever the row loses its result, gets another computation, or is removed. A job keeps the
# revision of its row from its start; when the revision differs at its end, its result is dropped.

"""
The computations of a workspace as one table and one graph. Each row of a [`Catalog`](@ref) is one
computation, and the rows among its arguments are its inputs. A row is missing, stale, current,
failed or removed (see [`State`](@ref)). The catalog decides which rows run and which stay; workers
run them with [`take!`](@ref) and [`finish!`](@ref).
"""
module Catalogs

using ..DataBrowserCore: Computation

"""
    Row

The position of a row in the table of a [`Catalog`](@ref): `Row(3)` is the third row. A position
is never given to another computation, so a `Row` kept after its row was removed never refers to
another computation; `in` tells whether the row is still there.
"""
struct Row
    index::Int32
end

"""
    Part(of, id)

The item with id `id` among the items that `of` gives. When reading the source item `a.csv` gives
the items `a/1` and `a/2`, the `process` of `a/1` receives `Part(row, "a/1")`, where `row` reads
`a.csv`. `of` is a computation, its row, or its [`Input`](@ref): `add!` replaces the first two with
the third. When the row of `of` becomes stale, so does each row that reads one of its parts, and it
runs again once `of` has run.
"""
struct Part{T}
    of::T
    id::String
end

"""
    State

The state of a row:

- `MISSING`: it was never computed;
- `STALE`: its code, something that it reads outside the catalog, one of its inputs, or its
  computation changed since it was computed;
- `CURRENT`: it was computed with its current code, from the current results of its inputs;
- `FAILED`: it was computed like a current row, and its function threw an error. It does not run
  again until it becomes stale, and every row that reads it is stuck;
- `REMOVED`: it left the catalog, because nothing held it and no row read it.
"""
@enum State::UInt8 MISSING STALE CURRENT FAILED REMOVED

"""One row of the table of a [`Catalog`](@ref): a computation and what the catalog knows of it."""
mutable struct Node
    computation::Computation
    ## Each row among its arguments once, and the rows that read it.
    inputs::Vector{Row}
    readers::Vector{Row}
    state::State
    running::Bool
    ## See `revision`.
    revision::UInt32
    ## How many inputs are not current, and how many failed or are stuck.
    waiting::Int32
    blocked::Int32
    ## The priority given with `want!`, the highest priority it inherited from a reader, and its holds.
    priority::Int
    inherited::Int
    holds::Int32
    ## The version and the type of its result; see `finish!`.
    version::UInt64
    type::Type
end

"""
    Catalog()

The table of the computations of one workspace, with one row for each. The workers and the tasks of
the workspace share it: every field is read and changed under `lock`.
"""
# TODO: a row costs about 300 bytes. Keep the inputs and readers of all rows in flat vectors when a
# workspace with millions of items needs it.
mutable struct Catalog
    const lock::ReentrantLock
    ## Notified at every change: for the tasks that wait for a row, and the workers that wait for a job.
    const changed::Threads.Condition
    const nodes::Vector{Node}
    ## The row of each computation, after `add!` instanced it.
    const row_of::Dict{Computation,Row}
    ## The rows that can run, by priority, in the order they became able to run, and the priority
    ## of each.
    const queue::Dict{Int,Vector{Row}}
    const queued_at::Dict{Row,Int}
    ## The rows that lost their result since the last `lost!`.
    const lost::Vector{Row}
    ## The number of rows in each state, by the type of their function.
    const counts::Dict{Type,Vector{Int}}
    ## Set by `close`: tasks in `wait` return, and workers stop waiting for jobs.
    closed::Bool
end

Catalog() = (lock = ReentrantLock(); Catalog(lock, Threads.Condition(lock), Node[], Dict{Computation,Row}(),
    Dict{Int,Vector{Row}}(), Dict{Row,Int}(), Row[], Dict{Type,Vector{Int}}(), false))

Base.show(io::IO, catalog::Catalog) = print(io, "Catalog(", length(catalog.nodes), " rows)")

"""
    Input(catalog, row)

Stands, in the arguments of a computation, for the result of `row`. When `add!` adds a
computation, each computation among its arguments is replaced by the `Input` of its row. When the row runs, the workspace
passes the result of each `Input` to the function in its place. An `Input` belongs to one catalog.
"""
struct Input
    catalog::Catalog
    row::Row
end

Base.show(io::IO, input::Input) = print(io, "Input(", input.row.index, ")")

"""
    CHANGES

A number that rises whenever a row is added, changes its state, or is removed. A progress display
draws again when it differs from the number it drew with. The catalogs of all open workspaces share
it, so it may also rise for a change in another workspace.
"""
const CHANGES = Threads.Atomic{Int}(0)

"""
    count(catalog, F, state) -> Int

The number of rows in `state` whose function has type `F`, such as `typeof(process)`: the progress
of one kind of work.
"""
Base.count(catalog::Catalog, F::Type, state::State)::Int =
    @lock catalog.lock get(catalog.counts, F, zeros(Int, 5))[Int(state) + 1]

# Count a row in its state (`change` 1), or stop counting it there before it changes (`change` -1).
function tally!(catalog::Catalog, current::Node, change::Int)::Nothing
    get!(() -> zeros(Int, 5), catalog.counts, typeof(current.computation.f))[Int(current.state) + 1] += change
    Threads.atomic_add!(CHANGES, 1)
    return nothing
end

# ## Reading a row
#
# These functions read one row. `getindex` and `in` take the lock themselves; for the others, the
# caller holds `catalog.lock`. A worker can change a row at any time, so read the facts that belong
# together under one lock, as `@lock catalog.lock (state(catalog, row), stuck(catalog, row))`.

node(catalog::Catalog, row::Row)::Node = catalog.nodes[row.index]

"""
    catalog[row] -> Computation

The computation of `row`. Each argument that was a computation is the [`Input`](@ref) of its row.
"""
Base.getindex(catalog::Catalog, row::Row)::Computation = @lock catalog.lock node(catalog, row).computation

"""
    row in catalog -> Bool

Whether `row` is still in the catalog: it was not removed.
"""
Base.in(row::Row, catalog::Catalog)::Bool = @lock catalog.lock node(catalog, row).state != REMOVED

"""
    state(catalog, row) -> State

The state of `row`; see [`State`](@ref). The caller holds `catalog.lock`.
"""
state(catalog::Catalog, row::Row)::State = node(catalog, row).state

"""
    revision(catalog, row) -> UInt32

A number that rises whenever `row` loses its result, is removed, or its running job goes out of
date. A job of the row keeps it from its start; see [`keepable`](@ref). The caller holds
`catalog.lock`.
"""
revision(catalog::Catalog, row::Row)::UInt32 = node(catalog, row).revision

"""
    inputs(catalog, row) -> Vector{Row}
    readers(catalog, row) -> Vector{Row}

The rows that `row` reads, each once, and the rows that read it. The caller holds `catalog.lock`.
"""
inputs(catalog::Catalog, row::Row)::Vector{Row} = node(catalog, row).inputs
readers(catalog::Catalog, row::Row)::Vector{Row} = node(catalog, row).readers

"""
    running(catalog, row) -> Bool

Whether a job runs for `row` now. The caller holds `catalog.lock`.
"""
running(catalog::Catalog, row::Row)::Bool = node(catalog, row).running

"""
    wanted(catalog, row) -> Bool

Whether something wants `row`: its [`priority`](@ref) is above 0. The caller holds `catalog.lock`.
"""
wanted(catalog::Catalog, row::Row)::Bool = priority(node(catalog, row)) > 0

"""
    stuck(catalog, row) -> Bool

Whether `row` is stuck: it failed, or it reads a row that failed, directly or through other rows.
The caller holds `catalog.lock`.
"""
stuck(catalog::Catalog, row::Row)::Bool = stuck(node(catalog, row))
stuck(node::Node)::Bool = node.state == FAILED || node.blocked > 0

"""
    version(catalog, row) -> UInt64
    result_type(catalog, row) -> Type

The version and the type of the result of `row`, as [`finish!`](@ref) or [`restore!`](@ref) gave
them: `0` and `Nothing` for a row that never had a result. A stale or failed row keeps those of its
last result. The caller holds `catalog.lock`.
"""
version(catalog::Catalog, row::Row)::UInt64 = node(catalog, row).version
result_type(catalog::Catalog, row::Row)::Type = node(catalog, row).type

"""
    priority(catalog, row) -> Int

The priority of `row`: the one [`want!`](@ref) gave it, or the highest that it inherited from a
reader, whichever is higher. A row with priority 0 does not run. The caller holds `catalog.lock`.
"""
priority(catalog::Catalog, row::Row)::Int = priority(node(catalog, row))
priority(node::Node)::Int = max(node.priority, node.inherited)

# ## Instancing
#
# A computation becomes a row once. `add!` *instances* it: each computation among its arguments is
# added as a row first, and replaced by the `Input` of that row. The instanced computation is the
# key of the row in `row_of`, so two equal computations find the same row.
#
# `input_rows(argument)` finds the inputs among the arguments, and `argument(catalog, argument, add)`
# instances one argument. Both look inside tuples, vectors and parts. An argument of another type
# that contains rows needs a method of each, as the workspace defines for a selection:
#
# ```julia
# Catalogs.input_rows(x::MyArgument) = Catalogs.input_rows(x.items)
# Catalogs.argument(catalog::Catalog, x::MyArgument, add::Bool) =
#     MyArgument(Catalogs.argument(catalog, x.items, add))
# ```
#
# Without them, the rows inside it are not inputs, and the row does not become stale when they
# change.

"""
    input_rows(argument) -> Vector{Row}

The rows that an argument of a computation reads. A vector of a concrete type that contains no
rows, such as a vector of numbers, is not visited.
"""
input_rows(value::Input) = Row[value.row]
input_rows(value::Part) = input_rows(value.of)
input_rows(values::Tuple) = reduce(vcat, map(input_rows, values); init=Row[])
function input_rows(values::AbstractVector{T}) where {T}
    T === Input && return Row[value.row for value in values]
    isconcretetype(T) && !(T <: Union{Input,Part,Tuple,AbstractVector}) && return Row[]
    return reduce(vcat, map(input_rows, values); init=Row[])
end
input_rows(_) = Row[]

# `value` with each computation and each row among its arguments replaced by its input. With `add`,
# the computations that the catalog does not have are added; without, they become
# `Input(catalog, NOWHERE)`.
instanced(catalog::Catalog, value::Computation; add::Bool) =
    Computation(value.f, argument(catalog, value.args, add), value.settings)
argument(catalog::Catalog, value::Computation, add::Bool) = Input(catalog,
    add ? add!(catalog, value) : get(catalog.row_of, instanced(catalog, value; add), NOWHERE))
argument(catalog::Catalog, value::Row, _) = Input(catalog, value)
function argument(catalog::Catalog, value::Input, _)
    value.catalog === catalog || error("The computation reads a result of another workspace")
    return value
end
argument(catalog::Catalog, value::Part, add::Bool) = Part(argument(catalog, value.of, add), value.id)
argument(catalog::Catalog, values::Tuple, add::Bool) = map(x -> argument(catalog, x, add), values)
function argument(catalog::Catalog, values::AbstractVector{T}, add::Bool) where {T}
    isconcretetype(T) && !(T <: Union{Computation,Row,Input,Part,Tuple,AbstractVector}) && return values
    return map(x -> argument(catalog, x, add), values)
end
argument(_, value, _) = value

"""
    NOWHERE

The row of no computation: what `get` gives for a computation that the catalog does not have.
"""
const NOWHERE = Row(0)

"""
    get(catalog, computation, default)

The row of `computation`, or `default` when the catalog does not have it. Nothing is added.
"""
Base.get(catalog::Catalog, value::Computation, default) =
    @lock catalog.lock get(catalog.row_of, instanced(catalog, value; add=false), default)

"""
    add!(catalog, computation) -> Row

The row of `computation`. A computation that the catalog does not have is added, and so is each
computation among its arguments that it does not have either. A new row is missing, and nothing
wants or holds it. Hold it with [`hold!`](@ref): a row without a hold is removed only when its last
reader is removed, and a row that is never held and never read stays. An input of the computation
that was removed is an error.
"""
function add!(catalog::Catalog, value::Computation)::Row
    @lock catalog.lock begin
        value = instanced(catalog, value; add=true)
        row = get(catalog.row_of, value, nothing)
        row === nothing || return row
        any(input -> node(catalog, input).state == REMOVED, input_rows(value.args)) &&
            error("An input of the computation was removed from the workspace")
        row = Row(length(catalog.nodes) + 1)
        push!(catalog.nodes, Node(value, Row[], Row[], MISSING, false, 0, 0, 0, 0, 0, 0, 0, Nothing))
        tally!(catalog, catalog.nodes[end], 1)
        catalog.row_of[value] = row
        connect!(catalog, row)
        return row
    end
end

"""
    replace!(catalog, row, computation) -> Row

Make `row` compute `computation` from now on. The row and its readers become stale; its holds,
its priority and its readers stay. The workspace uses it when the source item that a row reads
changed, or when a collection has other members: its readers keep reading the same row.
"""
function Base.replace!(catalog::Catalog, row::Row, value::Computation)::Row
    @lock catalog.lock begin
        value = instanced(catalog, value; add=true)
        current = node(catalog, row)
        delete!(catalog.row_of, current.computation)
        tally!(catalog, current, -1)
        current.computation = value
        tally!(catalog, current, 1)
        catalog.row_of[value] = row
        before = current.inputs
        disconnect!(catalog, row)
        connect!(catalog, row)
        foreach(input -> remove_unheld!(catalog, input), before)
        invalidate!(catalog, row, true)
        return row
    end
end

# Make the rows among the arguments of a row its inputs.
function connect!(catalog::Catalog, row::Row)::Nothing
    current = node(catalog, row)
    current.inputs = unique!(input_rows(current.computation.args))
    for input in current.inputs
        other = node(catalog, input)
        push!(other.readers, row)
        current.waiting += other.state != CURRENT
        current.blocked += stuck(other)
        inherit!(catalog, input, priority(current))
    end
    queue!(catalog, row)
    return nothing
end

# TODO: removing a reader is linear in the number of readers, so removing the k items of one source
# item takes k² steps.
function disconnect!(catalog::Catalog, row::Row)::Nothing
    current = node(catalog, row)
    for input in current.inputs
        other = node(catalog, input).readers
        deleteat!(other, findfirst(==(row), other))
    end
    current.inputs = Row[]
    current.waiting = current.blocked = 0
    return nothing
end

# ## Holding and removing rows

"""
    hold!(catalog, row)
    release!(catalog, row)

Hold `row` so that it stays, or let go of one hold; call `release!` once for each `hold!`. A row
that nothing holds and that no row reads is removed, and so are the inputs that then have nothing to
keep them either.
"""
hold!(catalog::Catalog, row::Row)::Nothing = @lock catalog.lock (node(catalog, row).holds += 1; nothing)

function release!(catalog::Catalog, row::Row)::Nothing
    @lock catalog.lock (node(catalog, row).holds -= 1; remove_unheld!(catalog, row))
    return nothing
end

# Remove a row that has no hold and no reader, and then each of its inputs that is left with neither.
function remove_unheld!(catalog::Catalog, row::Row)::Nothing
    current = node(catalog, row)
    (current.state == REMOVED || current.holds > 0 || !isempty(current.readers)) && return nothing
    push!(catalog.lost, row)
    before = current.inputs
    disconnect!(catalog, row)
    delete!(catalog.row_of, current.computation)
    delete!(catalog.queued_at, row)
    tally!(catalog, current, -1)
    current.state = REMOVED
    current.revision += 1
    foreach(input -> remove_unheld!(catalog, input), before)
    notify(catalog.changed)
    return nothing
end

# ## Priority

"""
    want!(catalog, row, priority)

Give `row` this priority: the higher the priority, the sooner it runs, and 0 means that nothing
wants it. The workspace has a constant for each priority, such as `VIEWED_ITEM` for an item that a
window shows. Each row that `row` reads, directly or through other rows, inherits the priority when
it has a lower one.
"""
# TODO: lowering the priority of a row does not lower what its inputs inherited, so an input that a
# view wanted once keeps that priority when it becomes stale again.
function want!(catalog::Catalog, row::Row, priority::Int)::Nothing
    @lock catalog.lock begin
        current = node(catalog, row)
        current.priority = priority
        queue!(catalog, row)
        foreach(input -> inherit!(catalog, input, priority), current.inputs)
    end
    return nothing
end

# Give a row, and the rows that it reads, at least `priority` as their inherited priority.
function inherit!(catalog::Catalog, row::Row, priority::Int)::Nothing
    current = node(catalog, row)
    current.inherited >= priority && return nothing
    current.inherited = priority
    queue!(catalog, row)
    foreach(input -> inherit!(catalog, input, priority), current.inputs)
    return nothing
end

# ## Stale rows

"""
    invalidate!(catalog, row)

Make `row` and every row that reads it, directly or through other rows, stale. The workspace calls it when the code
of the function of `row` changed, or when something that `row` reads outside the catalog, such as a
file, changed. A job that runs for one of these rows can finish, but its result is not kept, and the
row runs again.
"""
invalidate!(catalog::Catalog, row::Row)::Nothing = @lock catalog.lock invalidate!(catalog, row, true)

# `outside` is true for the row whose code or outside input changed. A reader that is missing or
# stale and has no job made its own readers stale already, so the walk stops there.
function invalidate!(catalog::Catalog, row::Row, outside::Bool)::Nothing
    current = node(catalog, row)
    had = current.state in (CURRENT, FAILED)
    (had || current.running || outside) || return nothing
    current.state == REMOVED && return nothing
    current.revision += 1
    had && (push!(catalog.lost, row); set!(catalog, row, STALE))
    foreach(reader -> invalidate!(catalog, reader, false), current.readers)
    queue!(catalog, row)
    return nothing
end

# Change the state of a row, and update in each reader the counts of its inputs that are not
# current and that are stuck.
function set!(catalog::Catalog, row::Row, state::State)::Nothing
    current = node(catalog, row)
    was_current, was_stuck = current.state == CURRENT, stuck(current)
    tally!(catalog, current, -1)
    current.state = state
    tally!(catalog, current, 1)
    for reader in current.readers
        other = node(catalog, reader)
        other.waiting += was_current - (state == CURRENT)
        other.waiting == 0 && queue!(catalog, reader)
    end
    stuck(current) == was_stuck || foreach(reader -> block!(catalog, reader, stuck(current) ? 1 : -1), current.readers)
    notify(catalog.changed)
    return nothing
end

# Count one more (`change` 1) or one less (`change` -1) stuck input of a row, and pass on to its
# readers a change of whether the row itself is stuck.
function block!(catalog::Catalog, row::Row, change::Int)::Nothing
    current = node(catalog, row)
    was_stuck = stuck(current)
    current.blocked += change
    stuck(current) == was_stuck || foreach(reader -> block!(catalog, reader, stuck(current) ? 1 : -1), current.readers)
    return nothing
end

# Whether a job can start for a row: it is missing or stale, no job runs for it, and its inputs are
# current. This is the Compute rule, without the priority.
startable(current::Node)::Bool = current.state in (MISSING, STALE) && !current.running && current.waiting == 0

# Queue the job of a row that can run and is wanted, at its priority. A row queued at another
# priority is queued again; `take!` skips its old place.
function queue!(catalog::Catalog, row::Row)::Nothing
    current = node(catalog, row)
    rank = priority(current)
    (rank > 0 && startable(current)) || return nothing
    get(catalog.queued_at, row, 0) == rank && return nothing
    push!(get!(Vector{Row}, catalog.queue, rank), row)
    catalog.queued_at[row] = rank
    notify(catalog.changed)
    return nothing
end

# ## Jobs
#
# A worker runs one row at a time. It holds the catalog lock while it takes a job, and waits for
# `catalog.changed` while no row can run:
#
# ```julia
# while true
#     job = @lock catalog.lock begin
#         job = take!(catalog)
#         while job === nothing && !catalog.closed
#             wait(catalog.changed)   # a row may be able to run now
#             job = take!(catalog)
#         end
#         job
#     end
#     job === nothing && break        # the catalog closed
#     try
#         result = ...                # call `catalog[job.row]` with the results of its inputs
#         finish!(catalog, job; version, type=typeof(result))   # `false`: the result is out of date
#     catch
#         finish!(catalog, job; failed=true)
#     end
# end
# ```
#
# The workspace computes `version` before it calls the function; `work!` in
# [`Evaluate.jl`](Workspace/Evaluate.md) is its loop.

"""
    Job

One row to compute, with the [`revision`](@ref) of the row when the job started.
"""
struct Job
    row::Row
    revision::UInt32
end

"""
    take!(catalog) -> Union{Job,Nothing}

Start the job of the row with the highest priority that can run: it is wanted, it is missing or
stale and no job runs for it, and its inputs are current. Rows of one priority start in the order
they became able to run. `take!` does not wait: it gives `nothing` when no row can run.
"""
function Base.take!(catalog::Catalog)::Union{Job,Nothing}
    @lock catalog.lock while !isempty(catalog.queue)
        rank = maximum(keys(catalog.queue))
        bucket = catalog.queue[rank]
        row = popfirst!(bucket)
        isempty(bucket) && delete!(catalog.queue, rank)
        get(catalog.queued_at, row, 0) == rank || continue
        delete!(catalog.queued_at, row)
        current = node(catalog, row)
        startable(current) || continue
        current.running = true
        notify(catalog.changed)
        return Job(row, current.revision)
    end
    return nothing
end

"""
    keepable(catalog, job) -> Bool

Whether the result of `job` can still be kept: its row is in the catalog, and it did not lose its
result since the job started, as when its code or an input changed.
"""
keepable(catalog::Catalog, job::Job)::Bool = @lock catalog.lock (
    node(catalog, job.row).state != REMOVED && node(catalog, job.row).revision == job.revision)

"""
    finish!(catalog, job; version, type) -> Bool
    finish!(catalog, job; failed=true) -> Bool

End `job`. Its row becomes current, with the `version` and the `type` of its result, or failed; then
`finish!` gives `true`. The workspace computes the version before the job runs (see
[`Evaluate.jl`](Workspace/Evaluate.md)), and the type of the result tells it which store keeps the
result. When the result is not [`keepable`](@ref), the row does not change, `finish!` gives `false`,
and the row runs again when it can.
"""
function finish!(catalog::Catalog, job::Job; failed::Bool=false, version::UInt64=UInt64(0), type::Type=Nothing)::Bool
    @lock catalog.lock begin
        current = node(catalog, job.row)
        current.running = false
        if !keepable(catalog, job)
            queue!(catalog, job.row)
            notify(catalog.changed)
            return false
        end
        failed || (current.version = version; current.type = type)
        set!(catalog, job.row, failed ? FAILED : CURRENT)
        return true
    end
end

"""
    restore!(catalog, row; version, type) -> Bool
    restore!(catalog, row; failed=true) -> Bool

Give `row` a result that an earlier session computed, without a job: the row becomes current or
failed. Gives `false`, and changes nothing, when an input is not current or the row is not missing
or stale. The workspace restores the rows of a source item first, then the rows that read them.
"""
function restore!(catalog::Catalog, row::Row; failed::Bool=false, version::UInt64=UInt64(0), type::Type=Nothing)::Bool
    @lock catalog.lock begin
        current = node(catalog, row)
        (current.waiting == 0 && current.state in (MISSING, STALE) && !current.running) || return false
        failed || (current.version = version; current.type = type)
        set!(catalog, row, failed ? FAILED : CURRENT)
        return true
    end
end

"""
    wait(catalog, row) -> State

Wait until `row` has a result, is stuck, or is removed, or until the catalog closes, and give its
state. Only a row that something wants runs: [`want!`](@ref) it first, or `wait` waits until the
catalog closes. A row that reads a failed row, and a row of a closed catalog, give `MISSING` or
`STALE`; tell them apart with [`stuck`](@ref) and `catalog.closed`. A failed row gives `FAILED`.
"""
function Base.wait(catalog::Catalog, row::Row)::State
    @lock catalog.lock while true
        current = node(catalog, row)
        (current.state in (CURRENT, FAILED, REMOVED) || current.blocked > 0 || catalog.closed) &&
            return current.state
        wait(catalog.changed)
    end
end

"""
    close(catalog)

Close the catalog: the tasks in [`wait`](@ref) return, and the workers that wait for
`catalog.changed` wake up and see `catalog.closed`.
"""
Base.close(catalog::Catalog)::Nothing = @lock catalog.lock (catalog.closed = true; notify(catalog.changed); nothing)

"""
    lost!(catalog) -> Vector{Row}

Return and clear the list of the rows that lost their result or were removed since the last call;
a row can appear more than once. The workspace calls it after each change that can make rows lose
their result or remove them, and forgets the results and errors that it keeps for these rows.
"""
lost!(catalog::Catalog)::Vector{Row} = @lock catalog.lock (lost = copy(catalog.lost); empty!(catalog.lost); lost)

"""
    queued(catalog) -> Int

The number of rows that wait for a worker.
"""
queued(catalog::Catalog)::Int = @lock catalog.lock length(catalog.queued_at)

end
