"""
The computations of a workspace, as one graph. Each row of the catalog is one computation, and its
inputs are the rows among its arguments. Three rules say what happens to a row:

- current: a row is current when it was computed with the current code of its function and the
  current results of its inputs;
- compute: a row that something wants, and that is not current, runs once its inputs are current;
- hold: a row stays while something holds it, or while a row that takes it as input stays.

The catalog keeps the rows and applies the rules. It runs nothing itself: workers take the rows
that can run with [`take!`](@ref) and report each with [`finish!`](@ref). What a row computes, where
its result is kept, and which rows to add when one finishes belong to the workspace.
"""
module Catalogs

using ..DataBrowserCore: Computation

"""A row of a catalog: its position. A position is never reused."""
struct Row
    index::Int32
end

"""
The item with id `id` among the items that `of` returns: the argument for one of the items that one
computation gives. `of` is a computation, its row, or its [`Input`](@ref).
"""
struct Part{T}
    of::T
    id::String
end

"""
Whether a row is current, and why not.

- `MISSING`: it was never computed.
- `STALE`: it was computed, and the code of its function or an input changed since.
- `CURRENT`: it was computed with the current code and the current results of its inputs.
- `FAILED`: its function threw with the current code and inputs.
- `REMOVED`: nothing holds it any more.
"""
@enum State::UInt8 MISSING STALE CURRENT FAILED REMOVED

mutable struct Node
    computation::Computation
    # The rows among its arguments, each once, and the rows that take it as an input.
    inputs::Vector{Row}
    readers::Vector{Row}
    state::State
    running::Bool
    # Rises whenever a job that runs for the row can no longer give its current result.
    revision::UInt32
    # How many inputs are not current, and how many failed or wait for one that failed.
    waiting::Int32
    blocked::Int32
    # The priority that its holders give it, and the highest priority of a reader that wants it.
    priority::Int
    inherited::Int
    holds::Int32
    # What its current result is: the same version means the same result, also in another session.
    version::UInt64
    type::Type
end

# TODO: a row costs about 300 bytes. Keep the inputs and readers of all rows in flat vectors when a
# workspace with millions of items needs it.
mutable struct Catalog
    const lock::ReentrantLock
    # Notified at every change, for the tasks that wait for a row and the workers that wait for one.
    const changed::Threads.Condition
    const nodes::Vector{Node}
    const rows::Dict{Computation,Row}
    # The rows that can run, by priority, in the order they could; `queued` holds the priority of each.
    const queue::Dict{Int,Vector{Row}}
    const queued::Dict{Row,Int}
    # Rows that lost their result since the last call of `lost!`.
    const lost::Vector{Row}
    # The number of rows in each state, by the type of their function.
    const counts::Dict{Type,Vector{Int}}
    # Set when the workspace stops: workers take no more rows and waiting tasks return.
    closed::Bool
end

function Catalog()
    lock = ReentrantLock()
    return Catalog(lock, Threads.Condition(lock), Node[], Dict{Computation,Row}(),
        Dict{Int,Vector{Row}}(), Dict{Row,Int}(), Row[], Dict{Type,Vector{Int}}(), false)
end

Base.show(io::IO, catalog::Catalog) = print(io, "Catalog(", length(catalog.nodes), " rows)")

"""
A row of a catalog as an argument of a computation: it stands for the result of the row. In the
computations of a catalog, each computation among the arguments is its input, so that
[`inputs`](@ref) of such a computation still gives the computations it reads.
"""
struct Input
    catalog::Catalog
    row::Row
end

Base.show(io::IO, input::Input) = print(io, "Input(", input.row.index, ")")

"""A number that rises whenever a row of any catalog changes its state, is added or is removed."""
const CHANGES = Threads.Atomic{Int}(0)

"""
    count(catalog, F, state) -> Int

The number of rows in `state` whose function has type `F`, such as `typeof(process)`.
"""
Base.count(catalog::Catalog, F::Type, state::State)::Int =
    @lock catalog.lock get(catalog.counts, F, zeros(Int, 5))[Int(state) + 1]

