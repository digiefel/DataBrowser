const CACHE_BUFFER_ROW_LIMIT = 2_000_000
const CACHE_BUFFER_FLUSH_INTERVAL = 2.0
const CACHE_DELETE_KEY_BATCH = 1_000

const MB_SEQ_COLUMN = "__mb_seq"
const MB_ROW_COLUMN = "__mb_row"

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

"""
Append the rows of one payload. The columns come as a tuple, so that this function is compiled for
their element types and appending a value needs no dispatch at run time.
"""
function _append_rows!(appender, seq::UInt32, rows::Int, columns::Tuple)::Nothing
    for row_index in 1:rows
        DuckDB.append(appender, seq)
        DuckDB.append(appender, UInt64(row_index))
        foreach(column -> DuckDB.append(appender, column[row_index]), columns)
        # Ending a row sometimes writes the rows appended so far. As in `_run`, the garbage
        # collector may run meanwhile.
        @ccall gc_safe=true DuckDB.libduckdb.duckdb_appender_end_row(
            appender.handle::DuckDB.duckdb_appender)::DuckDB.duckdb_state
    end
    return nothing
end

const PayloadShape = Tuple{Tuple{Vararg{String}},Tuple{Vararg{String}}}

"""
    can_store_payload(data) -> Bool

Whether the legacy DuckDB payload store can encode this value as table columns. This is an
encoding capability, independent of the item's storage policy. Unsupported values can still be
kept by their native result store. Errors in a declared table's column access are propagated.
"""
function can_store_payload(data)::Bool
    # A named tuple can hold arbitrary named values. It is a column table only when each value
    # is a vector; Tables.jl's iterable fallback also accepts nested blocks of unrelated values.
    data isa NamedTuple && !all(value -> value isa AbstractVector, values(data)) && return false
    Tables.istable(data) || return false
    columns = Tables.columns(data)
    # Typed: `any` and `all` on a vector of unknown type are calls that a package loaded later can invalidate.
    names = collect(Symbol, Tables.columnnames(columns))::Vector{Symbol}
    any(name -> String(name) in (MB_SEQ_COLUMN, MB_ROW_COLUMN), names) && return false
    return all(name -> _duckdb_sql_type_maybe(eltype(Tables.getcolumn(columns, name))) !== nothing, names)
end

"""Column names and DuckDB column types of one tabular payload, via the Tables.jl interface."""
function _payload_shape(data)::PayloadShape
    columns = Tables.columns(data)
    column_names = Tables.columnnames(columns)
    return (
        Tuple(String(name) for name in column_names),
        Tuple(_duckdb_sql_type(eltype(Tables.getcolumn(columns, name)))
              for name in column_names),
    )
end

"""Number of rows in one tabular payload."""
_payload_rows(data)::Int = Tables.rowcount(Tables.columns(data))

_payload_table_name(storage_id::UInt16)::String = "payload_$(storage_id)"

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

# A metadata value is saved as `StructUtils.lower` gives it: numbers, strings, symbols and dates as
# they are, vectors element by element, and any other value as the named tuple of its fields. It is
# read back with `StructUtils.make` and the type the value had.

"""The saved form of one metadata value, which a DuckDB column of [`_saved_sql`](@ref) holds."""
function _saved(value)
    lowered = StructUtils.lower(value)
    lowered isa Symbol && return String(lowered)
    lowered isa Union{Missing,Nothing,Bool,Integer,AbstractFloat,AbstractString,Date,DateTime} && return lowered
    lowered isa Union{AbstractVector,Tuple} && return [_saved(element) for element in lowered]
    fields = StructUtils.make(OrderedDict{Symbol,Any}, lowered)
    return NamedTuple{Tuple(keys(fields))}(Tuple(_saved(field) for field in values(fields)))
end

"""
The DuckDB column type that holds the saved form `saved`. An error when a part of it has no type,
as an empty vector of no element type, or a field that is `nothing`.
"""
function _saved_sql(saved)::String
    saved isa Bool && return "BOOLEAN"
    saved isa Integer && return "BIGINT"
    saved isa AbstractFloat && return "DOUBLE"
    saved isa AbstractString && return "VARCHAR"
    saved isa Date && return "DATE"
    saved isa DateTime && return "TIMESTAMP"
    if saved isa AbstractVector
        isempty(saved) && error("an empty vector has no column type")
        types = unique(_saved_sql.(saved))
        length(types) == 1 || error("a vector holds values of different column types: $(join(types, ", "))")
        return only(types) * "[]"
    end
    saved isa NamedTuple && return "STRUCT(" *
        join(["$(_quote_identifier(String(name))) $(_saved_sql(field))" for (name, field) in pairs(saved)], ", ") * ")"
    error("a part of type $(typeof(saved)) has no column type")
end

"""
The saved form as DuckDB text that a cast to its column type reads, for a column that holds a
`STRUCT`, which the appender cannot write.
"""
function _saved_text(saved)::String
    (saved === missing || saved === nothing) && return "NULL"
    saved isa Bool && return saved ? "true" : "false"
    saved isa Integer && return string(saved)
    saved isa AbstractFloat && return isnan(saved) ? "nan" : isinf(saved) ? (saved > 0 ? "inf" : "-inf") : repr(Float64(saved))
    saved isa Union{AbstractString,Date,DateTime} &&
        return "'" * replace(string(saved), "\\" => "\\\\", "'" => "\\'") * "'"
    saved isa AbstractVector && return "[" * join(_saved_text.(saved), ", ") * "]"
    return "{" * join(["$(_quote_identifier(String(name))): $(_saved_text(field))" for (name, field) in pairs(saved)], ", ") * "}"
