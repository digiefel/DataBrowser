# Each workspace has one *catalog*, which holds the computations of the workspace, decides which of
# them run, in which order, and which results are out of date. A computation,
# `Computation(f, args...; settings...)`, is a function call before it runs: a function with its
# arguments and its keyword arguments, which are called *settings*.
#
# The catalog is a table with one row for each computation, and each row contains the computation,
# its state, the rows that it reads and the rows that read it, and its priority. The rest of the
# workspace refers to a row by its position in the table, as in a spreadsheet: `Row(3)` is the third
# row.
#
# Two other parts of the workspace keep information about a row: the stores keep the result of each
# row, and the cache keeps the revision of each result and the error of each failed row (see
# [`Evaluate.jl`](Workspace/Evaluate.md)). Both keep them under the position of the row, which is
# its *key*. The cache keeps the key of each computation, so that the same computation gets the same
# position in each session; a position that no row has is empty.
#
# When an argument is another computation, that computation is a row too: it is an *input* of the
# row, and the row is a *reader* of it. The rows and their inputs form a graph. The workspace can
# also give a row inputs that are not among its arguments, with `connect!`: the row of a group
# process reads the rows of the values of its members.
#
# When a plot window draws a fit of the item `a/1`, which the `process` of the table in the source
# item `a.csv` gives, the catalog has three rows:
#
# ```text
#     row 1   read(project, source, a.csv)                read the table of the source item a.csv
#               │
#               ▼
#     row 2   process(project, Part(row 1, "a.csv"))      process it into the items a/1 and a/2
#               │
#               ▼
#     row 3   fit(Part(row 2, "a/1"))                     the fit that the plot window draws
#
#     ▼  the row below reads the result of the row above
# ```
#
# The workspace adds row 1 when it finds `a.csv`, and row 2 when reading `a.csv` gives the table.
# It *holds* both rows with `hold!` while `a.csv` is in the workspace, so that they stay in the
# catalog. When `a.csv` is removed, the workspace calls `release!` on both.
#
# When the plot window opens, the workspace adds row 3, holds it, and *requests* it with `request!`,
# with the priority of what a window shows: a requested row runs before the rows with a lower
# priority, until it has a result. Row 3 reads row 2, so row 2 gets the same request when it has no
# result yet, and runs first. Each run of a row is a *job*, and the *workers*, tasks of the
# workspace, run the jobs.
#
# When the code of `process` changes, row 2 becomes *stale*: it ran with code that is no longer
# current. Row 3 reads row 2, so row 3 becomes stale too. The plot window then requests row 3
# again, and both rows run again. When row 2 gives items `isequal` to those it gave before, with the
# same ids, row 3 becomes current without calling `fit`.
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
# A row becomes stale when the code of its function or something that it reads outside the catalog,
# such as a file, changes (`invalidate!`), when it gets another computation (`replace!`), or when
# one of its inputs becomes stale. A current or failed row that becomes stale *loses its result*:
# the workspace forgets the result or the error that it kept for the row.
#
# A failed row is finished, as a current row is: it runs again only when it becomes stale.
# A row is *stuck* when it failed, or when it reads a failed row, directly or through other rows. A
# stuck row that did not fail runs once the failed row is current again.
# Three rules decide what happens to a row:
#
# - **Current.** A row is current when it was computed with the current code of its function and
#   the current results of its inputs.
# - **Compute.** A row runs when the workspace wants it or requests it, it is missing or stale, and
#   its inputs are current. A row passes its priority on to its inputs, so that they run first. A
#   want lasts: an input keeps the highest priority that it inherited from a want. A request lasts
#   until the row is current or failed.
# - **Hold.** A row is removed when it loses its last hold while no row reads it, or its last reader
#   while it has no hold.
#
# Holding and wanting are separate. A row that is held stays, but it runs only when it is wanted or
# requested. The workspace holds the rows of each value while the value is in the workspace. It
# always wants the rows of source items; it wants the rows of `process` in the background only when
# it was opened with `background_processing=true`. A window that shows an item, or a script that
# reads it, requests its row, which then runs before everything else. The priorities of the
# workspace go from `VIEWED_ITEM` (6), for what a window shows or a script reads, down to
# `BACKGROUND_ITEM` (3), and 0 means that nothing wants or requests the row (see "Workers" in
# [`Evaluate.jl`](Workspace/Evaluate.md)).
#
# ## Who calls what
#
# The catalog keeps the rows and applies the rules, and the workspace and its workers call it:
#
# | Caller                      | Calls                                                              |
# | --------------------------- | ------------------------------------------------------------------ |
# | the workspace               | `add!`, `replace!`, `connect!`, `disconnect!`, `hold!`, `release!`, `want!`, `request!`, `invalidate!`, `restore!`, `lost!` |
# | a worker                    | `take!`, then `finish!`                                            |
# | the progress display        | `count`, `queued`                                                  |
#
# The workspace decides what a row computes, where its result and its error are kept, and which rows
# to add when a row finishes: see [`Evaluate.jl`](Workspace/Evaluate.md) and
# [`Pipeline.jl`](Workspace/Pipeline.md).
#
# Two numbers follow each row. Its *revision* identifies its result: the workspace computes it from
# the code of the function, the revisions of the results of the inputs, and the other arguments and
# settings. The same revision means the same result, even in another session. When a row runs again
# and its result is `isequal` to its last result, the workspace gives it the revision of its last
# result, so that its readers find the revisions they last ran with and do not call their functions
# again. Its number of *changes* protects a running job: a job keeps the number of changes of its
# row from its start, and the number rises when the code, an input, a file that it reads or the
# computation of the row changes, or when the row is removed. When the number differs at the end of
# the job, `finish!` drops its result.

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

