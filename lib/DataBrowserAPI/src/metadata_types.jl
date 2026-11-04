"""
The metadata of an item as a `Dict{Symbol,Any}`, from a dictionary, a named tuple, a pair, or pairs
that `Dict` accepts. Keys become symbols; values stay as they are.
"""
metadata_dict(values)::Dict{Symbol,Any} = metadata_dict(Dict(values))
metadata_dict(values::NamedTuple)::Dict{Symbol,Any} = metadata_dict(pairs(values))
metadata_dict(value::Pair)::Dict{Symbol,Any} = metadata_dict((value,))
metadata_dict(dict::Dict{Symbol,Any})::Dict{Symbol,Any} = dict
metadata_dict(dict::AbstractDict)::Dict{Symbol,Any} =
    Dict{Symbol,Any}(Symbol(key) => value for (key, value) in dict)