end

"""
One metadata column: the name of the Julia type its values have (see [`_type_name`](@ref)), that
type, or `nothing` while its module is not loaded, and the DuckDB column type of its saved values.
"""
struct MetadataColumn
    name::String
    type::Union{Nothing,Type}
    sql::String
end

# A type parameter that `_type_name` can write as it is.
_plain_parameter(x) = x isa Union{Integer,Symbol,Bool} || x isa Tuple && all(_plain_parameter, x)

"""
The name of type `T` in the registry of metadata columns: its module path and name, then its
parameters written the same way. When a parameter is a value that cannot be written so, the type is
named without its parameters, and `StructUtils.make` must build the value from that.
"""
function _type_name(T)::String
    name = Base.typename(Base.unwrap_unionall(T))
    base = join([string.(fullname(name.module))...; string(name.name)], ".")
    T isa DataType && !isempty(T.parameters) || return base
    all(p -> p isa Type || _plain_parameter(p), T.parameters) || return base
    return base * "{" * join([p isa Type ? _type_name(p) : repr(p) for p in T.parameters], ", ") * "}"
end

"""The type named `text` by [`_type_name`](@ref), or `nothing` when its module is not loaded."""
function _named_type(text::AbstractString)::Union{Nothing,Type}
    function find(expression)
        expression === :Main && return Main
        if expression isa Symbol
            modules = Base.loaded_modules_array()
            return modules[findfirst(m -> nameof(m) === expression, modules)]
        end
        expression isa QuoteNode && return expression.value
        expression isa Expr || return expression
        expression.head === :. && return getglobal(find(expression.args[1]), expression.args[2].value)
        expression.head === :tuple && return Tuple(find.(expression.args))
        expression.head === :curly && return find(expression.args[1]){find.(expression.args[2:end])...}
        error("not a type name: $text")
    end
    found = try find(Meta.parse(text)) catch; nothing end
    return found isa Type ? found : nothing
end

"""
A metadata table: one row per entity, one column per metadata name.

A column takes the type of the first value written under its name, and holds the saved form of its
values in a DuckDB type, so that queries can read it. `edit!` returns a message for each value it
leaves out: a value of another type than its column, or one that cannot be saved and built again.
New columns are added with `ALTER TABLE ADD COLUMN` when the buffered rows are written.
"""
mutable struct WideRowStore{K} <: AbstractDatabaseStore{K,Dict{Symbol,Any}}
    read_connection::DuckDB.Connection
    read_lock::ReentrantLock
    write_connection::DuckDB.Connection
    table_name::String
    quoted_table::String
    key_column::Symbol
    quoted_key_column::String
    flush_condition::Base.Threads.Condition
    queued::Dict{K,BufferMutation{Dict{Symbol,Any}}}
    writing::Dict{K,BufferMutation{Dict{Symbol,Any}}}
    queued_rows::Int
    writing_rows::Int
    row_limit::Union{Nothing,Int}
    last_flush::Float64
    closing::Bool
    flush_task::Task
    columns::Dict{Symbol,MetadataColumn}
    # The columns in the order of the table.
    column_order::Vector{Symbol}
    # Columns first seen since the last write, which the table does not have yet.
    pending_columns::Vector{Symbol}
end

_buffer_rows(::Dict{Symbol,Any})::Int = 1

function WideRowStore{K}(
    database::DuckDB.DB,
    table::AbstractString,
    key_column::AbstractString,
) where {K}
    key_symbol = Symbol(String(key_column))
    quoted_table = _quote_identifier(table)
    read_connection = DBInterface.connect(database)
    write_connection = DBInterface.connect(database)
    columns = Dict{Symbol,MetadataColumn}()
    for row in DBInterface.execute(
        DBInterface.prepare(
            read_connection,
            "SELECT column_name, julia_type, sql_type FROM wide_columns WHERE table_name = ?"),
        (String(table),),
    )
        name = String(row.julia_type)
        columns[Symbol(String(row.column_name))] = MetadataColumn(name, _named_type(name), String(row.sql_type))
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
        Dict{K,BufferMutation{Dict{Symbol,Any}}}(),
        Dict{K,BufferMutation{Dict{Symbol,Any}}}(),
        0,
        0,
        nothing,
        time(),
        false,
        current_task(),
        columns,
        column_order,
        Symbol[],
    )
    store.flush_task = Base.Threads.@spawn _flush_loop!(store)
    return store
end

"""
The column that `value` under `name` starts, or the message why it cannot be saved: it has no
DuckDB type, or `StructUtils.make` does not build it again from its saved form.
"""
function _new_column(name::Symbol, value)::Union{MetadataColumn,String}
    T = typeof(value)
    problem = try
        saved = _saved(value)
        sql = _saved_sql(saved)
        isequal(_saved(StructUtils.make(T, saved)), saved) ?
            MetadataColumn(_type_name(T), T, sql) : "its saved form builds a different value"
    catch error
        first(split(sprint(showerror, error), '\n'))
    end
    problem isa MetadataColumn && return problem
    return "metadata :$name cannot be saved: a $T, and $problem"
end

