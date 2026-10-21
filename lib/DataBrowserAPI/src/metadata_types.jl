"""
Typed metadata values stored in the item index and DuckDB cache.

Scalars and homogeneous vectors only (tuples are converted to vectors) — the cache persists these as typed columns.
"""
const MetadataValue = Union{
    Bool, Int64, Float64, String, Symbol, Date, DateTime, Missing,
    Vector{Bool}, Vector{Int64}, Vector{Float64}, Vector{String},
}

"""The typed dict the engine stores for item/collection `metadata`."""
const MetadataDict = Dict{Symbol,MetadataValue}

"""Normalize one value into the supported metadata value union."""
function metadata_value(value)::MetadataValue
    value isa MetadataValue && return value
    value isa Integer && return Int64(value)
    value isa AbstractFloat && return Float64(value)
    value isa AbstractString && return String(value)
    value isa AbstractVector{Bool} && return Vector{Bool}(value)
    value isa AbstractVector{<:Integer} && return Int64.(value)
    value isa AbstractVector{<:AbstractFloat} && return Float64.(value)
    value isa AbstractVector{<:AbstractString} && return String.(value)
    # A tuple such as (1000.0, 1000.0) is stored as a vector of its promoted element type.
    value isa Tuple && return metadata_value([value...])
    throw(ArgumentError(
        "unsupported metadata value of type $(typeof(value)): $(repr(value)); " *
        "metadata must be scalars (Bool/Int64/Float64/String/Symbol/Date/DateTime/Missing) " *
        "or homogeneous Bool/Int64/Float64/String vectors or tuples",
    ))
end

"""
Convert a dictionary, named tuple, pair, or iterable accepted by `Dict` into a
validated [`MetadataDict`](@ref). Keys are converted to symbols; values must be
supported by [`metadata_value`](@ref).
"""
metadata_dict(values)::MetadataDict = metadata_dict(Dict(values))
metadata_dict(values::NamedTuple)::MetadataDict = metadata_dict(pairs(values))
metadata_dict(value::Pair)::MetadataDict = metadata_dict((value,))
metadata_dict(dict::MetadataDict)::MetadataDict = dict
function metadata_dict(dict::AbstractDict)::MetadataDict
    out = MetadataDict()
    for (key, value) in dict
        sym = Symbol(key)
        out[sym] = try
            metadata_value(value)
        catch err
            err isa ArgumentError || rethrow()
            throw(ArgumentError("metadata key :$sym: $(err.msg)"))
        end
    end
    return out
end
