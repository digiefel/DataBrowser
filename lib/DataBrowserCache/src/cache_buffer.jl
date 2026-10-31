const CACHE_BUFFER_ROW_LIMIT = 2_000_000
const CACHE_BUFFER_FLUSH_INTERVAL = 2.0
const CACHE_DELETE_KEY_BATCH = 1_000

@enum BufferMutationKind::UInt8 begin
    BUFFER_APPEND
    BUFFER_EDIT
    BUFFER_DELETE
end

struct BufferMutation{R}
    kind::BufferMutationKind
    row::Union{Nothing,R}
end

abstract type AbstractDatabaseStore{K,R} end

function _quote_identifier(identifier::AbstractString)::String
    return "\"" * replace(String(identifier), "\"" => "\"\"") * "\""
end

"""The DuckDB column type storing Julia element type `T`, or `nothing` when none does."""
function _duckdb_sql_type_maybe(T::Type)::Union{Nothing,String}
    candidates = Type[m for m in Base.uniontypes(T) if m !== Nothing && m !== Missing]
    length(candidates) == 1 || return nothing
    U = only(candidates)
    U <: Bool && return "BOOLEAN"
    U <: Int8 && return "TINYINT"
    U <: Int16 && return "SMALLINT"
    U <: Int32 && return "INTEGER"
    U <: Int64 && return "BIGINT"
    U <: Int128 && return "HUGEINT"
    U <: UInt8 && return "UTINYINT"
    U <: UInt16 && return "USMALLINT"
    U <: UInt32 && return "UINTEGER"
    U <: UInt64 && return "UBIGINT"
    U <: Float32 && return "FLOAT"
    U <: Float64 && return "DOUBLE"
    U <: AbstractString && return "VARCHAR"
    U <: DateTime && return "TIMESTAMP"
    U <: Date && return "DATE"
    if U <: AbstractArray
        inner = _duckdb_sql_type_maybe(eltype(U))
        return inner === nothing ? nothing : "$(inner)[]"
    end
    return nothing
end

function _duckdb_sql_type(T::Type)::String
    sql = _duckdb_sql_type_maybe(T)
    sql === nothing && error("No DuckDB column type for Julia element type $T")
    return sql
end

function create_table_sql(
    R::Type,
    table::AbstractString,
    key_columns::Tuple{Vararg{Symbol}}=(),
)::String
    definitions = String[
        "$(_quote_identifier(String(name))) $(_duckdb_sql_type(fieldtype(R, name)))"
        for name in fieldnames(R)
    ]
    if !isempty(key_columns)
        key_list = join((_quote_identifier(String(key)) for key in key_columns), ", ")
        push!(definitions, "PRIMARY KEY ($key_list)")
    end
    return "CREATE TABLE IF NOT EXISTS $(_quote_identifier(table)) " *
        "($(join(definitions, ", ")))"
end

"""
Run a statement that returns no rows and takes no parameters.

The garbage collector may run while DuckDB works on the statement. In the calls that DuckDB.jl
makes, it cannot: it waits for the statement to end, and every other thread waits with it.
"""
function _run(connection::DuckDB.Connection, sql::String)::Nothing
    result = Ref{DuckDB.duckdb_result}()
    state = @ccall gc_safe=true DuckDB.libduckdb.duckdb_query(
        connection.handle::DuckDB.duckdb_connection, sql::Cstring,
        result::Ref{DuckDB.duckdb_result})::DuckDB.duckdb_state
    message = state == DuckDB.DuckDBSuccess ? nothing :
        unsafe_string(DuckDB.duckdb_result_error(result))
    DuckDB.duckdb_destroy_result(result)
    message === nothing || error("DuckDB could not run `$sql`: $message")
    return nothing
end

function _transaction(work::Function, connection)::Nothing
    _run(connection, "BEGIN TRANSACTION")
    try
        work()
        _run(connection, "COMMIT")
    catch
        _run(connection, "ROLLBACK")
        rethrow()
    end
    return nothing
end