"""
Buffer one whole-row metadata replacement. Returns a message for each value left out of the row:
one whose type differs from its column's, or one that cannot be saved. The first value under a new
name gives its column, at once, in memory.
"""
function edit!(store::WideRowStore{K}, key::K, row::AbstractDict)::Vector{String} where {K}
    dropped = String[]
    accepted = Dict{Symbol,Any}()
    lock(store.flush_condition) do
        _require_writable(store)
        for (name, value) in row
            value === missing && continue
            column = get(store.columns, name, nothing)
            if column === nothing
                column = _new_column(name, value)
                if column isa String
                    push!(dropped, column)
                    continue
                end
                store.columns[name] = column
                push!(store.column_order, name)
                push!(store.pending_columns, name)
            elseif typeof(value) !== column.type && _type_name(typeof(value)) != column.name
                # The workspace of DataBrowserCore gives the same text for a value that it does
                # not keep, so that the error of an item says it once.
                push!(dropped, "metadata :$name has type $(typeof(value)) here but " *
                    "$(something(column.type, column.name)) in earlier items: give it one type in the project, then rebuild the cache")
                continue
            end
            accepted[name] = value
        end
        _accept_rows!(store, key, accepted)
        previous = get(store.queued, key, nothing)
        kind = previous !== nothing && previous.kind === BUFFER_APPEND ?
            BUFFER_APPEND : BUFFER_EDIT
        _set_queued!(store, key, BufferMutation{Dict{Symbol,Any}}(kind, accepted))
    end
    return dropped
end

# A column whose type is not loaded is left out of the rows read.
function Base.read(store::WideRowStore{K})::Dict{K,Dict{Symbol,Any}} where {K}
    while true
        writing, queued, columns, stored_columns = lock(store.flush_condition) do
            _require_open(store)
            # Columns not written yet are only in `queued` and `writing`.
            (
                store.writing,
                store.queued,
                copy(store.columns),
                setdiff(store.column_order, store.pending_columns),
            )
        end
        filter!(name -> columns[name].type !== nothing, stored_columns)
        rows = Dict{K,Dict{Symbol,Any}}()
        lock(store.read_lock) do
            for database_row in DBInterface.execute(
                store.read_connection, "SELECT * FROM $(store.quoted_table)")
                raw_key = getproperty(database_row, store.key_column)
                dict = Dict{Symbol,Any}()
                for name in stored_columns
                    raw = getproperty(database_row, name)
                    ismissing(raw) && continue
                    type = columns[name].type
                    dict[name] = raw isa type ? raw : StructUtils.make(type, raw)
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

# The appender cannot write lists and structs. When the table has such columns, rows go to a staging
# table first, where those columns hold DuckDB text, and then to the table with a cast.
function _flush_to_db!(
    store::WideRowStore{K},
    batch::Dict{K,BufferMutation{Dict{Symbol,Any}}},
)::Nothing where {K}
    deleted_keys = K[]
    rows = Pair{K,Dict{Symbol,Any}}[]
    for (key, mutation) in batch
        if mutation.kind === BUFFER_DELETE
            push!(deleted_keys, key)
        else
            mutation.kind === BUFFER_EDIT && push!(deleted_keys, key)
            push!(rows, key => something(mutation.row))
        end
    end
    new_columns, column_order, columns = lock(store.flush_condition) do
        (copy(store.pending_columns), copy(store.column_order), copy(store.columns))
    end
    nested(name) = occursin(r"\[|STRUCT", columns[name].sql)
    quoted(name) = _quote_identifier(String(name))
    staging = store.table_name * "_staging"
    _transaction(store.write_connection) do
        for name in new_columns
            _run(store.write_connection,
                "ALTER TABLE $(store.quoted_table) ADD COLUMN $(quoted(name)) $(columns[name].sql)")
            DBInterface.execute(
                DBInterface.prepare(
                    store.write_connection, "INSERT INTO wide_columns VALUES (?, ?, ?, ?)"),
                (store.table_name, String(name), columns[name].name, columns[name].sql),
            )
        end
        _delete_keys!(
            store.write_connection,
            store.quoted_table,
            String[store.quoted_key_column],
            deleted_keys,
        )
        isempty(rows) && return
        if !any(nested, column_order)
            _append_table!(store.write_connection, store.table_name) do appender
                for (key, dict) in rows
                    DuckDB.append(appender, key)
                    for name in column_order
                        value = get(dict, name, missing)
                        DuckDB.append(appender, value === missing ? missing : _saved(value))
                    end
                    DuckDB.end_row(appender)
                end
            end
            return
        end
        _run(store.write_connection, "CREATE OR REPLACE TABLE $(_quote_identifier(staging)) AS " *
            "SELECT $(store.quoted_key_column)" *
            join([", $(nested(name) ? "CAST(NULL AS VARCHAR) AS $(quoted(name))" : quoted(name))"
                  for name in column_order]) *
            " FROM $(store.quoted_table) LIMIT 0")
        _append_table!(store.write_connection, staging) do appender
            for (key, dict) in rows
                DuckDB.append(appender, key)
                for name in column_order
                    value = get(dict, name, missing)
                    saved = value === missing ? missing : _saved(value)
                    DuckDB.append(appender, saved !== missing && nested(name) ? _saved_text(saved) : saved)
                end
                DuckDB.end_row(appender)
            end
        end
        _run(store.write_connection, "INSERT INTO $(store.quoted_table) " *
            "SELECT $(store.quoted_key_column)" *
            join([", " * (nested(name) ? "CAST($(quoted(name)) AS $(columns[name].sql))" : quoted(name))
                  for name in column_order]) *
            " FROM $(_quote_identifier(staging))")
        _run(store.write_connection, "DROP TABLE $(_quote_identifier(staging))")
    end
    lock(store.flush_condition) do
        filter!(name -> !(name in new_columns), store.pending_columns)
    end
    return nothing
