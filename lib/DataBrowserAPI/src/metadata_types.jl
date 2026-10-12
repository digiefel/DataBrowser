"""
Typed metadata values stored in the item index and DuckDB cache.

Scalars and homogeneous vectors only — the cache persists these as typed columns.
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
    throw(ArgumentError(
        "unsupported metadata value of type $(typeof(value)): $(repr(value)); " *
        "metadata must be scalars (Bool/Int64/Float64/String/Symbol/Date/DateTime/Missing) " *
        "or homogeneous Bool/Int64/Float64/String vectors",
    ))
end

"""Convert a symbol-keyed dictionary into a validated [`MetadataDict`](@ref)."""
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