The position of a row in the table of a [`Catalog`](@ref): `Row(3)` is the third row. The position
is also the key of the row in the cache and in the stores, and the same computation gets the same
position in each session, because the cache keeps it. A new row always takes a new position, so a
`Row` refers to one row for as long as the catalog exists, even when [`replace!`](@ref) gives that
row another computation; `in` tells whether the row is still there.
"""
struct Row
    index::Int32
end

"""
    Part(of, id)

The value with id `id` among the values that `of` gives: its result, or an element of the vector
it gives. When the `process` of the table of `a.csv` gives the items `a/1` and `a/2`, a fit of `a/1`
receives `Part(row, "a/1")`, where `row` is that `process`. `of` is a computation, its row, or its
[`Input`](@ref): `add!` replaces the first two with the third. When the row of `of` becomes stale,
so does each row that reads one of its parts, and each of those rows runs again once `of` has run.
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
    ## Each input once, in no order: the rows among its arguments and those that `connect!` gave
    ## it; and the rows that read it.
    inputs::Vector{Row}
    readers::Vector{Row}
    state::State
    running::Bool
    ## See `changes`.
    changes::UInt32
    ## How many inputs are not current, and how many failed or are stuck.
    waiting::Int32
    blocked::Int32
    ## The priority given with `want!`, the highest priority it inherited from a want of a reader,
    ## the priority of a request that waits for its result (see `request!`), and its holds.
    priority::Int
    inherited::Int
    requested::Int
    holds::Int32
    ## The revision and the type of its result; see `finish!`.
    revision::UInt64
    type::Type
end