end

# Memory-only least-recently-used store

"""
A memory-only cache that drops the least recently used values first. `weight(value)` measures each
entry against `capacity`.

Weights are recorded on insertion so later mutation cannot corrupt eviction accounting. One value
larger than the capacity remains usable until another value arrives. Cache eviction only releases
its reference; values held by running consumers remain alive. Writing, reading and removing a value
take the same time for any number of entries.
"""
mutable struct MemoryStore{K,R} <: DataBrowserAPI.AbstractStore
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
# A hit is a copy, which the caller may change.
function read_hit(store::MemoryStore{K,R}, key::K)::Union{Nothing,Some} where {K,R}
    found = lock(store.lock) do
        store.closed && error("memory store is closed")
        found = pop!(store.entries, key, nothing)
        found === nothing && return nothing
        # The value read becomes the most recently used.
        store.entries[key] = found
        return Some(first(found))
    end
    # `deepcopy` of a value of any type is a dynamic call: a `deepcopy` method of a package loaded later then
    # does not invalidate the compiled code here.
    return found === nothing ? nothing : Some(Base.invokelatest(deepcopy, something(found)))
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

# Database-backed tabular table family

# Tables kept as DuckDB columns, one DuckDB table per set of column names and types, under string
# ids. Writes are queued and written in batches by a background task.

# `body` is the caller's original Tables.jl container; pending reads hand it back untouched, and
# the flush loop reads it only through the interface. `container` is the hex-serialized container
# type, carried in the batch because the store's `containers` map can drop a superseded location
# while its append is still being flushed.
struct TabularBodyBatch
    id::String
    body::Any
    container::String
end

_buffer_rows(batch::TabularBodyBatch)::Int = _payload_rows(batch.body)

# The number of tasks that append payload rows during one flush. One task cannot store payloads
# as fast as several workers produce them.
const PAYLOAD_APPEND_TASKS = 4

mutable struct TabularFamilyStore <:
               AbstractDatabaseStore{Tuple{UInt16,UInt32},TabularBodyBatch}
    read_connection::DuckDB.Connection
    # DuckDB connections are not thread-safe; every read_connection use holds this lock.
    read_lock::ReentrantLock
    write_connection::DuckDB.Connection
    # One connection for each task that appends payload rows during a flush.
    append_connections::Vector{DuckDB.Connection}
    flush_condition::Base.Threads.Condition
    queued::Dict{Tuple{UInt16,UInt32},BufferMutation{TabularBodyBatch}}
    writing::Dict{Tuple{UInt16,UInt32},BufferMutation{TabularBodyBatch}}
    queued_rows::Int
    writing_rows::Int
    row_limit::Union{Nothing,Int}
    last_flush::Float64
    closing::Bool
    flush_task::Task
    item_locations::Dict{String,Tuple{UInt16,UInt32}}
    payload_schemas::Dict{PayloadShape,UInt16}
    # Hex-serialized container type per stored payload, rebuilt on read via Tables.materializer.
    containers::Dict{Tuple{UInt16,UInt32},String}
    # Number of rows per stored payload, which sets how many payloads one query of a read takes.
    rows::Dict{Tuple{UInt16,UInt32},Int}
    # The hex-serialized name of each container type stored so far.
    container_names::Dict{Type,String}
    next_seq::UInt32
end

function TabularFamilyStore(
    database::DuckDB.DB;
    row_limit::Union{Nothing,Int}=nothing,
)::TabularFamilyStore
    row_limit === nothing || row_limit > 0 ||
        throw(ArgumentError("cache buffer row limit must be positive"))
    read_connection = DBInterface.connect(database)
    write_connection = DBInterface.connect(database)
    _run(write_connection, """
        CREATE TABLE IF NOT EXISTS item_data(
            id VARCHAR PRIMARY KEY,
            storage_id USMALLINT,
            seq UINTEGER,
            container TEXT,
            rows UBIGINT,
            UNIQUE (storage_id, seq))""")
    _run(write_connection, """
        CREATE TABLE IF NOT EXISTS payload_schemas(
            storage_id USMALLINT PRIMARY KEY,
            column_names VARCHAR[],
            column_types VARCHAR[])""")
    locations = Dict{String,Tuple{UInt16,UInt32}}()
    containers = Dict{Tuple{UInt16,UInt32},String}()
    rows = Dict{Tuple{UInt16,UInt32},Int}()
    for row in DBInterface.execute(
        read_connection, "SELECT id, storage_id, seq, container, rows FROM item_data")
        location = (UInt16(row.storage_id), UInt32(row.seq))
        locations[String(row.id)] = location
        containers[location] = String(row.container)
        rows[location] = Int(row.rows)
    end
    schemas = Dict{PayloadShape,UInt16}()
    for row in DBInterface.execute(
        read_connection,
        "SELECT storage_id, column_names, column_types FROM payload_schemas",
    )
        shape = (
            Tuple(String(name) for name in row.column_names),
            Tuple(String(type) for type in row.column_types),
        )
        schemas[shape] = UInt16(row.storage_id)
    end
    max_seq = Int128(only(DBInterface.execute(
        read_connection,
        "SELECT coalesce(max(seq), 0) AS seq FROM item_data",
    )).seq)
    # A flush that stopped half way leaves payload rows that `item_data` does not name. Their
    # sequence numbers are not given out again.
    for storage_id in values(schemas)
        table = _quote_identifier(_payload_table_name(storage_id))
        max_seq = max(max_seq, Int128(only(DBInterface.execute(
            read_connection, "SELECT coalesce(max($MB_SEQ_COLUMN), 0) AS seq FROM $table")).seq))
    end
    max_seq < typemax(UInt32) ||
        error("Processed-data cache exhausted its UInt32 sequence space")
    store = TabularFamilyStore(
        read_connection,
        ReentrantLock(),
        write_connection,
        [DBInterface.connect(database) for _ in 1:PAYLOAD_APPEND_TASKS],
        Base.Threads.Condition(),
        Dict{Tuple{UInt16,UInt32},BufferMutation{TabularBodyBatch}}(),
        Dict{Tuple{UInt16,UInt32},BufferMutation{TabularBodyBatch}}(),
        0,
        0,
        row_limit,
        time(),
        false,
        current_task(),
        locations,
        schemas,
        containers,
        rows,
        Dict{Type,String}(),
        UInt32(max_seq + 1),
    )
    store.flush_task = Base.Threads.@spawn _flush_loop!(store)
    return store
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

