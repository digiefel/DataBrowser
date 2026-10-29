# Column storage: the status word of each row, ids and labels as bytes, and metadata layers.

# Status

@enum Validity::UInt8 MISSING STALE FRESH REMOVED

"""
The status of one stage on one row.

`validity` says whether the output matches the current input revision, `running` whether a job for
it runs, `failed` whether the last job for this revision failed, `output` whether the output is
present, `absent` whether the project defines no such stage for the row, and `blocked` whether an
input it needs failed or is blocked, so that no job can make it fresh until that input is retried or
invalidated. Whether a job waits in the queue is not part of the status: the queue holds it.
"""
struct StageStatus
    validity::Validity
    running::Bool
    failed::Bool
    output::Bool
    absent::Bool
    blocked::Bool
    revision::UInt32
end

StageStatus(;
    validity=MISSING, running=false, failed=false, output=false, absent=false, blocked=false, revision=0,
) = StageStatus(validity, running, failed, output, absent, blocked, revision)

"""A copy of `old` with the given fields changed."""
StageStatus(
    old::StageStatus;
    validity=old.validity,
    running=old.running,
    failed=old.failed,
    output=old.output,
    absent=old.absent,
    blocked=old.blocked,
    revision=old.revision,
) = StageStatus(validity, running, failed, output, absent, blocked, revision)

# One stage in 32 bits: validity 0–1, running 2, failed 3, output 4, absent 5, blocked 6,
# revision 8–31.
StageStatus(bits::UInt32) = StageStatus(
    Validity(bits & 0x3),
    isodd(bits >> 2),
    isodd(bits >> 3),
    isodd(bits >> 4),
    isodd(bits >> 5),
    isodd(bits >> 6),
    bits >> 8,
)

Base.UInt32(status::StageStatus) =
    UInt32(status.validity) |
    UInt32(status.running) << 2 |
    UInt32(status.failed) << 3 |
    UInt32(status.output) << 4 |
    UInt32(status.absent) << 5 |
    UInt32(status.blocked) << 6 |
    (status.revision & 0x00ff_ffff) << 8

"""The status word of a row whose two stages have the given status."""
word(first::StageStatus, second::StageStatus)::UInt64 =
    UInt64(UInt32(first)) | UInt64(UInt32(second)) << 32

"""
Status words of one table, one per row. Readers need no lock; writers, including growth, hold the
catalog's lock. Growth replaces `words` with a copy twice as long, so a reader holding the old
array sees the words as they were a moment earlier.
"""
mutable struct StatusColumn
    @atomic words::AtomicMemory{UInt64}
    length::Int
end

StatusColumn() = StatusColumn(AtomicMemory{UInt64}(undef, 64), 0)

function Base.push!(column::StatusColumn, value::UInt64)::StatusColumn
    words = @atomic column.words
    if column.length == length(words)
        grown = AtomicMemory{UInt64}(undef, 2 * length(words))
        for row in 1:column.length
            @atomic grown[row] = @atomic words[row]
        end
        @atomic column.words = grown
        words = grown
    end
    column.length += 1
    @atomic words[column.length] = value
    return column
end

function Base.getindex(column::StatusColumn, row::Integer)::UInt64
    words = @atomic column.words
    return @atomic words[row]
end

function Base.setindex!(column::StatusColumn, value::UInt64, row::Integer)::StatusColumn
    words = @atomic column.words
    @atomic words[row] = value
    return column
end

# Text

"""
Public ids of one table in one byte buffer, in row order. An id never changes, so a row stores only
where its id ends; it starts after the previous row's. A buffer holds at most 4 GiB.
"""
struct IdColumn
    bytes::Vector{UInt8}
    ends::Vector{UInt32}
end

IdColumn() = IdColumn(UInt8[], UInt32[])

Base.length(column::IdColumn) = length(column.ends)

function Base.push!(column::IdColumn, id::AbstractString)::IdColumn
    push!(column.ends, length(column.bytes) + ncodeunits(id))
    append!(column.bytes, codeunits(id))
    return column
end

function Base.view(column::IdColumn, row::Integer)
    start = row == 1 ? 1 : Int(column.ends[row-1]) + 1
    return view(column.bytes, start:Int(column.ends[row]))
end

"""
Labels of one table in one byte buffer, with the start and length of each row's label. A changed
label is appended and the row points to it; the old bytes stay until compaction. A buffer holds at
most 4 GiB.
"""
struct LabelColumn
    bytes::Vector{UInt8}
    starts::Vector{UInt32}
    lengths::Vector{UInt32}
end

LabelColumn() = LabelColumn(UInt8[], UInt32[], UInt32[])

function Base.push!(column::LabelColumn, label::AbstractString)::LabelColumn
    push!(column.starts, 0)
    push!(column.lengths, 0)
    column[length(column.starts)] = label
    return column
end

function Base.setindex!(column::LabelColumn, label::AbstractString, row::Integer)::LabelColumn
    column.starts[row] = length(column.bytes) + 1
    column.lengths[row] = ncodeunits(label)
    append!(column.bytes, codeunits(label))
    return column
end

function Base.view(column::LabelColumn, row::Integer)
    start = Int(column.starts[row])
    return view(column.bytes, start:start+Int(column.lengths[row])-1)
end

