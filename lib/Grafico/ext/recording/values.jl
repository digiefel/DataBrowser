mutable struct ValuePool
    values::Vector{Any}
    indices::Dict{UInt,Vector{Int}}
end
ValuePool() = ValuePool(Any[], Dict{UInt,Vector{Int}}())

freeze(value::Union{Number,Enum,Symbol,AbstractString,Nothing}) = value
freeze(value::AbstractArray) = isbitstype(eltype(value)) ? copy(value) : map(freeze, value)
freeze(value::Makie.Observable) = freeze(value[])
freeze(value::Tuple) = map(freeze, value)
freeze(value::NamedTuple) = map(freeze, value)
freeze(value::AbstractDict) = Dict(key => freeze(item) for (key, item) in value)
freeze(value) = throw(ArgumentError("The native renderer produced an unsupported recorded value $(typeof(value))."))

function same_value(a, b)
    typeof(a) === typeof(b) || return false
    if a isa AbstractDict
        keys(a) == keys(b) || return false
        return all(key -> same_value(a[key], b[key]), keys(a))
    elseif a isa AbstractArray && !isbitstype(eltype(a))
        axes(a) == axes(b) || return false
        return all(same_value(x, y) for (x, y) in zip(a, b))
    elseif a isa Union{Tuple,NamedTuple}
        return all(same_value(x, y) for (x, y) in zip(a, b))
    end
    isequal(a, b)
end

function retain!(pool, value)
    key = hash((typeof(value), value))
    bucket = get!(Vector{Int}, pool.indices, key)
    for index in bucket
        same_value(pool.values[index], value) && return index
    end
    push!(pool.values, freeze(value))
    push!(bucket, length(pool.values))
    length(pool.values)
end