function _queue_delete_location!(
    store::TabularFamilyStore,
    location::Tuple{UInt16,UInt32},
)::Nothing
    delete!(store.containers, location)
    delete!(store.rows, location)
    previous = get(store.queued, location, nothing)
    if previous !== nothing && previous.kind === BUFFER_APPEND
        _set_queued!(store, location, nothing)
    else
        _set_queued!(
            store,
            location,
            BufferMutation{TabularBodyBatch}(BUFFER_DELETE, nothing),
        )
    end
    return nothing
end

function Base.append!(
    store::TabularFamilyStore,
    payload_key::String,
    body,
)::Bool
    any(
        name -> String(name) in (MB_SEQ_COLUMN, MB_ROW_COLUMN),
        collect(Symbol, Tables.columnnames(Tables.columns(body)))::Vector{Symbol},
    ) && error(
        "Table '$payload_key' uses a reserved cache column name " *
        "'$MB_SEQ_COLUMN' or '$MB_ROW_COLUMN'",
    )
    lock(store.flush_condition)
    try
        _require_writable(store)
        batch = TabularBodyBatch(
            payload_key, body,
            get!(() -> something(_serialize_hex(typeof(body))), store.container_names, typeof(body)))
        old_location = get(store.item_locations, payload_key, nothing)
        old_mutation = old_location === nothing ?
            nothing : get(store.queued, old_location, nothing)
        old_rows = _mutation_rows(store, old_mutation)
        # A writer waits only while the queue is at its limit, which is also when a flush is due.
        while store.row_limit !== nothing && store.queued_rows - old_rows >= store.row_limit
            wait(store.flush_condition)
            _require_writable(store)
            old_location = get(store.item_locations, payload_key, nothing)
            old_mutation = old_location === nothing ?
                nothing : get(store.queued, old_location, nothing)
            old_rows = _mutation_rows(store, old_mutation)
        end
        shape = _payload_shape(body)
        store.next_seq < typemax(UInt32) ||
            error("Processed-data cache exhausted its UInt32 sequence space")
        storage_id = get(store.payload_schemas, shape, nothing)
        if storage_id === nothing
            next_storage_id = isempty(store.payload_schemas) ?
                0 : maximum(Int, values(store.payload_schemas)) + 1
            next_storage_id <= typemax(UInt16) ||
                error("Processed-data cache exhausted its UInt16 payload shape space")
            storage_id = UInt16(next_storage_id)
            store.payload_schemas[shape] = storage_id
        end
        location = (storage_id, store.next_seq)
        store.next_seq += UInt32(1)
        old_location = pop!(store.item_locations, payload_key, nothing)
        store.item_locations[payload_key] = location
        store.containers[location] = batch.container
        store.rows[location] = _payload_rows(batch.body)
        old_location === nothing || _queue_delete_location!(store, old_location)
        _set_queued!(
            store,
            location,
            BufferMutation{TabularBodyBatch}(BUFFER_APPEND, batch),
        )
        return true
    finally
        unlock(store.flush_condition)
    end
end

function Base.delete!(store::TabularFamilyStore, payload_key::String)::Nothing
    lock(store.flush_condition) do
        _require_writable(store)
        location = pop!(store.item_locations, payload_key, nothing)
        location === nothing || _queue_delete_location!(store, location)
    end
    return nothing
end

function Base.haskey(store::TabularFamilyStore, payload_key::String)::Bool
    return lock(store.flush_condition) do
        _require_open(store)
        haskey(store.item_locations, payload_key)
    end
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

function _pending_tabular_body(
    store::TabularFamilyStore,
    location::Tuple{UInt16,UInt32},
)::Tuple{Bool,Any}
    queued = _read_mutation(store.queued, location)
    # A payload that waits to be written is handed out as a copy, as one read from the database is new.
    queued[1] && return (true, queued[2] === nothing ? nothing : Base.invokelatest(deepcopy, queued[2].body))
    writing = _read_mutation(store.writing, location)
    return writing[1] ?
        (true, writing[2] === nothing ? nothing : Base.invokelatest(deepcopy, writing[2].body)) :
        (false, nothing)
end

# The most values that one query of a read returns, about 20 MiB of numbers, which the reader holds
# in memory once more while it places them.
const READ_BATCH_VALUES = 2_500_000
const READ_BATCH_PAYLOADS = 1024