function _append_table!(emit::Function, connection, table::AbstractString)::Nothing
    appender = DuckDB.Appender(connection, table)
    try
        emit(appender)
        # As in `_run`: the garbage collector may run while the rows are written.
        @ccall gc_safe=true DuckDB.libduckdb.duckdb_appender_flush(
            appender.handle::DuckDB.duckdb_appender)::DuckDB.duckdb_state
    finally
        DuckDB.close(appender)
    end
    return nothing
end

function _buffer_rows end

# Database-backed ordinary tables

mutable struct RowStore{K,R} <: AbstractDatabaseStore{K,R}
    read_connection::DuckDB.Connection
    # DuckDB connections are not thread-safe; every read_connection use holds this lock.
    read_lock::ReentrantLock
    write_connection::DuckDB.Connection
    table_name::String
    quoted_table::String
    key_columns::Tuple{Vararg{Symbol}}
    quoted_key_columns::Vector{String}
    flush_condition::Base.Threads.Condition
    queued::Dict{K,BufferMutation{R}}
    writing::Dict{K,BufferMutation{R}}
    queued_rows::Int
    writing_rows::Int
    row_limit::Union{Nothing,Int}
    last_flush::Float64
    closing::Bool
    flush_task::Task
end

function RowStore{K,R}(
    database::DuckDB.DB,
    table::AbstractString,
    key_columns::Tuple{Vararg{AbstractString}};
    row_limit::Union{Nothing,Int}=nothing,
) where {K,R}
    row_limit === nothing || row_limit > 0 ||
        throw(ArgumentError("cache buffer row limit must be positive"))
    isempty(key_columns) &&
        throw(ArgumentError("cache buffer requires at least one key column"))
    key_symbols = Tuple(Symbol(String(column)) for column in key_columns)
    quoted_table = _quote_identifier(table)
    quoted_key_columns = String[_quote_identifier(String(column)) for column in key_symbols]
    read_connection = DBInterface.connect(database)
    write_connection = DBInterface.connect(database)
    initial_flush_task = current_task()
    store = RowStore{K,R}(
        read_connection,
        ReentrantLock(),
        write_connection,
        String(table),
        quoted_table,
        key_symbols,
        quoted_key_columns,
        Base.Threads.Condition(),
        Dict{K,BufferMutation{R}}(),
        Dict{K,BufferMutation{R}}(),
        0,
        0,
        row_limit,
        time(),
        false,
        initial_flush_task,
    )
    store.flush_task = Base.Threads.@spawn _flush_loop!(store)
    return store
end

# Database-backed dynamically-widened metadata table

"""A wide metadata column's logical type: the discriminator restoring the [`MetadataValue`](@ref)."""
@enum MetaVType::Int8 begin
    VT_BOOL = 1
    VT_INT = 2
    VT_FLOAT = 3
    VT_STRING = 4
    VT_SYMBOL = 5
    VT_DATE = 6
    VT_DATETIME = 7
    VT_VBOOL = 9
    VT_VINT = 10
    VT_VFLOAT = 11
    VT_VSTRING = 12
end

"""Classify one [`MetadataValue`](@ref) as its wide-column logical type. `missing` is not stored."""
function _meta_vtype(value)::MetaVType
    value isa Bool && return VT_BOOL
    value isa Int64 && return VT_INT
    value isa Float64 && return VT_FLOAT
    value isa String && return VT_STRING
    value isa Symbol && return VT_SYMBOL
    value isa Date && return VT_DATE
    value isa DateTime && return VT_DATETIME
    value isa Vector{Bool} && return VT_VBOOL
    value isa Vector{Int64} && return VT_VINT
    value isa Vector{Float64} && return VT_VFLOAT
    value isa Vector{String} && return VT_VSTRING
    error("No wide-column vtype for $(typeof(value))")
end

"""The Julia type name a wide-column logical type stands for, for conflict messages."""
function _vtype_julia(vtype::MetaVType)::String
    vtype === VT_BOOL && return "Bool"
    vtype === VT_INT && return "Int64"
    vtype === VT_FLOAT && return "Float64"
    vtype === VT_STRING && return "String"
    vtype === VT_SYMBOL && return "Symbol"
    vtype === VT_DATE && return "Date"
    vtype === VT_DATETIME && return "DateTime"
    vtype === VT_VBOOL && return "Vector{Bool}"
    vtype === VT_VINT && return "Vector{Int64}"
    vtype === VT_VFLOAT && return "Vector{Float64}"
    vtype === VT_VSTRING && return "Vector{String}"
    error("No Julia type name for wide-column vtype $vtype")