# TODO: a row costs about 300 bytes, and each of its inputs an entry of `edges`. Keep the inputs and
# readers of all rows in flat vectors when a workspace with millions of items needs it.
"""
    Catalog(key)

The table of the computations of one workspace, with one row for each. `key(computation)` gives the
position of each new row, a position that no row of the catalog had: [`add!`](@ref) calls it with
the computation after it replaced the computations among its arguments with their
[`Input`](@ref)s. The workers and the tasks of the workspace share the catalog: every function reads
and changes the fields inside `@lock catalog.lock`, except `findfirst`, which takes no lock.
"""
mutable struct Catalog
    const lock::ReentrantLock
    ## Notified at every change: for the workers that wait for a job.
    const changed::Threads.Condition
    const key::Function
    ## The positions that no row has hold `EMPTY`.
    const nodes::Vector{Node}
    ## The row of each computation, after `add!` instanced it, as a pair under the hash of the
    ## computation: a `PersistentDict` compares its keys with `===`, so `findfirst` compares the
    ## computations with `isequal`. `findfirst` reads it without the lock, so the vectors in it
    ## never change: a new vector takes the place of one.
    @atomic row_of::Base.PersistentDict{UInt,Vector{Pair{Computation,Row}}}
    ## For each row and each of its inputs: the place of the input among the inputs of the row, the
    ## place of the row among the readers of the input, and how many times the row reads the input.
    const edges::Dict{Tuple{Row,Row},@NamedTuple{input::Int32, reader::Int32, uses::Int32}}
    ## The rows that can run, by priority, in the order they became able to run, and the priority
    ## of each.
    const queue::Dict{Int,Vector{Row}}
    const queued_at::Dict{Row,Int}
    ## The rows that lost their result or were removed since the last `lost!`.
    const lost::Vector{Row}
    ## The rows that are new, or whose computation, state, priority, job or the state of an input
    ## changed, until the workspace reads them for the cells of its rows (see `keep!`).
    const touched::Set{Row}
    ## The number of rows in each state, by the type of their function.
    const counts::Dict{Type,Vector{Int}}
    ## Set by `close`: workers stop waiting for jobs.
    closed::Bool
end

Catalog(key::Function) = (lock = ReentrantLock(); Catalog(lock, Threads.Condition(lock), key,
    Node[], Base.PersistentDict{UInt,Vector{Pair{Computation,Row}}}(),
    Dict{Tuple{Row,Row},@NamedTuple{input::Int32, reader::Int32, uses::Int32}}(),
    Dict{Int,Vector{Row}}(), Dict{Row,Int}(), Row[], Set{Row}(), Dict{Type,Vector{Int}}(), false))

# The node of every position that no row has: removed, and never counted.
const EMPTY = Node(Computation(nothing), Row[], Row[], REMOVED, false, 0, 0, 0, 0, 0, 0, 0, 0, Nothing)

Base.show(io::IO, catalog::Catalog) =
    print(io, "Catalog(", sum(length, values(@atomic catalog.row_of); init=0), " rows)")

"""
    Input(catalog, row)

Stands for the result of `row` among the arguments of a computation. When `add!` adds a
computation, it replaces each computation among the arguments with the `Input` of its row. When the
row runs, the workspace passes the result of each `Input` to the function in its place. An `Input`
belongs to one catalog. It also keeps the computation of its row as it was when the `Input` was
made, so that `inputs` reads it without the lock. Two inputs are equal when they stand for the same
row.
"""
struct Input
    catalog::Catalog
    row::Row
    computation::Computation
end

# The caller holds the catalog lock.
Input(catalog::Catalog, row::Row) = Input(catalog, row, row == NOWHERE ? EMPTY.computation : node(catalog, row).computation)
Base.:(==)(a::Input, b::Input) = a.catalog === b.catalog && a.row == b.row
Base.hash(input::Input, h::UInt) = hash(input.row, hash(objectid(input.catalog), h))

Base.show(io::IO, input::Input) = print(io, "Input(", input.row.index, ")")

"""
    count(catalog, F, state) -> Int

The number of rows in `state` whose function has type `F`, such as `typeof(process)`: the progress
of one kind of work.
"""
Base.count(catalog::Catalog, F::Type, state::State)::Int =
    @lock catalog.lock get(catalog.counts, F, zeros(Int, 5))[Int(state) + 1]

# Add 1 to the number of rows in the state of a row (`change` 1), or subtract 1 before its state
# changes (`change` -1).
function tally!(catalog::Catalog, current::Node, change::Int)::Nothing
    get!(() -> zeros(Int, 5), catalog.counts, typeof(current.computation.f))[Int(current.state) + 1] += change
    return nothing
end