"""
Read the stored payloads at `locations`, each as a `NamedTuple` of columns. `locations` gives the
number of values of each payload, rows times columns.

A read is split into queries of at most `READ_BATCH_VALUES` values, and a payload larger than that
has a query of its own.
"""
function _read_tabular_locations(
    store::TabularFamilyStore,
    locations::Dict{Tuple{UInt16,UInt32},Int},
)::Dict{Tuple{UInt16,UInt32},Any}
    by_storage = Dict{UInt16,Vector{UInt32}}()
    for (storage_id, seq) in keys(locations)
        push!(get!(() -> UInt32[], by_storage, storage_id), seq)
    end
    rows_by_location = Dict{Tuple{UInt16,UInt32},Any}()
    # The column names and DuckDB column types of each payload table.
    shapes = lock(() -> Dict(storage_id => shape for (shape, storage_id) in store.payload_schemas), store.flush_condition)
    for (storage_id, seqs) in by_storage
        table = _quote_identifier(_payload_table_name(storage_id))
        remaining = sort!(seqs)
        while !isempty(remaining)
            batch, batch_values = 1, locations[(storage_id, remaining[1])]
            while batch < min(length(remaining), READ_BATCH_PAYLOADS) &&
                    batch_values + locations[(storage_id, remaining[batch+1])] <= READ_BATCH_VALUES
                batch += 1
                batch_values += locations[(storage_id, remaining[batch])]
            end
            batch_seqs = splice!(remaining, 1:batch)
            names, types = shapes[storage_id]
            payloads = all(type -> haskey(DIRECT_READ_TYPES, type), types) ?
                _read_direct(store, table, storage_id, batch_seqs, names, types) : nothing
            payloads === nothing && (payloads = _read_converted(store, table, storage_id, batch_seqs))
            for seq in batch_seqs
                rows_by_location[(storage_id, seq)] = payloads[seq]
            end
        end
    end
    return rows_by_location
end

# The Julia element type of each DuckDB column type that a read copies straight from the query
# result, with no conversion.
const DIRECT_READ_TYPES = Dict{String,DataType}(
    "BOOLEAN" => Bool, "TINYINT" => Int8, "SMALLINT" => Int16, "INTEGER" => Int32, "BIGINT" => Int64,
    "UTINYINT" => UInt8, "USMALLINT" => UInt16, "UINTEGER" => UInt32, "UBIGINT" => UInt64,
    "FLOAT" => Float32, "DOUBLE" => Float64)

"""
Read the payloads `seqs` of one payload table whose column types are all in `DIRECT_READ_TYPES`.
Each value is copied from the chunks of the query result to its row in its payload, with no other
copy. `nothing` when a column has a missing value; the caller reads those payloads with
`_read_converted`.
"""
function _read_direct(store::TabularFamilyStore, table::String, storage_id::UInt16, seqs::Vector{UInt32}, names, types)
    element_types = [DIRECT_READ_TYPES[type] for type in types]
    columns = Dict{UInt32,Vector{AbstractVector}}(
        seq => AbstractVector[Vector{T}(undef, store.rows[(storage_id, seq)]) for T in element_types]
        for seq in seqs)
    selected = join([MB_SEQ_COLUMN; MB_ROW_COLUMN; _quote_identifier.(collect(names))], ", ")
    placeholders = join(fill("?", length(seqs)), ", ")
    runs = Run[]
    complete = lock(store.read_lock) do
        result = _execute_on_duckdb_threads(store.read_connection,
            "SELECT $selected FROM $table WHERE $MB_SEQ_COLUMN IN ($placeholders)", seqs)
        try
            while (chunk = DuckDB.nextDataChunk(result)) !== missing
                try
                    size = Int(DuckDB.get_size(chunk))
                    all(index -> DuckDB.all_valid(chunk, index + 2), eachindex(element_types)) || return false
                    # The chunk's own memory, of which the first `size` values are its rows.
                    _runs!(runs, columns, DuckDB.get_array(chunk, 1, UInt32), DuckDB.get_array(chunk, 2, UInt64), size)
                    for (index, T) in enumerate(element_types)
                        _scatter!(runs, index, DuckDB.get_array(chunk, index + 2, T))
                    end
                finally
                    DuckDB.destroy_data_chunk(chunk)
                end
            end
            return true
        finally
            DBInterface.close!(result)
        end
    end
    complete || return nothing
    data_names = Tuple(Symbol.(names))
    return Dict(seq => NamedTuple{data_names}(Tuple(columns[seq])) for seq in seqs)
end

"""
Read the payloads `seqs` of one payload table through DuckDB.jl's conversion of the query result to
Julia columns, which handles every column type and missing values.
"""
function _read_converted(store::TabularFamilyStore, table::String, storage_id::UInt16, seqs::Vector{UInt32})
    seq_name, row_name = Symbol(MB_SEQ_COLUMN), Symbol(MB_ROW_COLUMN)
    placeholders = join(fill("?", length(seqs)), ", ")
    # One materialized query, which DuckDB runs on all threads. Its rows come in no order; each
    # value goes to its place from the seq and row columns.
    result = lock(store.read_lock) do
        Tables.columntable(_execute_on_duckdb_threads(store.read_connection,
            "SELECT * FROM $table WHERE $MB_SEQ_COLUMN IN ($placeholders)", seqs))
    end
    data_names = Tuple(name for name in keys(result) if name ∉ (seq_name, row_name))
    seq_column, row_column = result[seq_name], result[row_name]
    columns = Dict{UInt32,Vector{AbstractVector}}(
        seq => AbstractVector[similar(result[name], store.rows[(storage_id, seq)]) for name in data_names]
        for seq in seqs)
    runs = _runs!(Run[], columns, seq_column, row_column, length(seq_column))
    for (index, name) in enumerate(data_names)
        _scatter!(runs, index, result[name])
    end
    return Dict(seq => NamedTuple{data_names}(Tuple(map(columns[seq]) do column
        # The database reports a column as one that allows missing values when any row of the
        # query has one; a payload column without missing values comes back without it.
        Missing <: eltype(column) && !any(ismissing, column) ?
            convert(Vector{nonmissingtype(eltype(column))}, column) : column
    end)) for seq in seqs)