end

"""One wide-column type conflict: the name, its registered type, and the rejected value's type."""
const WideConflict = Tuple{Symbol,MetaVType,MetaVType}

"""The DuckDB column type storing one wide-column logical type."""
function _meta_vtype_sql(vtype::MetaVType)::String
    vtype === VT_BOOL && return "BOOLEAN"
    vtype === VT_INT && return "BIGINT"
    vtype === VT_FLOAT && return "DOUBLE"
    vtype === VT_STRING && return "VARCHAR"
    vtype === VT_SYMBOL && return "VARCHAR"
    vtype === VT_DATE && return "TIMESTAMP"
    vtype === VT_DATETIME && return "TIMESTAMP"
    vtype === VT_VBOOL && return "BOOLEAN[]"
    vtype === VT_VINT && return "BIGINT[]"
    vtype === VT_VFLOAT && return "DOUBLE[]"
    vtype === VT_VSTRING && return "VARCHAR[]"
    error("No SQL type for wide-column vtype $vtype")
end

"""The value stored in a wide column for one [`MetadataValue`](@ref) (Symbol/Date normalized to SQL)."""
function _encode_wide_value(value)
    value isa Symbol && return String(value)
    value isa Date && return DateTime(value)
    return value
end

"""Restore one [`MetadataValue`](@ref) from a wide-column cell using the registry's logical type."""
function _decode_wide_value(vtype::MetaVType, raw)
    vtype === VT_BOOL && return Bool(raw)
    vtype === VT_INT && return Int64(raw)
    vtype === VT_FLOAT && return Float64(raw)
    vtype === VT_STRING && return String(raw)
    vtype === VT_SYMBOL && return Symbol(String(raw))
    vtype === VT_DATE && return Date(raw)
    vtype === VT_DATETIME && return DateTime(raw)
    vtype === VT_VBOOL && return Vector{Bool}(raw)
    vtype === VT_VINT && return Vector{Int64}(raw)
    vtype === VT_VFLOAT && return Vector{Float64}(raw)
    vtype === VT_VSTRING && return Vector{String}(raw)
    error("No decoder for wide-column vtype $vtype")
end

"""
A dynamically-widened metadata table: one row per entity, one bare column per metadata name.

Reuses the generic database-store queue (`append!`/`edit!`/`delete!`/`clear!`/`close!`) with whole-row
replace semantics. `edit!` type-checks each value against the first type registered for its name,
registers unseen names in memory immediately, and returns the keys it dropped for a type conflict;
the domain layer surfaces those as failures. The flush additively `ALTER TABLE ADD COLUMN`s new names
in one transaction with the keyed deletes and the Appender pass.
"""
mutable struct WideRowStore{K} <: AbstractDatabaseStore{K,MetadataDict}
    read_connection::DuckDB.Connection
    read_lock::ReentrantLock
    write_connection::DuckDB.Connection
    table_name::String
    quoted_table::String
    key_column::Symbol
    quoted_key_column::String
    flush_condition::Base.Threads.Condition
    queued::Dict{K,BufferMutation{MetadataDict}}
    writing::Dict{K,BufferMutation{MetadataDict}}
    queued_rows::Int
    writing_rows::Int
    row_limit::Union{Nothing,Int}
    last_flush::Float64
    closing::Bool
    flush_task::Task
    # Registered columns: their logical type and their physical order (matching the Appender).
    column_vtypes::Dict{Symbol,MetaVType}
    column_order::Vector{Symbol}
    # Names first seen in memory this session, flushed as ALTER TABLE ADD COLUMN + registry insert.
    pending_columns::Vector{Symbol}
end

_buffer_rows(::MetadataDict)::Int = 1