# ## The facts of a row
#
# These functions give the facts of one row. `getindex` and `in` lock the catalog themselves; call
# the others inside `@lock catalog.lock`. A worker can change a row at any time, so read the facts
# that belong together under one lock, as
# `@lock catalog.lock (state(catalog, row), stuck(catalog, row))`.

node(catalog::Catalog, row::Row)::Node = catalog.nodes[row.index]

"""
    catalog[row] -> Computation

The computation of `row`. Each argument that was a computation is the [`Input`](@ref) of its row.
"""
Base.getindex(catalog::Catalog, row::Row)::Computation = @lock catalog.lock node(catalog, row).computation

"""
    row in catalog -> Bool

Whether `row` is in the catalog: a row has its position, and it was not removed.
"""
Base.in(row::Row, catalog::Catalog)::Bool =
    @lock catalog.lock checkbounds(Bool, catalog.nodes, row.index) && node(catalog, row).state != REMOVED

"""
    state(catalog, row) -> State

The state of `row`; see [`State`](@ref). Call it inside `@lock catalog.lock`.
"""
state(catalog::Catalog, row::Row)::State = node(catalog, row).state

"""
    changes(catalog, row) -> UInt32

The number of changes of `row`: it rises when the code, an input, a file that it reads or the
computation of `row` changes, or when `row` is removed. A job of the row keeps the number from its
start; see [`keepable`](@ref). Call it inside `@lock catalog.lock`.
"""
changes(catalog::Catalog, row::Row)::UInt32 = node(catalog, row).changes

"""
    inputs(catalog, row) -> Vector{Row}
    readers(catalog, row) -> Vector{Row}

The rows that `row` reads, each once, and the rows that read it. Call them inside
`@lock catalog.lock`.
"""
inputs(catalog::Catalog, row::Row)::Vector{Row} = node(catalog, row).inputs
readers(catalog::Catalog, row::Row)::Vector{Row} = node(catalog, row).readers

"""
    reads(catalog, row, other) -> Bool

Whether `row` reads `other`, directly or through other rows: then `other` must not read `row`,
which would make a cycle. Call it inside `@lock catalog.lock`.
"""
function reads(catalog::Catalog, row::Row, other::Row)::Bool
    seen, next = Set{Row}(), Row[row]
    while !isempty(next)
        at = pop!(next)
        at == other && return true
        at in seen || (push!(seen, at); append!(next, inputs(catalog, at)))
    end
    return false
end

"""
    running(catalog, row) -> Bool

Whether a job runs for `row` now. Call it inside `@lock catalog.lock`.
"""
running(catalog::Catalog, row::Row)::Bool = node(catalog, row).running

"""
    wanted(catalog, row) -> Bool

Whether something wants or requests `row`: its [`priority`](@ref) is above 0. Call it inside
`@lock catalog.lock`.
"""
wanted(catalog::Catalog, row::Row)::Bool = priority(node(catalog, row)) > 0

"""
    stuck(catalog, row) -> Bool

Whether `row` is stuck: it failed, or it reads a row that failed, directly or through other rows.
Call it inside `@lock catalog.lock`.
"""
stuck(catalog::Catalog, row::Row)::Bool = stuck(node(catalog, row))
stuck(node::Node)::Bool = node.state == FAILED || node.blocked > 0

"""
    revision(catalog, row) -> UInt64
    result_type(catalog, row) -> Type

The revision and the type of the result of `row`, as [`finish!`](@ref) or [`restore!`](@ref) gave
them: `0` and `Nothing` for a row that never had a result. A stale or failed row keeps the revision
and the type of its last result. Call them inside `@lock catalog.lock`.
"""
revision(catalog::Catalog, row::Row)::UInt64 = node(catalog, row).revision
result_type(catalog::Catalog, row::Row)::Type = node(catalog, row).type

"""
    priority(catalog, row) -> Int

The priority of `row`: the one [`want!`](@ref) gave it, the highest that it inherited from a
reader, or the one of a [`request!`](@ref), whichever is highest. A row with priority 0 does not
run. Call it inside `@lock catalog.lock`.
"""
priority(catalog::Catalog, row::Row)::Int = priority(node(catalog, row))
priority(node::Node)::Int = max(node.priority, node.inherited, node.requested)