# Count a row in its state, or stop counting it, before it changes.
function tally!(catalog::Catalog, current::Node, change::Int)::Nothing
    get!(() -> zeros(Int, 5), catalog.counts, typeof(current.computation.f))[Int(current.state) + 1] += change
    Threads.atomic_add!(CHANGES, 1)
    return nothing
end

node(catalog::Catalog, row::Row)::Node = catalog.nodes[row.index]

"""The computation of `row`. Its arguments that are computations of the catalog are their rows."""
Base.getindex(catalog::Catalog, row::Row)::Computation = @lock catalog.lock node(catalog, row).computation

"""Whether `row` is still in the catalog."""
Base.in(row::Row, catalog::Catalog)::Bool = @lock catalog.lock node(catalog, row).state != REMOVED

state(catalog::Catalog, row::Row)::State = node(catalog, row).state
"""A number that rises whenever `row` loses its result, or a job of it can no longer give one."""
revision(catalog::Catalog, row::Row)::UInt32 = node(catalog, row).revision
inputs(catalog::Catalog, row::Row)::Vector{Row} = node(catalog, row).inputs
readers(catalog::Catalog, row::Row)::Vector{Row} = node(catalog, row).readers

"""Whether a job runs for `row`, and whether one would run if it could: something wants it."""
running(catalog::Catalog, row::Row)::Bool = node(catalog, row).running
wanted(catalog::Catalog, row::Row)::Bool = priority(node(catalog, row)) > 0

"""Whether `row` failed, or waits for a row that failed."""
stuck(catalog::Catalog, row::Row)::Bool = stuck(node(catalog, row))
stuck(node::Node)::Bool = node.state == FAILED || node.blocked > 0

"""The version and the type of the current result of `row`; see [`finish!`](@ref)."""
version(catalog::Catalog, row::Row)::UInt64 = node(catalog, row).version
result_type(catalog::Catalog, row::Row)::Type = node(catalog, row).type

priority(node::Node)::Int = max(node.priority, node.inherited)
"""The priority of the job of `row`: its own, or the highest of a reader that wants it."""
priority(catalog::Catalog, row::Row)::Int = priority(node(catalog, row))

# The rows among the arguments of a computation of the catalog. The workspace adds methods for its
# own argument types that refer to rows.
rows(value::Input) = Row[value.row]
rows(value::Part) = rows(value.of)
rows(values::Tuple) = reduce(vcat, map(rows, values); init=Row[])
function rows(values::AbstractVector{T}) where {T}
    T === Input && return Row[value.row for value in values]
    isconcretetype(T) && !(T <: Union{Input,Part,Tuple,AbstractVector}) && return Row[]
    return reduce(vcat, map(rows, values); init=Row[])
end
rows(_) = Row[]

# `value` with each computation and each row among its arguments replaced by its input. `add` adds
# the computations that the catalog does not have; otherwise they are the input of no row.
instanced(catalog::Catalog, value::Computation; add::Bool) =
    Computation(value.f, argument(catalog, value.args, add), value.settings)
argument(catalog::Catalog, value::Computation, add::Bool) = Input(catalog,
    add ? add!(catalog, value) : get(catalog.rows, instanced(catalog, value; add), NOWHERE))
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

# The row of no computation.
const NOWHERE = Row(0)

"""
    get(catalog, computation, default)

The row of `computation`, or `default` when the catalog does not have it. Nothing is added.
"""
Base.get(catalog::Catalog, value::Computation, default) =
    @lock catalog.lock get(catalog.rows, instanced(catalog, value; add=false), default)

"""
    add!(catalog, computation) -> Row

The row of `computation`. A computation that the catalog does not have yet is added, with a row for
each computation among its arguments that it does not have either. In the computation of the row,
those arguments, and the rows among them, are their [`Input`](@ref). A new row is wanted by nothing
and held by nothing: hold it with [`hold!`](@ref), or it goes with the next [`release!`](@ref) that
reaches it.
"""
function add!(catalog::Catalog, value::Computation)::Row
    @lock catalog.lock begin
        value = instanced(catalog, value; add=true)
        row = get(catalog.rows, value, nothing)
        row === nothing || return row
        any(input -> node(catalog, input).state == REMOVED, rows(value.args)) &&
            error("An input of the computation was removed from the workspace")
        row = Row(length(catalog.nodes) + 1)
        push!(catalog.nodes, Node(value, Row[], Row[], MISSING, false, 0, 0, 0, 0, 0, 0, 0, Nothing))
        tally!(catalog, catalog.nodes[end], 1)
        catalog.rows[value] = row
        connect!(catalog, row)
        return row
    end