function WideRowStore{K}(
    database::DuckDB.DB,
    table::AbstractString,
    key_column::AbstractString,
) where {K}
    key_symbol = Symbol(String(key_column))
    quoted_table = _quote_identifier(table)
    read_connection = DBInterface.connect(database)
    write_connection = DBInterface.connect(database)
    column_vtypes = Dict{Symbol,MetaVType}()
    for row in DBInterface.execute(
        DBInterface.prepare(
            read_connection,
            "SELECT column_name, vtype FROM wide_columns WHERE table_name = ?"),
        (String(table),),
    )
        column_vtypes[Symbol(String(row.column_name))] = MetaVType(Int8(row.vtype))
    end
    column_order = Symbol[]
    for row in DBInterface.execute(
        DBInterface.prepare(read_connection, """
            SELECT column_name FROM information_schema.columns
            WHERE table_schema = 'main' AND table_name = ?
            ORDER BY ordinal_position
        """),
        (String(table),),
    )
        name = Symbol(String(row.column_name))
        name === key_symbol || push!(column_order, name)
    end
    store = WideRowStore{K}(
        read_connection,
        ReentrantLock(),
        write_connection,
        String(table),
        quoted_table,
        key_symbol,
        _quote_identifier(String(key_column)),
        Base.Threads.Condition(),
        Dict{K,BufferMutation{MetadataDict}}(),
        Dict{K,BufferMutation{MetadataDict}}(),
        0,
        0,
        nothing,
        time(),
        false,
        current_task(),
        column_vtypes,
        column_order,
        Symbol[],
    )
    store.flush_task = Base.Threads.@spawn _flush_loop!(store)
    return store
end

"""
Buffer one whole-row metadata replacement, type-checked against registered columns.

Returns the conflicts dropped from the row: each name whose registered logical type differs from
the incoming value's, with both types. Unseen names register their type immediately, in memory.
The surviving keys are stored; conflicting keys are omitted from the row.
"""
function edit!(store::WideRowStore{K}, key::K, row::MetadataDict)::Vector{WideConflict} where {K}
    dropped = WideConflict[]
    accepted = MetadataDict()
    lock(store.flush_condition) do
        _require_writable(store)
        for (name, value) in row
            value === missing && continue
            incoming = _meta_vtype(value)
            registered = get(store.column_vtypes, name, nothing)
            if registered === nothing
                store.column_vtypes[name] = incoming
                push!(store.column_order, name)
                push!(store.pending_columns, name)
            elseif registered !== incoming
                push!(dropped, (name, registered, incoming))
                continue
            end
            accepted[name] = value
        end
        _accept_rows!(store, key, accepted)
        previous = get(store.queued, key, nothing)
        kind = previous !== nothing && previous.kind === BUFFER_APPEND ?
            BUFFER_APPEND : BUFFER_EDIT
        _set_queued!(store, key, BufferMutation{MetadataDict}(kind, accepted))
    end
    return dropped
end

function Base.read(store::WideRowStore{K})::Dict{K,MetadataDict} where {K}
    while true
        writing, queued, vtypes, stored_columns = lock(store.flush_condition) do
            _require_open(store)
            # Only decode flushed columns from the database; pending names live in queued/writing.
            (
                store.writing,
                store.queued,
                copy(store.column_vtypes),
                setdiff(store.column_order, store.pending_columns),
            )
        end
        rows = Dict{K,MetadataDict}()
        lock(store.read_lock) do
            for database_row in DBInterface.execute(
                store.read_connection, "SELECT * FROM $(store.quoted_table)")
                raw_key = getproperty(database_row, store.key_column)
                dict = MetadataDict()
                for name in stored_columns
                    vtype = vtypes[name]
                    raw = getproperty(database_row, name)
                    ismissing(raw) && continue
                    dict[name] = _decode_wide_value(vtype, raw)
                end
                rows[convert(K, raw_key)] = dict
            end
        end
        stable = lock(store.flush_condition) do
            _require_open(store)
            store.writing === writing && store.queued === queued || return false
            _overlay!(rows, store.writing)
            _overlay!(rows, store.queued)
            true
        end
        stable && return rows
    end
end