# ## Instancing
#
# `add!` gives each computation one row, after it *instances* the computation: each computation
# among its arguments is added as a row first, and replaced by the `Input` of that row. `findfirst`
# finds the row of the instanced computation, so two equal computations find the same row.
#
# `input_rows(argument)` finds the inputs among the arguments, and
# `argument(catalog, argument, add)` instances one argument. Both look inside tuples, vectors and
# parts. When an argument of your own type contains computations, define a method of each function
# for it, as the workspace does for a selection:
#
# ```julia
# Catalogs.input_rows(x::MyArgument) = Catalogs.input_rows(x.items)
# Catalogs.argument(catalog::Catalog, x::MyArgument, add::Bool) =
#     MyArgument(Catalogs.argument(catalog, x.items, add))
# ```
#
# Without these methods, the computations inside the argument are not inputs, and the row does not
# become stale when they change.

"""
    input_rows(argument) -> Vector{Row}

The rows whose results `argument` stands for, among the arguments of a computation. `input_rows`
skips a vector whose element type is concrete and cannot contain rows, such as a `Vector{Float64}`.
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
    add ? add!(catalog, value) : something(findfirst(isequal(value), catalog), NOWHERE))
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

The row of no computation, `Row(0)`.
"""
const NOWHERE = Row(0)

"""
    findfirst(isequal(computation), catalog) -> Union{Row,Nothing}

The row of `computation`, or `nothing` when the catalog does not have it. `findfirst` leaves the
catalog as it is, and takes no lock.
"""
function Base.findfirst(equal::Base.Fix2{typeof(isequal),<:Computation}, catalog::Catalog)
    value = instanced(catalog, equal.x; add=false)
    for (computation, row) in get(@atomic(catalog.row_of), hash(value), ())
        isequal(computation, value) && return row
    end
    return nothing
end

"""
    add!(catalog, computation) -> Row

The row of `computation`, which `add!` adds when the catalog does not have it, together with each
computation among its arguments that the catalog does not have. The `key` of the catalog gives the
position of each new row. A new row is `MISSING`, and nothing wants or holds it. A row is removed
only when it loses its last hold or its last reader (see [`hold!`](@ref)), so a row that is never
held and never read stays. `add!` throws an error when an input of the computation was removed.
"""
function add!(catalog::Catalog, value::Computation)::Row
    @lock catalog.lock begin
        row = findfirst(isequal(value), catalog)
        row === nothing || return row
        ## The catalog does not have the computation, nor will it after the inputs are added.
        value = instanced(catalog, value; add=true)
        any(input -> node(catalog, input).state == REMOVED, input_rows(value.args)) &&
            error("An input of the computation was removed from the workspace")
        row = Row(catalog.key(value))
        length(catalog.nodes) < row.index && append!(catalog.nodes, fill(EMPTY, row.index - length(catalog.nodes)))
        catalog.nodes[row.index] = Node(value, Row[], Row[], MISSING, false, 0, 0, 0, 0, 0, 0, 0, 0, Nothing)
        tally!(catalog, catalog.nodes[row.index], 1)
        push!(catalog.touched, row)
        row_of, key = @atomic(catalog.row_of), hash(value)
        @atomic catalog.row_of = Base.PersistentDict(row_of, key => [get(row_of, key, Pair{Computation,Row}[]); value => row])
        foreach(input -> connect!(catalog, row, input), input_rows(value.args))
        return row
    end
end