end

"""
    replace!(catalog, row, computation)

Make `row` compute `computation` from now on: the source changed the source item it reads, or a
collection has other members. The row and the rows that read it are no longer current. What holds
the row and what wants it stay.
"""
function Base.replace!(catalog::Catalog, row::Row, value::Computation)::Row
    @lock catalog.lock begin
        value = instanced(catalog, value; add=true)
        current = node(catalog, row)
        delete!(catalog.rows, current.computation)
        tally!(catalog, current, -1)
        current.computation = value
        tally!(catalog, current, 1)
        catalog.rows[value] = row
        before = current.inputs
        disconnect!(catalog, row)
        connect!(catalog, row)
        foreach(input -> remove_unheld!(catalog, input), before)
        invalidate!(catalog, row, true)
        return row
    end
end

# Connect a row to the rows among its arguments, which then count as its inputs.
function connect!(catalog::Catalog, row::Row)::Nothing
    current = node(catalog, row)
    current.inputs = unique!(rows(current.computation.args))
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

"""
    hold!(catalog, row)
    release!(catalog, row)

Hold `row` so that it stays, or let go of one hold. A row that nothing holds and that no row reads
is removed, and so are the rows it read that then have nothing to keep them either.
"""
hold!(catalog::Catalog, row::Row)::Nothing = @lock catalog.lock (node(catalog, row).holds += 1; nothing)

function release!(catalog::Catalog, row::Row)::Nothing
    @lock catalog.lock begin
        node(catalog, row).holds -= 1
        remove_unheld!(catalog, row)
    end
    return nothing
end

function remove_unheld!(catalog::Catalog, row::Row)::Nothing
    current = node(catalog, row)
    (current.state == REMOVED || current.holds > 0 || !isempty(current.readers)) && return nothing
    push!(catalog.lost, row)
    before = current.inputs
    disconnect!(catalog, row)
    delete!(catalog.rows, current.computation)
    delete!(catalog.queued, row)
    tally!(catalog, current, -1)
    current.state = REMOVED
    current.revision += 1
    foreach(input -> remove_unheld!(catalog, input), before)
    notify(catalog.changed)
    return nothing
end

"""
    want!(catalog, row, priority)

Give the job of `row` this priority, and that of each row it reads, directly or not, that has a
lower one. A row that nothing wants has priority 0 and does not run. What a row passed on to the
rows it reads stays when its own priority is lowered.
"""
function want!(catalog::Catalog, row::Row, priority::Int)::Nothing
    @lock catalog.lock begin
        current = node(catalog, row)
        current.priority = priority
        queue!(catalog, row)
        foreach(input -> inherit!(catalog, input, priority), current.inputs)
    end
    return nothing
end

function inherit!(catalog::Catalog, row::Row, priority::Int)::Nothing
    current = node(catalog, row)
    current.inherited >= priority && return nothing
    current.inherited = priority
    queue!(catalog, row)
    foreach(input -> inherit!(catalog, input, priority), current.inputs)
    return nothing
end

"""
    invalidate!(catalog, row)

Make `row`, and every row that reads it directly or not, not current: the code of its function
changed, or something it reads outside the catalog, such as a file. A job that runs for one of
them cannot finish, and runs again.
"""
invalidate!(catalog::Catalog, row::Row)::Nothing = @lock catalog.lock invalidate!(catalog, row, true)

# A row whose result was not current and that does not run passed that on to its readers already.
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

# Change the state of a row, and what its readers count of it.
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

