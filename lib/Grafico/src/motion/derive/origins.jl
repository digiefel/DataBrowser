# Ordinary tables and array views retain observation origins while a derivation
# is prepared. Numerical analyses and native rendering continue to use Grafico.
module _ObservationLineage
import ..Grafico
import ..Grafico.Tables as Tables
using ..Grafico: Layer, Layers

struct Origin
    root::Int
    index::Int
end

mutable struct Context
    roots::IdDict{Any,Int}
    dataset_ids::IdDict{Any,Int}
    datasets::Vector{Any}
    analyses::Vector{Any}
end
Context() = Context(IdDict{Any,Int}(), IdDict{Any,Int}(), Any[], Any[])

struct OriginArray{T,A<:AbstractVector{T},O,R} <: AbstractVector{T}
    values::A
    origins::O
    rows::R
    dataset::Int
end
OriginArray(values, origins; rows = collect(eachindex(values)), dataset = 0) =
    OriginArray(values, origins, rows, dataset)
Base.size(a::OriginArray) = size(a.values)
Base.axes(a::OriginArray) = axes(a.values)
Base.IndexStyle(::Type{<:OriginArray}) = IndexLinear()
Base.getindex(a::OriginArray, i::Int) = a.values[i]
Base.getindex(a::OriginArray, indices::AbstractVector) =
    OriginArray(a.values[indices], a.origins[indices]; rows = a.rows[indices], a.dataset)
Base.getindex(a::OriginArray, ::Colon) =
    OriginArray(copy(a.values), copy(a.origins); rows = copy(a.rows), a.dataset)
Base.view(a::OriginArray, indices...) =
    OriginArray(view(a.values, indices...), view(a.origins, indices...);
                rows = view(a.rows, indices...), a.dataset)
Base.vcat(a::OriginArray, b::OriginArray) = begin
    a.dataset == b.dataset || throw(ArgumentError("A derivation needs distinct input datasets to remain distinct."))
    OriginArray(vcat(a.values, b.values), vcat(a.origins, b.origins);
                rows = vcat(a.rows, b.rows), a.dataset)
end

plain(a) = a
plain(a::OriginArray) = a.values
row_origins(a, i) = ()
row_origins(a::OriginArray, i) = a.origins[i]

function origin_array(context, array::AbstractVector)
    if array isa SubArray
        parent = origin_array(context, Base.parent(array))
        return OriginArray(array, parent.origins[only(parentindices(array))])
    end
    root = get!(context.roots, array) do
        length(context.roots) + 1
    end
    OriginArray(array, [(Origin(root, i),) for i in eachindex(array)])
end

function Base.map(f, first::OriginArray, others::AbstractVector...)
    arrays = (first, others...)
    values = map(f, plain.(arrays)...)
    origins = [Tuple(unique(collect(Iterators.flatten(row_origins(a, i) for a in arrays))))
               for i in eachindex(values)]
    OriginArray(values, origins; rows = first.rows, first.dataset)
end
Base.Broadcast.broadcasted(f, a::OriginArray) =
    OriginArray(f.(a.values), a.origins; a.rows, a.dataset)
Grafico._narrow_nonmissing(a::OriginArray) =
    OriginArray(Grafico._narrow_nonmissing(a.values), a.origins; a.rows, a.dataset)
Grafico._entry_argument(a::OriginArray) = a.values

# An analysis output carries its actual membership alongside the numeric
# columns. This survives grouping and scale processing until Entry creation.
struct AnalysisArray{T,N,A<:AbstractArray{T,N}} <: AbstractArray{T,N}
    values::A
    analysis::Any
end
Base.size(a::AnalysisArray) = size(a.values)
Base.axes(a::AnalysisArray) = axes(a.values)
Base.IndexStyle(::Type{<:AnalysisArray{T,N,A}}) where {T,N,A} = Base.IndexStyle(A)
Base.getindex(a::AnalysisArray, i::Int) = a.values[i]
Base.getindex(a::AnalysisArray, i::CartesianIndex) = a.values[i]
Base.getindex(a::AnalysisArray, indices::AbstractVector) = AnalysisArray(a.values[indices], a.analysis)
Base.view(a::AnalysisArray, indices...) = AnalysisArray(view(a.values, indices...), a.analysis)
Base.map(f, a::AnalysisArray) = AnalysisArray(map(f, a.values), a.analysis)
function Base.map(f, a::AnalysisArray, b::AnalysisArray)
    a.analysis === b.analysis || throw(ArgumentError("A coordinate transform combines unrelated analysis outputs."))
    AnalysisArray(map(f, a.values, b.values), a.analysis)
end
Base.Broadcast.broadcasted(f, a::AnalysisArray) = AnalysisArray(f.(a.values), a.analysis)
plain(a::AnalysisArray) = a.values
Grafico._entry_argument(a::AnalysisArray) = a.values

struct AnalysisParts
    parts::Vector{Tuple{Any,UnitRange{Int}}}