"""
    replace!(catalog, row, computation) -> Row

Make `row` compute `computation` from now on. The row and its readers become stale; its holds,
its priority, its readers and the inputs that [`connect!`](@ref) gave it stay. The workspace uses it
when the source item that a row reads changed, or when a `process` takes its value from another
row: its readers keep reading the same row.
"""
function Base.replace!(catalog::Catalog, row::Row, value::Computation)::Row
    @lock catalog.lock begin
        value = instanced(catalog, value; add=true)
        current = node(catalog, row)
        before = input_rows(current.computation.args)
        row_of, key = @atomic(catalog.row_of), hash(current.computation)
        pairs = filter(pair -> pair.second != row, row_of[key])
        row_of = isempty(pairs) ? Base.delete(row_of, key) : Base.PersistentDict(row_of, key => pairs)
        @atomic catalog.row_of = Base.PersistentDict(row_of, hash(value) => [get(row_of, hash(value), Pair{Computation,Row}[]); value => row])
        tally!(catalog, current, -1)
        current.computation = value
        tally!(catalog, current, 1)
        push!(catalog.touched, row)
        ## The rows among the new arguments are connected first, so that a row among both stays.
        foreach(input -> connect!(catalog, row, input), input_rows(value.args))
        foreach(input -> disconnect!(catalog, row, input), before)
        invalidate!(catalog, row, true)
        return row
    end
end

"""
    connect!(catalog, row, input)
    disconnect!(catalog, row, input)

Give `row` one more input, or one less: `add!` connects the rows among the arguments of a
computation, and the workspace connects the row of a group to the rows of the values of its
members. A row that is connected to an input more than once reads it until it is disconnected as
many times. Both make `row` stale, and `connect!` passes on the priority and the request of `row`
to `input`. Apart from making `row` stale, each takes the same time whatever the number of inputs
and readers. `disconnect!`
removes `input` when it is left with no hold and no reader.
"""
function connect!(catalog::Catalog, row::Row, input::Row)::Nothing
    @lock catalog.lock begin
        current, other = node(catalog, row), node(catalog, input)
        edge = get(catalog.edges, (row, input), nothing)
        if edge === nothing
            push!(current.inputs, input)
            push!(other.readers, row)
            catalog.edges[(row, input)] = (input=length(current.inputs), reader=length(other.readers), uses=1)
            current.waiting += other.state != CURRENT
            stuck(other) && block!(catalog, row, 1)
        else
            catalog.edges[(row, input)] = (; edge..., uses=edge.uses + 1)
        end
        inherit!(catalog, input, max(current.priority, current.inherited))
        request!(catalog, input, current.requested)
        invalidate!(catalog, row, true)
    end
    return nothing
end

function disconnect!(catalog::Catalog, row::Row, input::Row)::Nothing
    @lock catalog.lock begin
        edge = catalog.edges[(row, input)]
        edge.uses > 1 ? (catalog.edges[(row, input)] = (; edge..., uses=edge.uses - 1)) : unlink!(catalog, row, input)
        invalidate!(catalog, row, true)
        remove_unheld!(catalog, input)
    end
    return nothing
end

# Take `input` from the inputs of `row`, and `row` from the readers of `input`: the last element of
# each vector takes the place of the one that leaves.
function unlink!(catalog::Catalog, row::Row, input::Row)::Nothing
    edge = pop!(catalog.edges, (row, input))
    current, other = node(catalog, row), node(catalog, input)
    moved = pop!(current.inputs)
    moved == input || (current.inputs[edge.input] = moved;
        catalog.edges[(row, moved)] = (; catalog.edges[(row, moved)]..., input=edge.input))
    moved = pop!(other.readers)
    moved == row || (other.readers[edge.reader] = moved;
        catalog.edges[(moved, input)] = (; catalog.edges[(moved, input)]..., reader=edge.reader))
    current.waiting -= other.state != CURRENT
    stuck(other) && block!(catalog, row, -1)
    return nothing
end

# ## Holding and removing rows