function block!(catalog::Catalog, row::Row, change::Int)::Nothing
    current = node(catalog, row)
    was_stuck = stuck(current)
    current.blocked += change
    stuck(current) == was_stuck || foreach(reader -> block!(catalog, reader, stuck(current) ? 1 : -1), current.readers)
    return nothing
end

startable(current::Node)::Bool = current.state in (MISSING, STALE) && !current.running && current.waiting == 0

# Queue the job of a row that can run and is wanted, at its priority. A job queued at another
# priority moves; `take!` skips its old place.
function queue!(catalog::Catalog, row::Row)::Nothing
    current = node(catalog, row)
    rank = priority(current)
    (rank > 0 && startable(current)) || return nothing
    get(catalog.queued, row, 0) == rank && return nothing
    push!(get!(Vector{Row}, catalog.queue, rank), row)
    catalog.queued[row] = rank
    notify(catalog.changed)
    return nothing
end

"""A job: one row to compute, with the revision of the row when the job started."""
struct Job
    row::Row
    revision::UInt32
end

"""
    take!(catalog) -> Union{Job,Nothing}

Start the job of the row with the highest priority that can run: it is wanted, it is not current
and does not run, and its inputs are current. Rows of one priority start in the order they could.
`nothing` when no row can run.
"""
function Base.take!(catalog::Catalog)::Union{Job,Nothing}
    @lock catalog.lock while !isempty(catalog.queue)
        rank = maximum(keys(catalog.queue))
        bucket = catalog.queue[rank]
        row = popfirst!(bucket)
        isempty(bucket) && delete!(catalog.queue, rank)
        get(catalog.queued, row, 0) == rank || continue
        delete!(catalog.queued, row)
        current = node(catalog, row)
        startable(current) || continue
        current.running = true
        notify(catalog.changed)
        return Job(row, current.revision)
    end
    return nothing
end

"""
    iscurrent(catalog, job) -> Bool

Whether the result of `job` would be kept: its row is in the catalog, and neither its code nor an
input changed since the job started.
"""
iscurrent(catalog::Catalog, job::Job)::Bool = @lock catalog.lock (
    node(catalog, job.row).state != REMOVED && node(catalog, job.row).revision == job.revision)

"""
    finish!(catalog, job; version, type) -> Bool
    finish!(catalog, job; failed=true) -> Bool

End `job`. Its row becomes current, with the version and the type of its result, or failed, and
`finish!` returns `true`. When the row was removed, or its code or an input changed while the job
ran, the result is not kept: the row runs again when it can, and `finish!` returns `false`.
"""
function finish!(catalog::Catalog, job::Job; failed::Bool=false, version::UInt64=UInt64(0), type::Type=Nothing)::Bool
    @lock catalog.lock begin
        current = node(catalog, job.row)
        current.running = false
        if !(current.state != REMOVED && current.revision == job.revision)
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

Give `row` a result that an earlier session computed, without running it: the row becomes current
or failed. Returns `false`, and changes nothing, when an input is not current.
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

Wait until `row` is current, failed, waits for a row that failed, or is removed, or until the
catalog closes, and return its state. Only a row that something wants becomes current.
"""
function Base.wait(catalog::Catalog, row::Row)::State
    @lock catalog.lock while true
        current = node(catalog, row)
        (current.state in (CURRENT, FAILED, REMOVED) || current.blocked > 0 || catalog.closed) &&
            return current.state
        wait(catalog.changed)
    end
end

"""Stop the catalog: [`take!`](@ref) waits no more, and tasks waiting for a row return."""
Base.close(catalog::Catalog)::Nothing = @lock catalog.lock (catalog.closed = true; notify(catalog.changed); nothing)

"""
    lost!(catalog) -> Vector{Row}

The rows that lost a current or failed result, and the rows that were removed, since the last call,
each as often as it happened: the caller removes what it saved for them.
"""
lost!(catalog::Catalog)::Vector{Row} = @lock catalog.lock (lost = copy(catalog.lost); empty!(catalog.lost); lost)

"""The number of jobs that wait to run."""
queued(catalog::Catalog)::Int = @lock catalog.lock length(catalog.queued)

end