function _flush_to_db!(
    store::WideRowStore{K},
    batch::Dict{K,BufferMutation{MetadataDict}},
)::Nothing where {K}
    deleted_keys = K[]
    rows = Pair{K,MetadataDict}[]
    for (key, mutation) in batch
        if mutation.kind === BUFFER_DELETE
            push!(deleted_keys, key)
        else
            mutation.kind === BUFFER_EDIT && push!(deleted_keys, key)
            push!(rows, key => something(mutation.row))
        end
    end
    new_columns, column_order, vtypes = lock(store.flush_condition) do
        (copy(store.pending_columns), copy(store.column_order), copy(store.column_vtypes))
    end
    _transaction(store.write_connection) do
        for name in new_columns
            DBInterface.execute(
                store.write_connection,
                "ALTER TABLE $(store.quoted_table) ADD COLUMN " *
                "$(_quote_identifier(String(name))) $(_meta_vtype_sql(vtypes[name]))",
            )
            DBInterface.execute(
                DBInterface.prepare(
                    store.write_connection, "INSERT INTO wide_columns VALUES (?, ?, ?)"),
                (store.table_name, String(name), Int8(vtypes[name])),
            )
        end
        _delete_keys!(
            store.write_connection,
            store.quoted_table,
            String[store.quoted_key_column],
            deleted_keys,
        )
        isempty(rows) || _append_table!(store.write_connection, store.table_name) do appender
            for (key, dict) in rows
                DuckDB.append(appender, key)
                for name in column_order
                    value = get(dict, name, missing)
                    DuckDB.append(
                        appender, value === missing ? missing : _encode_wide_value(value))
                end
                DuckDB.end_row(appender)
            end
        end
    end
    lock(store.flush_condition) do
        filter!(name -> !(name in new_columns), store.pending_columns)
    end
    return nothing
end

_clear_db!(store::WideRowStore)::Nothing =
    (_transaction(() -> DBInterface.execute(
        store.write_connection, "DELETE FROM $(store.quoted_table)"), store.write_connection);
     nothing)

_reset_memory!(::WideRowStore)::Nothing = nothing

# Memory-only least-recently-used store

"""
A memory-only cache that drops the least recently used values first. `weight(value)` measures each
entry against `capacity`.

Weights are recorded on insertion so later mutation cannot corrupt eviction accounting. One value
larger than the capacity remains usable until another value arrives. Cache eviction only releases
its reference; values held by running consumers remain alive. Writing, reading and removing a value
take the same time for any number of entries.
"""
mutable struct MemoryStore{K,R}
    lock::ReentrantLock
    # Each value with its weight, the least recently used first.
    entries::OrderedDict{K,Tuple{R,Int}}
    size::Int
    capacity::Int
    weight::Function
    closed::Bool
end

function MemoryStore{K,R}(; capacity::Int, weight::Function=_buffer_rows)::MemoryStore{K,R} where {K,R}
    capacity > 0 || throw(ArgumentError("memory cache capacity must be positive"))
    return MemoryStore{K,R}(ReentrantLock(), OrderedDict{K,Tuple{R,Int}}(), 0, capacity, weight, false)
end

function Base.append!(store::MemoryStore{K,R}, key::K, row::R)::Bool where {K,R}
    cost = max(1, store.weight(row))
    lock(store.lock) do
        store.closed && error("memory store is closed")
        replaced = pop!(store.entries, key, nothing)
        replaced === nothing || (store.size -= last(replaced))
        store.entries[key] = (row, cost)
        store.size += cost
        while store.size > store.capacity && length(store.entries) > 1
            _, (_, evicted) = popfirst!(store.entries)
            store.size -= evicted
        end
    end
    return true
end

function Base.delete!(store::MemoryStore{K}, key::K)::Nothing where {K}
    lock(store.lock) do
        store.closed && error("memory store is closed")
        removed = pop!(store.entries, key, nothing)
        removed === nothing || (store.size -= last(removed))
    end
    return nothing
end

"""Return a cache hit marker and its value atomically, or `nothing` on a miss."""
function read_hit(store::MemoryStore{K,R}, key::K)::Union{Nothing,Some} where {K,R}
    return lock(store.lock) do
        store.closed && error("memory store is closed")
        found = pop!(store.entries, key, nothing)
        found === nothing && return nothing
        # The value read becomes the most recently used.
        store.entries[key] = found
        return Some(first(found))
    end
end

function Base.haskey(store::MemoryStore{K}, key::K)::Bool where {K}
    return lock(store.lock) do
        store.closed && error("memory store is closed")
        haskey(store.entries, key)
    end