"""
    hold!(catalog, row)
    release!(catalog, row)

Hold `row` so that it stays, or let go of one hold; call `release!` once for each `hold!`. A row is
removed when it loses its last hold while no row reads it, or its last reader while it has no hold.
Each input of a removed row that is then left with no hold and no reader is removed too.
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
    before = copy(current.inputs)
    foreach(input -> unlink!(catalog, row, input), before)
    row_of, key = @atomic(catalog.row_of), hash(current.computation)
    pairs = filter(pair -> pair.second != row, row_of[key])
    @atomic catalog.row_of = isempty(pairs) ? Base.delete(row_of, key) : Base.PersistentDict(row_of, key => pairs)
    delete!(catalog.queued_at, row)
    tally!(catalog, current, -1)
    current.state = REMOVED
    current.changes += 1
    foreach(input -> remove_unheld!(catalog, input), before)
    notify(catalog.changed)
    return nothing
end

# ## Priority

# TODO: an input keeps what it inherited after its reader is lowered, replaced or removed. The
# workspace lowers only source rows, which read no rows.
"""
    want!(catalog, row, priority)

Give `row` this priority until the next `want!` of `row`: the higher the priority, the sooner it
runs, and 0 means that nothing wants it. The workspace has a constant for each priority, such as
`BACKGROUND_ITEM` for the `process` of an item in the background. Each row that `row` reads,
directly or through other rows, inherits the priority when it has a lower one.
"""
function want!(catalog::Catalog, row::Row, priority::Int)::Nothing
    @lock catalog.lock begin
        current = node(catalog, row)
        current.priority = priority
        push!(catalog.touched, row)
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
    push!(catalog.touched, row)
    queue!(catalog, row)
    foreach(input -> inherit!(catalog, input, priority), current.inputs)
    return nothing
end

"""
    request!(catalog, row, priority)

Ask for the result of `row`: until the row is current or failed, it has at least this priority,
and so does each row that it reads, directly or through other rows, until that row is current or
failed. A row that is current or failed does not change. A row that reads a failed row keeps its
request, and runs once the failed row is current again. When a row becomes stale while the request
of a reader waits, it gets that request. The workspace requests what a window shows and what a
script reads with `VIEWED_ITEM`.
"""
function request!(catalog::Catalog, row::Row, priority::Int)::Nothing
    @lock catalog.lock begin
        current = node(catalog, row)
        (current.state in (MISSING, STALE) && current.requested < priority) || return nothing
        current.requested = priority
        push!(catalog.touched, row)
        queue!(catalog, row)
        foreach(input -> request!(catalog, input, priority), current.inputs)
    end
    return nothing
end

# ## Stale rows

"""
    invalidate!(catalog, row)

Make `row` stale, and every row that reads it, directly or through other rows. The workspace calls
it when the code of the function of `row` changed, or when something that `row` reads outside the
catalog, such as a file, changed. A job that runs for one of these rows can finish, but `finish!`
drops its result, and the row runs again.
"""
invalidate!(catalog::Catalog, row::Row)::Nothing = @lock catalog.lock invalidate!(catalog, row, true)

# `outside` is true for the row whose code or outside input changed. A reader that is missing or
# stale and has no job made its own readers stale already, so `invalidate!` goes no further from it.
function invalidate!(catalog::Catalog, row::Row, outside::Bool)::Nothing
    current = node(catalog, row)
    had = current.state in (CURRENT, FAILED)
    (had || current.running || outside) || return nothing
    current.state == REMOVED && return nothing
    current.changes += 1
    ## The readers of a row without a result have none either, and passed their requests on to it.
    if had
        push!(catalog.lost, row)
        set!(catalog, row, STALE)
        foreach(reader -> invalidate!(catalog, reader, false), current.readers)
        ## A reader whose request waits needs this row again.
        request!(catalog, row, maximum(reader -> node(catalog, reader).requested, current.readers; init=0))
    end
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
    push!(catalog.touched, row)
    ## A request ends with a result.
    state in (CURRENT, FAILED) && (current.requested = 0)
    tally!(catalog, current, 1)
    for reader in current.readers
        other = node(catalog, reader)
        push!(catalog.touched, reader)
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
    push!(catalog.touched, row)
    stuck(current) == was_stuck || foreach(reader -> block!(catalog, reader, stuck(current) ? 1 : -1), current.readers)
    return nothing
end

# Whether a job can start for a row: it is missing or stale, no job runs for it, and its inputs are
# current, whatever its priority.
startable(current::Node)::Bool = current.state in (MISSING, STALE) && !current.running && current.waiting == 0

# Put a row that can run and is wanted in the queue, at its priority. A row in the queue at another
# priority goes in again; `take!` skips its old place.
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
# A worker runs one row at a time. It takes a job inside `@lock catalog.lock`, and waits for
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
#         finish!(catalog, job; revision, type=typeof(result))   # `false`: the row changed
#     catch
#         finish!(catalog, job; failed=true)
#     end
# end
# ```
#
# The workspace computes `revision` before it calls the function; `work!` in
# [`Evaluate.jl`](Workspace/Evaluate.md) is the loop of the workers.

"""
    Job