end
analysis_parts(a::AnalysisArray) = a.analysis isa AnalysisParts ? a.analysis.parts :
    [(a.analysis, 1:length(a))]
function Grafico._concat_data_from(initial::AnalysisArray, arrays)
    parts = Tuple{Any,UnitRange{Int}}[]
    offset = 0
    for array in arrays
        array isa AnalysisArray || throw(ArgumentError("A derived analysis cannot merge with an untracked result."))
        for (record, indices) in analysis_parts(array)
            push!(parts, (record, (first(indices)+offset):(last(indices)+offset)))
        end
        offset += length(array)
    end
    AnalysisArray(reduce(vcat, map(plain, arrays)), AnalysisParts(parts))
end
Grafico._concat_data_from(first::OriginArray, arrays) = foldl(vcat, arrays)

struct OriginColumns{T} <: Tables.AbstractColumns
    columns::T
    context::Context
    dataset::Int
end
function OriginColumns(columns, context)
    dataset = get!(context.dataset_ids, columns) do
        push!(context.datasets, columns)
        length(context.datasets)
    end
    OriginColumns(columns, context, dataset)
end
Tables.columnnames(table::OriginColumns) = Tables.columnnames(getfield(table, :columns))
Tables.schema(table::OriginColumns) = Tables.schema(getfield(table, :columns))
function Tables.getcolumn(table::OriginColumns, name::Symbol)
    values = Tables.getcolumn(getfield(table, :columns), name)
    Grafico.scientific_eltype(values) === Grafico.categorical && return values
    traced = origin_array(getfield(table, :context), values)
    OriginArray(traced.values, traced.origins; dataset = getfield(table, :dataset))
end
Tables.getcolumn(table::OriginColumns, index::Int) = Tables.getcolumn(table, Tables.columnnames(table)[index])

mutable struct HistogramRecord
    operation::Any
    histogram::Any
    parents::Any
    membership::Any
    weights::Any
    rows::Any
    dataset::Int
    direction::Symbol
end

struct HistogramOrigins{H}
    analysis::H
    context::Context
end
function (operation::HistogramOrigins)(input)
    h = operation.analysis
    output = h(input)
    dimensions = length(input.positional)
    dimensions == 1 || throw(ArgumentError("Observation derivation currently retains one-dimensional histogram membership; use an explicit animation for higher-dimensional statistics."))
    transforms = ntuple(i -> Grafico.position_transform(input.axis_transforms, output.plottype,
        output.attributes, dimensions + 1, i), dimensions)
    limits = h.datalimits === Grafico.automatic ?
        Grafico._transformation_datalimits(input.positional, transforms) :
        Grafico.forward_datalimits(Grafico._strip_datalimits_units(h.datalimits), transforms)
    records = HistogramRecord[]
    Grafico._map_processed(input, limits) do positional, named, group_limits
        positional, named = Grafico._drop_missing_nan_rows(positional, named)
        numerical = ntuple(i -> Grafico.to_transformed_numerical(positional[i], transforms[i]), dimensions)
        options = Grafico.valid_options(; h.bins, h.closed, h.normalization)
        histogram = Grafico._histogram(Tuple(plain.(numerical));
            (key => plain(value) for (key, value) in pairs(named))...,
            options..., datalimits = group_limits)
        parents = [Tuple(unique(collect(Iterators.flatten(row_origins(column, i) for column in positional))))
                   for i in eachindex(first(positional))]
        membership = [Grafico.StatsBase.binindex(histogram, value) for value in only(numerical)]
        weights = plain(get(named, :weights, ones(length(parents))))
        direction = get(output.attributes, :direction, :y)
        record = HistogramRecord(h, histogram, parents, membership, weights,
            first(positional).rows, first(positional).dataset, direction)
        push!(records, record)
        push!(operation.context.analyses, record)
        positional, named
    end
    positional = map(output.positional) do groups
        wrapped = similar(groups, Any)
        for (index, position) in enumerate(CartesianIndices(groups))
            wrapped[position] = AnalysisArray(groups[position], records[index])
        end
        wrapped
    end
    Grafico.ProcessedLayer(output; positional)
end

tracked(f, context) = f
tracked(f::Grafico.HistogramAnalysis, context) = HistogramOrigins(f, context)
tracked(f::ComposedFunction, context) = tracked(f.outer, context) ∘ tracked(f.inner, context)
function track(layer::Layer, context)
    columns = layer.data isa Grafico.Columns ?
        Grafico.Columns(OriginColumns(layer.data.columns, context)) : layer.data
    Layer(; data = columns, transformation = tracked(layer.transformation, context),
          layer.positional, layer.named)
end
track(layers::Layers, context) = Layers([track(layer, context) for layer in layers.layers])
track(plot::Grafico.Scaled, context) = Grafico.Scaled(track(plot.layers, context),
    plot.scales, plot.texts, plot.legend, plot.theme, plot.coords)
track(plot::Grafico.PlotLines, context) = Grafico.PlotLines([
    Grafico.PlotLine(track(line.layers, context), line.shared, line.drawn) for line in plot.lines])

end