end

"""The recorded weight of the value under `key`, or `nothing` when there is none."""
function stored_weight(store::MemoryStore{K}, key::K)::Union{Nothing,Int} where {K}
    return lock(store.lock) do
        found = get(store.entries, key, nothing)
        found === nothing ? nothing : last(found)
    end
end

function clear!(store::MemoryStore)::Nothing
    lock(store.lock) do
        store.closed && error("memory store is closed")
        empty!(store.entries)
        store.size = 0
    end
    return nothing
end

function close!(store::MemoryStore)::Nothing
    lock(store.lock) do
        store.closed && error("memory store is already closed")
        store.closed = true
        empty!(store.entries)
        store.size = 0
    end
    return nothing
end

# Shared database queue

_require_open(store::AbstractDatabaseStore)::Nothing =
    store.closing ? error("cache store is closed") : nothing

_require_writable(store::AbstractDatabaseStore)::Nothing =
    (_require_open(store); istaskfailed(store.flush_task) && fetch(store.flush_task); nothing)

function _mutation_rows(
    store::AbstractDatabaseStore{K,R},
    mutation::Union{Nothing,BufferMutation{R}},
)::Int where {K,R}
    (store.row_limit === nothing || mutation === nothing || mutation.row === nothing) && return 0
    return _buffer_rows(mutation.row)
end

function _set_queued!(
    store::AbstractDatabaseStore{K,R},
    key::K,
    mutation::Union{Nothing,BufferMutation{R}},
)::Nothing where {K,R}
    previous = get(store.queued, key, nothing)
    previous === nothing || (store.queued_rows -= _mutation_rows(store, previous))
    was_empty = isempty(store.queued)
    if mutation === nothing
        delete!(store.queued, key)
    else
        store.queued[key] = mutation
        store.queued_rows += _mutation_rows(store, mutation)
    end
    # The flush task is woken only when its wait can end: the queue got its first entry, or
    # reached its limit. A removed entry can make room for a writer that waits. Waking the flush
    # task for every entry makes all writers queue for the lock behind it.
    at_limit = store.row_limit !== nothing && store.queued_rows >= store.row_limit
    (was_empty || at_limit || mutation === nothing) && notify(store.flush_condition)
    return nothing
end

function _accept_rows!(
    store::AbstractDatabaseStore{K,R},
    key::K,
    row::R,
)::Nothing where {K,R}
    store.row_limit === nothing && return nothing
    previous = get(store.queued, key, nothing)
    previous_rows = _mutation_rows(store, previous)
    # A writer waits only while the queue is at its limit, which is also when a flush is due:
    # otherwise the writer and the flush task would wait for each other until the flush interval.
    while store.queued_rows - previous_rows >= store.row_limit
        wait(store.flush_condition)
        _require_writable(store)
        previous = get(store.queued, key, nothing)
        previous_rows = _mutation_rows(store, previous)
    end
    return nothing
end

function Base.append!(
    store::AbstractDatabaseStore{K,R},
    key::K,
    row::R,
)::Bool where {K,R}
    lock(store.flush_condition)
    try
        _require_writable(store)
        _accept_rows!(store, key, row)
        previous = get(store.queued, key, nothing)
        if previous === nothing
            writing = get(store.writing, key, nothing)
            kind = writing === nothing || writing.kind === BUFFER_DELETE ?
                BUFFER_APPEND : BUFFER_EDIT
        else
            kind = previous.kind === BUFFER_APPEND ? BUFFER_APPEND : BUFFER_EDIT
        end
        _set_queued!(store, key, BufferMutation{R}(kind, row))
        return true
    finally
        unlock(store.flush_condition)
    end
end

function edit!(
    store::AbstractDatabaseStore{K,R},
    key::K,
    row::R,
)::Bool where {K,R}
    lock(store.flush_condition)
    try
        _require_writable(store)
        _accept_rows!(store, key, row)
        previous = get(store.queued, key, nothing)
        kind = previous !== nothing && previous.kind === BUFFER_APPEND ?
            BUFFER_APPEND : BUFFER_EDIT
        _set_queued!(store, key, BufferMutation{R}(kind, row))
        return true
    finally
        unlock(store.flush_condition)
    end