One row to compute, with the number of [`changes`](@ref) of the row when the job started.
"""
struct Job
    row::Row
    changes::UInt32
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
        push!(catalog.touched, row)
        notify(catalog.changed)
        return Job(row, current.changes)
    end
    return nothing
end

"""
    keepable(catalog, job) -> Bool

Whether the result of `job` can still be kept: its row is in the catalog, and its number of
[`changes`](@ref) did not rise since the job started, as it does when its code or an input changes.
"""
keepable(catalog::Catalog, job::Job)::Bool = @lock catalog.lock (
    node(catalog, job.row).state != REMOVED && node(catalog, job.row).changes == job.changes)

"""
    finish!(catalog, job; revision, type) -> Bool
    finish!(catalog, job; failed=true) -> Bool

End `job`. Its row becomes current, with the `revision` and the `type` of its result, or failed;
then `finish!` gives `true`. The workspace computes the revision before the job runs, and gives the
revision of the last result of the row instead when the new result is `isequal` to it (see
[`Evaluate.jl`](Workspace/Evaluate.md)); it chooses the store of the result by its type. When the
result is not [`keepable`](@ref), the row does not change, `finish!` gives `false`, and the row runs
again when it can.
"""
function finish!(catalog::Catalog, job::Job; failed::Bool=false, revision::UInt64=UInt64(0), type::Type=Nothing)::Bool
    @lock catalog.lock begin
        current = node(catalog, job.row)
        current.running = false
        push!(catalog.touched, job.row)
        if !keepable(catalog, job)
            queue!(catalog, job.row)
            notify(catalog.changed)
            return false
        end
        failed || (current.revision = revision; current.type = type)
        set!(catalog, job.row, failed ? FAILED : CURRENT)
        return true
    end
end

"""
    restore!(catalog, row; revision, type) -> Bool
    restore!(catalog, row; failed=true) -> Bool

Give `row` a result that the cache saved, with the `revision` and the `type` of that result, without
a job: the row becomes current or failed. Gives `false`, and changes nothing, when an input is not
current or the row is not missing or stale. The workspace restores the rows of a source item first,
then the rows that read them.
"""
function restore!(catalog::Catalog, row::Row; failed::Bool=false, revision::UInt64=UInt64(0), type::Type=Nothing)::Bool
    @lock catalog.lock begin
        current = node(catalog, row)
        (current.waiting == 0 && current.state in (MISSING, STALE) && !current.running) || return false
        failed || (current.revision = revision; current.type = type)
        set!(catalog, row, failed ? FAILED : CURRENT)
        return true
    end
end

"""
    close(catalog)

Close the catalog: the tasks that wait for `catalog.changed`, such as the workers, wake up and see
`catalog.closed`.
"""
Base.close(catalog::Catalog)::Nothing = @lock catalog.lock (catalog.closed = true; notify(catalog.changed); nothing)

"""
    lost!(catalog) -> Vector{Row}

Return and clear the list of the rows that lost their result or were removed since the last call;
a row can appear more than once. The workspace calls it after each change that can make rows lose
their result or be removed, and then forgets the results and errors that it keeps for those rows.

"""
lost!(catalog::Catalog)::Vector{Row} = @lock catalog.lock (lost = copy(catalog.lost); empty!(catalog.lost); lost)

"""
    queued(catalog) -> Int

The number of rows that wait for a worker.
"""
queued(catalog::Catalog)::Int = @lock catalog.lock length(catalog.queued_at)

end