end

# Run a query whose result is materialized. DuckDB.jl's `execute` runs the query's work on one
# Julia task per Julia thread, which wait for work by yielding in a loop; when other work takes
# those threads, the query slows down several times. Here the calling task runs DuckDB's tasks
# one by one while DuckDB's own threads run the others (the store opens the file with
# `external_threads = 1`).
# TODO(maintenance): uses DuckDB.jl internals (`Stmt`, `PendingQueryResult`, `QueryResult`).
function _execute_on_duckdb_threads(connection::DuckDB.Connection, sql::AbstractString, parameters)
    statement = DuckDB.Stmt(connection, sql, DuckDB.MaterializedResult)
    try
        DuckDB.bind_parameters(statement, parameters)
        pending = DuckDB.PendingQueryResult(statement)
        if !pending.success || !DuckDB.pending_execute_tasks(pending)
            throw(DuckDB.QueryException(DuckDB.get_error(statement, pending)))
        end
        handle = Ref{DuckDB.duckdb_result}()
        if DuckDB.duckdb_execute_pending(pending.handle, handle) != DuckDB.DuckDBSuccess
            message = DuckDB.fetch_error(sql, DuckDB.duckdb_result_error(handle))
            DuckDB.duckdb_destroy_result(handle)
            throw(DuckDB.QueryException(message))
        end
        return DuckDB.QueryResult(handle)
    finally
        DuckDB._close_stmt(statement)
    end
end

# Consecutive query rows that go to consecutive rows of one payload: the payload's columns, the
# first row there, the first query row and the number of rows.
const Run = Tuple{Vector{AbstractVector},Int,Int,Int}

# The runs of the first `count` query rows, whose payloads and rows are in `seqs` and `rows`. The
# rows of one payload mostly follow each other, so a chunk of query rows has few runs.
function _runs!(runs::Vector{Run}, columns::Dict{UInt32,Vector{AbstractVector}}, seqs::AbstractVector, rows::AbstractVector, count::Int)
    empty!(runs)
    checkbounds(seqs, 1:count); checkbounds(rows, 1:count)
    position = 1
    @inbounds while position <= count
        run_end = position
        while run_end < count && seqs[run_end+1] == seqs[position] && rows[run_end+1] == rows[run_end] + 1
            run_end += 1
        end
        push!(runs, (columns[seqs[position]], Int(rows[position]), position, run_end - position + 1))
        position = run_end + 1
    end
    return runs
end

# Copy each run of `values` to the column `index` of its payload.
function _scatter!(runs::Vector{Run}, index::Int, values::AbstractVector{T}) where {T}
    for (payload, row, position, count) in runs
        copyto!(payload[index]::Vector{T}, row, values, position, count)
    end
    return nothing
end

"""
Rebuild one stored payload as the container type it was stored with, via `Tables.materializer`.
A container type that no longer deserializes (changed project code) is a cache miss — the cache
may always be rebuilt — so the caller recomputes and replaces the entry.
"""
function _materialize_payload(store::TabularFamilyStore, location::Tuple{UInt16,UInt32}, columns)
    hex = get(store.containers, location, nothing)
    hex === nothing && return columns
    container = try
        _deserialize_hex(hex)
    catch
        return nothing
    end
    return materialized(container, columns)
end

# The columns of a payload just read, as a `container`. The columns are new arrays that nothing
# else holds, so a container type may take them without copying them.
materialized(container, columns) = Tables.materializer(container)(columns)

function Base.read(
    store::TabularFamilyStore,
    payload_keys::Vector{String},
)::Dict{String,Any}
    # Typed, as each pass replaces it: a captured variable that changes is otherwise of unknown type.
    remaining::Vector{String} = unique(payload_keys)
    results = Dict{String,Any}()
    while !isempty(remaining)
        locations = Dict{String,Tuple{UInt16,UInt32}}()
        stored_values = Dict{Tuple{UInt16,UInt32},Int}()
        lock(store.flush_condition) do
            _require_open(store)
            columns = Dict(storage_id => length(first(shape)) for (shape, storage_id) in store.payload_schemas)
            for key in remaining
                location = get(store.item_locations, key, nothing)
                if location === nothing
                    results[key] = nothing
                    continue
                end
                handled, data = _pending_tabular_body(store, location)
                if handled
                    results[key] = data
                else
                    locations[key] = location
                    stored_values[location] = store.rows[location] * columns[first(location)]
                end
            end
        end
        isempty(locations) && break
        stored_rows = _read_tabular_locations(store, stored_values)
        retry = String[]
        lock(store.flush_condition) do
            _require_open(store)
            for (key, location) in locations
                current_location = get(store.item_locations, key, nothing)
                if current_location === nothing
                    results[key] = nothing
                    continue
                end
                handled, data = _pending_tabular_body(store, current_location)
                if handled
                    results[key] = data
                elseif current_location == location
                    results[key] = _materialize_payload(store, location, stored_rows[location])
                else
                    push!(retry, key)
                end
            end
        end
        remaining = retry
    end
    return results
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