end

function Base.delete!(store::AbstractDatabaseStore{K,R}, key::K)::Nothing where {K,R}
    lock(store.flush_condition) do
        _require_writable(store)
        previous = get(store.queued, key, nothing)
        if previous !== nothing && previous.kind === BUFFER_APPEND
            _set_queued!(store, key, nothing)
        else
            _set_queued!(store, key, BufferMutation{R}(BUFFER_DELETE, nothing))
        end
    end
    return nothing
end

"""Wait on a held condition, waking no later than `deadline`; whether the deadline is still ahead."""
function _wait_condition_deadline(condition::Base.Threads.Condition, deadline::Float64)::Bool
    remaining = deadline - time()
    remaining <= 0 && return false
    timer = Timer(remaining) do _
        lock(() -> notify(condition; all=true), condition)
    end
    try
        wait(condition)
    finally
        close(timer)
    end
    return time() < deadline
end

_queue_empty(store::AbstractDatabaseStore)::Bool = isempty(store.queued)

function _flush_due(store::AbstractDatabaseStore, now::Float64)::Bool
    _queue_empty(store) && return false
    at_capacity = store.row_limit !== nothing && store.queued_rows >= store.row_limit
    return store.closing || at_capacity ||
        now - store.last_flush >= CACHE_BUFFER_FLUSH_INTERVAL
end

function _flush_loop!(store::AbstractDatabaseStore{K,R})::Nothing where {K,R}
    while true
        writing = lock(store.flush_condition) do
            while !_flush_due(store, time())
                store.closing && _queue_empty(store) && return nothing
                if _queue_empty(store)
                    # No queued rows means no flush deadline; sleep until an append notifies.
                    wait(store.flush_condition)
                else
                    _wait_condition_deadline(
                        store.flush_condition,
                        store.last_flush + CACHE_BUFFER_FLUSH_INTERVAL,
                    )
                end
            end
            store.writing = store.queued
            store.writing_rows = store.queued_rows
            store.queued = Dict{K,BufferMutation{R}}()
            store.queued_rows = 0
            store.last_flush = time()
            notify(store.flush_condition)
            store.writing
        end
        writing === nothing && return nothing
        try
            @timed_dbg _flush_to_db!(store, writing)
        catch error
            lock(store.flush_condition) do
                notify(store.flush_condition, error; all=true, error=true)
            end
            @error "Cache store flush failed" exception=error
            rethrow()
        end
        lock(store.flush_condition) do
            store.writing = Dict{K,BufferMutation{R}}()
            store.writing_rows = 0
            notify(store.flush_condition)
        end
    end
end

function _read_mutation(
    mutations::Dict{K,BufferMutation{R}},
    key::K,
)::Tuple{Bool,Union{Nothing,R}} where {K,R}
    mutation = get(mutations, key, nothing)
    mutation === nothing && return (false, nothing)
    return mutation.kind === BUFFER_DELETE ? (true, nothing) : (true, mutation.row)
end

# Reads

function _overlay!(
    rows::Dict{K,R},
    mutations::Dict{K,BufferMutation{R}},
)::Nothing where {K,R}
    for (key, mutation) in mutations
        if mutation.kind === BUFFER_DELETE
            delete!(rows, key)
        else
            rows[key] = something(mutation.row)
        end
    end
    return nothing
end

function Base.read(store::RowStore{K,R})::Dict{K,R} where {K,R}
    while true
        writing, queued = lock(store.flush_condition) do
            _require_open(store)
            (store.writing, store.queued)
        end
        rows = Dict{K,R}()
        lock(store.read_lock) do
            for database_row in DBInterface.execute(
                store.read_connection,
                "SELECT * FROM $(store.quoted_table)",
            )
                row = R(database_row)
                values = Tuple(
                    getproperty(database_row, column) for column in store.key_columns)
                raw_key = length(values) == 1 ? only(values) : values
                rows[convert(K, raw_key)] = row
            end
        end
        stable = lock(store.flush_condition) do
            _require_open(store)
            store.writing === writing && store.queued === queued || return false
            _overlay!(rows, store.writing)
            _overlay!(rows, store.queued)
            true
        end
        stable && return rows
    end
end

# Flush