Base.getindex(column::Union{IdColumn,LabelColumn}, row::Integer)::String = String(view(column, row))

"""
The producing targets each item reads, in input order: its source item's expand, or the exact
row and stage supplying an input to a computed value. New inputs of a row are added at the end,
and the row points to them.
"""
struct InputColumn
    keys::Vector{Target}
    starts::Vector{UInt32}
    lengths::Vector{UInt32}
end

InputColumn() = InputColumn(Target[], UInt32[], UInt32[])

function Base.push!(column::InputColumn, keys)::InputColumn
    push!(column.starts, length(column.keys) + 1)
    append!(column.keys, keys)
    push!(column.lengths, length(column.keys) - column.starts[end] + 1)
    return column
end

# TODO: the inputs a row no longer points to stay in `keys` until the workspace closes.
function Base.setindex!(column::InputColumn, keys, row::Integer)::InputColumn
    column.starts[row] = length(column.keys) + 1
    append!(column.keys, keys)
    column.lengths[row] = length(column.keys) - column.starts[row] + 1
    return column
end

function Base.view(column::InputColumn, row::Integer)
    start = Int(column.starts[row])
    return view(column.keys, start:start+Int(column.lengths[row])-1)
end

"""
Public id → key of one table. A key is found by `hash(id)` and confirmed against the stored id; an
id whose hash is already taken goes into `collisions`.
"""
struct IdLookup{K}
    ids::IdColumn
    by_hash::Dict{UInt64,K}
    collisions::Dict{String,K}
end

IdLookup{K}(ids::IdColumn) where {K} = IdLookup{K}(ids, Dict{UInt64,K}(), Dict{String,K}())

function Base.get(lookup::IdLookup, id::AbstractString, default)
    key = get(lookup.by_hash, hash(id), nothing)
    key !== nothing && view(lookup.ids, key.index) == codeunits(id) && return key
    isempty(lookup.collisions) && return default
    return get(lookup.collisions, id, default)
end

function Base.setindex!(lookup::IdLookup{K}, key::K, id::AbstractString) where {K}
    slot = hash(id)
    if haskey(lookup.by_hash, slot)
        lookup.collisions[String(id)] = key
    else
        lookup.by_hash[slot] = key
    end
    return lookup
end

function Base.delete!(lookup::IdLookup, id::AbstractString)
    if haskey(lookup.collisions, id)
        delete!(lookup.collisions, id)
        return lookup
    end
    slot = hash(id)
    delete!(lookup.by_hash, slot)
    # An id with the same hash moves from the side table into the freed place.
    for (other, key) in lookup.collisions
        hash(other) == slot || continue
        delete!(lookup.collisions, other)
        lookup.by_hash[slot] = key
        break
    end
    return lookup
end

# Metadata

"""
What a set of metadata comes from: the stage that produced it, or, for a collection, `:collection`
for the metadata of its value and `:source` for the metadata its source gives it.
"""
const MetadataLayer = Union{PipelineStage,Symbol}

"""
A metadata value that was not stored: its name already holds values of type `expected` in the same
layer, and the value has type `found`.
"""
struct MetadataConflict
    name::Symbol
    expected::Type
    found::Type
end

"""
One layer of metadata for the rows of one table: one column per name, holding
`missing` for rows without a value. The first value stored under a name fixes the type of its
column.
"""
struct MetadataColumns
    columns::Dict{Symbol,Vector}
end

MetadataColumns() = MetadataColumns(Dict{Symbol,Vector}())

"""The metadata of row `row`, without the names it has no value for. A vector value is a copy."""
function Base.getindex(layer::MetadataColumns, row::Integer)::MetadataDict
    return MetadataDict(
        name => (column[row] isa Vector ? copy(column[row]) : column[row])
        for (name, column) in layer.columns
        if row <= length(column) && column[row] !== missing)
end

"""Clear the metadata of row `row`."""
function Base.delete!(layer::MetadataColumns, row::Integer)::MetadataColumns
    for column in values(layer.columns)
        row <= length(column) && (column[row] = missing)
    end
    return layer
end

"""
Replace the metadata of row `row` with `values`. The layer keeps its own copy of a vector value.

Returns whether the stored metadata of the row changed, and the values that were not stored because
their name holds values of another type. Values are compared with `isequal`, so `NaN` equals `NaN`.
"""
function store!(
    layer::MetadataColumns, row::Integer, values::AbstractDict{Symbol},
)::Tuple{Bool,Vector{MetadataConflict}}
    changed = false
    dropped = MetadataConflict[]
    # A name clears when `values` has no value of the column's type for it.
    for (name, column) in layer.columns
        (row > length(column) || column[row] === missing) && continue
        get(values, name, missing) isa nonmissingtype(eltype(column)) && continue
        column[row] = missing
        changed = true
    end
    for (name, value) in values
        value === missing && continue
        column = get!(() -> Vector{Union{Missing,typeof(value)}}(), layer.columns, name)
        expected = nonmissingtype(eltype(column))
        if typeof(value) != expected
            push!(dropped, MetadataConflict(name, expected, typeof(value)))
            continue
        end
        length(column) < row && append!(column, Iterators.repeated(missing, row - length(column)))
        isequal(column[row], value) && continue
        column[row] = value isa Vector ? copy(value) : value
        changed = true
    end
    return changed, dropped
end