function _delete_payloads!(
    connection,
    locations::Vector{Tuple{UInt16,UInt32}},
)::Nothing
    # TODO: add a cold processed-data maintenance pass that drops unreferenced
    # payload tables, prunes stale payload_schemas rows, checkpoints/compacts
    # DuckDB, and optionally rewrites rows in WorkspaceIndex item order for locality.
    # Keep it out of flush: deletes here should stay blind and cheap.
    isempty(locations) && return nothing
    by_storage = Dict{UInt16,Vector{UInt32}}()
    for (storage_id, seq) in locations
        push!(get!(() -> UInt32[], by_storage, storage_id), seq)
    end
    for (storage_id, seqs) in by_storage
        table = _quote_identifier(_payload_table_name(storage_id))
        for first_index in 1:CACHE_DELETE_KEY_BATCH:length(seqs)
            chunk = @view seqs[first_index:min(first_index + CACHE_DELETE_KEY_BATCH - 1, end)]
            placeholders = join(fill("?", length(chunk)), ", ")
            DBInterface.execute(
                DBInterface.prepare(
                    connection,
                    "DELETE FROM $table WHERE $MB_SEQ_COLUMN IN ($placeholders)",
                ),
                Tuple(chunk),
            )
        end
    end
    _delete_keys!(
        connection,
        _quote_identifier("item_data"),
        String[_quote_identifier("storage_id"), _quote_identifier("seq")],
        locations,
    )
    return nothing
end

function _flush_to_db!(
    store::TabularFamilyStore,
    batch::Dict{
        Tuple{UInt16,UInt32},
        BufferMutation{TabularBodyBatch},
    },
)::Nothing
    deleted = Tuple{UInt16,UInt32}[]
    appends = Pair{Tuple{UInt16,UInt32},TabularBodyBatch}[]
    for (location, mutation) in batch
        if mutation.kind === BUFFER_DELETE
            push!(deleted, location)
        elseif mutation.kind === BUFFER_APPEND
            push!(appends, location => something(mutation.row))
        else
            error("TabularFamilyStore replaces physical data with delete plus append, never edit")
        end
    end
    groups = Dict{UInt16,Vector{Pair{Tuple{UInt16,UInt32},TabularBodyBatch}}}()
    for append in appends
        push!(get!(() -> Pair{Tuple{UInt16,UInt32},TabularBodyBatch}[], groups, append.first[1]), append)
    end
    # The flush has three transactions, so that several tasks can append the payload rows. A
    # reader finds a payload through `item_data`, which is written last.
    _transaction(store.write_connection) do
        _delete_payloads!(store.write_connection, deleted)
        for (storage_id, storage_appends) in groups
            columns, types = _payload_shape(first(storage_appends).second.body)
            definitions = join(
                ("$(_quote_identifier(name)) $type" for (name, type) in zip(columns, types)), ", ")
            table = _quote_identifier(_payload_table_name(storage_id))
            DBInterface.execute(
                store.write_connection,
                "CREATE TABLE IF NOT EXISTS $table (" *
                "$MB_SEQ_COLUMN UINTEGER, $MB_ROW_COLUMN UBIGINT, $definitions)",
            )
            DBInterface.execute(
                DBInterface.prepare(
                    store.write_connection,
                    """
                    INSERT INTO payload_schemas VALUES (?, ?, ?)
                    ON CONFLICT (storage_id) DO NOTHING
                    """,
                ),
                (storage_id, collect(columns), collect(types)),
            )
        end
    end
    isempty(appends) && return nothing

    # Each task takes parts of the payloads of one table until none is left.
    parts = Channel{Tuple{UInt16,Vector{Pair{Tuple{UInt16,UInt32},TabularBodyBatch}}}}(Inf)
    for (storage_id, storage_appends) in groups,
            part in Iterators.partition(storage_appends, cld(length(storage_appends), PAYLOAD_APPEND_TASKS))
        put!(parts, (storage_id, collect(part)))
    end
    close(parts)
    tasks = map(store.append_connections) do connection
        Base.Threads.@spawn for (storage_id, part) in parts
            columns, types = _payload_shape(first(groups[storage_id]).second.body)
            _transaction(connection) do
                _append_table!(connection, _payload_table_name(storage_id)) do appender
                    for (location, entry) in part
                        body_columns = Tables.columns(entry.body)
                        _payload_shape(entry.body) == (columns, types) ||
                            error("Storage id $storage_id has incompatible payload shapes")
                        _append_rows!(appender, location[2], _payload_rows(entry.body), Tuple(
                            Tables.getcolumn(body_columns, Symbol(name)) for name in columns))
                    end
                end
            end
        end
    end
    # Every writer finishes before the payload locations are recorded, also when one fails.
    waitall(tasks; failfast=false)

    _transaction(store.write_connection) do
        _append_table!(store.write_connection, "item_data") do appender
            for (location, entry) in appends
                DuckDB.append(appender, entry.id)
                DuckDB.append(appender, location[1])
                DuckDB.append(appender, location[2])
                DuckDB.append(appender, entry.container)
                DuckDB.append(appender, UInt64(_payload_rows(entry.body)))
                DuckDB.end_row(appender)
            end
        end
    end
    return nothing
end

# Lifecycle

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
        store isa TabularFamilyStore && foreach(DBInterface.close!, store.append_connections)
    finally
        DBInterface.close!(store.write_connection)
    end
    task_error === nothing || throw(task_error)
    return nothing
end