function _delete_keys_with_temp_table!(
    connection,
    quoted_table::String,
    quoted_key_columns::Vector{String},
    keys::Vector{K},
)::Nothing where {K}
    key_types = Base.fieldtypes(K)
    table_name = "mb_delete_keys_$(time_ns())"
    quoted_temp = _quote_identifier(table_name)
    definitions = join(
        (
            "$(quoted_key_columns[index]) $(_duckdb_sql_type(key_types[index]))"
            for index in eachindex(quoted_key_columns)
        ),
        ", ",
    )
    _run(connection, "CREATE TEMPORARY TABLE $quoted_temp ($definitions)")
    try
        _append_table!(connection, table_name) do appender
            for key in keys
                for value in key
                    DuckDB.append(appender, value)
                end
                DuckDB.end_row(appender)
            end
        end
        predicate = join(
            (
                "$quoted_table.$column = $quoted_temp.$column"
                for column in quoted_key_columns
            ),
            " AND ",
        )
        _run(connection, "DELETE FROM $quoted_table USING $quoted_temp WHERE $predicate")
    finally
        _run(connection, "DROP TABLE $quoted_temp")
    end
    return nothing
end

function _delete_keys!(
    connection,
    quoted_table::String,
    quoted_key_columns::Vector{String},
    keys::Vector{K},
)::Nothing where {K}
    isempty(keys) && return nothing
    arity = length(quoted_key_columns)
    if arity > 1
        _delete_keys_with_temp_table!(connection, quoted_table, quoted_key_columns, keys)
        return nothing
    end
    for first_index in 1:CACHE_DELETE_KEY_BATCH:length(keys)
        chunk = @view keys[first_index:min(first_index + CACHE_DELETE_KEY_BATCH - 1, end)]
        placeholders = join(fill("?", length(chunk)), ", ")
        sql = "DELETE FROM $quoted_table WHERE $(only(quoted_key_columns)) " *
            "IN ($placeholders)"
        DBInterface.execute(DBInterface.prepare(connection, sql), chunk)
    end
    return nothing
end

function _flush_to_db!(
    store::RowStore{K,R},
    batch::Dict{K,BufferMutation{R}},
)::Nothing where {K,R}
    deleted_keys = K[]
    rows = R[]
    for (key, mutation) in batch
        if mutation.kind === BUFFER_DELETE
            push!(deleted_keys, key)
        else
            mutation.kind === BUFFER_EDIT && push!(deleted_keys, key)
            push!(rows, something(mutation.row))
        end
    end
    _transaction(store.write_connection) do
        _delete_keys!(
            store.write_connection,
            store.quoted_table,
            store.quoted_key_columns,
            deleted_keys,
        )
        isempty(rows) || _append_table!(store.write_connection, store.table_name) do appender
            for row in rows
                for column in fieldnames(R)
                    DuckDB.append(appender, getproperty(row, column))
                end
                DuckDB.end_row(appender)
            end
        end
    end
    return nothing
end

# Lifecycle

function _clear_db!(store::RowStore)::Nothing
    _transaction(store.write_connection) do
        DBInterface.execute(store.write_connection, "DELETE FROM $(store.quoted_table)")
    end
    return nothing
end

_reset_memory!(store::RowStore)::Nothing = nothing

function clear!(store::AbstractDatabaseStore)::Nothing
    lock(store.flush_condition)
    try
        _require_writable(store)
        empty!(store.queued)
        store.queued_rows = 0
        while !isempty(store.writing)
            wait(store.flush_condition)
            _require_writable(store)
        end
        _clear_db!(store)
        _reset_memory!(store)
        notify(store.flush_condition)
    finally
        unlock(store.flush_condition)
    end
    return nothing
end

function close!(store::AbstractDatabaseStore)::Nothing
    lock(store.flush_condition) do
        store.closing && error("cache store is already closed")
        store.closing = true
        notify(store.flush_condition)
    end
    task_error::Union{Nothing,Exception} = nothing
    try
        wait(store.flush_task)
    catch error
        task_error = error
    end
    try
        DBInterface.close!(store.read_connection)
    finally
        DBInterface.close!(store.write_connection)
    end
    task_error === nothing || throw(task_error)
    return nothing
end
