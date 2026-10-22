"""Draw AlgebraOfGraphics declarations with any loaded Makie backend."""
module DataBrowserPlotsAlgebraOfGraphicsExt

import AlgebraOfGraphics as AoG
using DataBrowserAPI: @timed_dbg
import DataBrowserPlots: figure
using DataBrowserPlots: EntryLabels, Labelled, Statistic, column
using DataBrowserAPI: item_data, metadata
using DataBrowserCore: select

function figure(
    specification::Union{AoG.Layer, AoG.Layers, AoG.ProcessedLayer, AoG.ProcessedLayers},
    args...;
    options...,
)
    return (@timed_dbg "aog_draw" AoG.draw(specification, args...; options...)).figure
end

# The scale of each named role whose categories a label can name.
const ROLE_SCALES = Dict(:color => :Color, :marker => :Marker, :linestyle => :LineStyle,
    :layout => :Layout, :col => :Col, :row => :Row)

# The category a group's value gives in a role: the value after the role's transformation, as in
# `:Chip => uppercase => "chip"`.
category(value, raw) = !(value isa Pair) ? raw :
    last(value) isa Function ? last(value)(raw) :
    last(value) isa Pair && first(last(value)) isa Function ? first(last(value))(raw) : raw

function Base.:*(statistic::Statistic, layer::AoG.Layer)
    layer.transformation isa AoG.Visual ||
        error("A fit is drawn with a visual, such as `contacts * visual(Lines)`")
    attributes = layer.transformation.attributes
    label = get(attributes, :label, nothing)
    # The curve of each group, on the columns of x and y, with the group's value in each role.
    x, y = column.(statistic.positional)
    # A role the plot type cannot show, such as `marker` for `Lines`, is left out of its mapping.
    plottype = layer.transformation.plottype
    shown = hasmethod(AoG.aesthetic_mapping, Tuple{Type{plottype},Int}) ?
        keys(AoG.aesthetic_mapping(plottype, length(statistic.positional))) : keys(Dict(statistic.named))
    roles = [(role, value, column(value)) for (role, value) in statistic.named if role in shown]
    columns = Dict{Symbol,Vector{Any}}(name => Any[] for name in [x; y; [c for (_, _, c) in roles]])
    for group in statistic.groups
        curve = item_data(group)
        append!(columns[x], curve.x)
        append!(columns[y], curve.y)
        for (_, _, c) in unique(r -> r[3], roles)
            append!(columns[c], fill(metadata(group)[c], length(curve.x)))
        end
    end
    table = NamedTuple{Tuple(keys(columns))}(Tuple(identity.(values(columns))))
    mapping = AoG.mapping(statistic.positional...; (role => value for (role, value, _) in roles)...)
    categories = Dict{Symbol,Vector{Pair{Any,Any}}}()
    if label isa EntryLabels
        named = [(role, value, c) for (role, value, c) in roles if haskey(ROLE_SCALES, role)]
        length(unique(r -> r[3], named)) == 1 || error("A label names the legend entry of each group, so " *
            "the groups must come from one column in a role such as `color`")
        texts = label.labels(select(statistic.groups))
        for (role, value, c) in named
            categories[ROLE_SCALES[role]] = [category(value, metadata(group)[c]) => text
                for (group, text) in zip(statistic.groups, texts)]
        end
        layer = AoG.visual(plottype; (k => v for (k, v) in pairs(attributes) if k !== :label)...)
    end
    return Labelled(AoG.data(table) * mapping * layer, categories)
end

# A statistic without a visual is drawn with its own.
labelled(statistic::Statistic) = statistic * AoG.visual(getproperty(AoG.Makie, statistic.plottype))
labelled(plot::Labelled) = plot
labelled(layers::AoG.AbstractAlgebraic) = Labelled(layers, Dict{Symbol,Vector{Pair{Any,Any}}}())

# Several statistics may label one category: their labels join, one on each line.
function Base.:+(a::Union{Labelled,Statistic}, b::Union{Labelled,Statistic,AoG.AbstractAlgebraic})
    a, b = labelled(a), labelled(b)
    categories = copy(a.categories)
    for (scale, pairs) in b.categories
        existing = copy(get(categories, scale, Pair{Any,Any}[]))
        for (key, text) in pairs
            index = findfirst(p -> first(p) == key, existing)
            index === nothing ? push!(existing, key => text) : (existing[index] = key => "$(last(existing[index]))\n$text")
        end
        categories[scale] = existing
    end
    return Labelled(a.layers + b.layers, categories)
end
Base.:+(a::AoG.AbstractAlgebraic, b::Union{Labelled,Statistic}) = labelled(a) + b

figure(statistic::Statistic, args...; options...) = figure(labelled(statistic), args...; options...)
function figure(plot::Labelled, args...; options...)
    isempty(plot.categories) && return figure(plot.layers, args...; options...)
    scales = AoG.scales(; (scale => (; categories=pairs) for (scale, pairs) in plot.categories)...)
    return figure(plot.layers, scales, args...; options...)
end

end
