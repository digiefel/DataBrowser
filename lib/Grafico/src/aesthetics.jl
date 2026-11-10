# Automatic aesthetic mapping from Makie plot types and their attributes.

using Dictionaries: dictionary
using Makie: Makie, ABLines, Annotation, Arrows2D, Band, BarPlot, BoxPlot, Contour, CrossBar, Density, ECDFPlot, Errorbars, Heatmap, Hist, HLines, HSpan, Plot, RainClouds, Rangebars, Surface, Violin, VLines, VSpan

function mandatory_attributes(T::Type{<:Plot})
    attrs = Makie.attribute_names(T)
    pairs = Pair{Symbol,Any}[]
    if T <: Union{BarPlot, Rangebars, Errorbars, Hist}
        push!(pairs, :direction => :y)
    elseif T <: Union{Density, Band}
        push!(pairs, :direction => :x)
    elseif T <: Union{Violin, RainClouds, BoxPlot, CrossBar}
        push!(pairs, :orientation => :vertical)
    elseif T === Contour
        push!(pairs, :colormap => [Makie.current_default_theme()[:linecolor][]])
    elseif T === Annotation
        push!(pairs, :labelspace => :relative_pixel)
    end
    return dictionary(pairs)
end

function aesthetic_mapping end

function positional_scientific_types(p::ProcessedLayer)::Vector{ScientificType}
    return map(p.positional) do pos
        if pos isa AbstractArray{<:AbstractArray}
            return scientific_type(eltype(eltype(pos)))
        else
            return scientific_eltype(pos)
        end
    end
end

aesthetic_mapping(p::ProcessedLayer) = aesthetic_mapping(p.plottype, p.attributes, positional_scientific_types(p))

function aesthetic_mapping(plottype, attributes, scitypes::Vector{ScientificType})::AestheticMapping
    mapping = aesthetic_mapping(plottype, scitypes...)
    for (key, value) in pairs(mapping)
        if value isa Pair
            attrkey, dict = value
            if !haskey(attributes, attrkey)
                error("Aesthetic mapping lookup for $plottype failed with key $(repr(key)), could not find $(repr(attrkey)) in plot attributes. Consider adding `mandatory_attributes(::$plottype)` to define a default for $(repr(attrkey)).")
            end
            attrvalue = attributes[attrkey]
            if !haskey(dict, attrvalue)
                error("Aesthetic mapping lookup for $plottype failed with key $(repr(key)), no entry for attribute $(repr(attrkey)) with value $(repr(attrvalue)). Existing variants are $(dict)")
            end
            aes = dict[attrvalue]
            mapping[key] = aes
        end
    end
    return mapping
end

function pointlike_positionals(N::Int)
    1 <= N <= 3 || error("Point-like plot types take 1 to 3 positional arguments, got $N")
    return N == 1 ? [1 => AesY] : N == 2 ? [1 => AesX, 2 => AesY] : [1 => AesX, 2 => AesY, 3 => AesZ]
end

# Named Makie attributes that map to Grafico aesthetics across plot types.
const ATTRIBUTE_AESTHETICS = Pair{Symbol,Any}[
    :color => AesColor,
    :strokecolor => AesColor,
    :textcolor => AesColor,
    :background_color => AesColor,
    :text_color => AesColor,
    :whiskercolor => AesColor,
    :mediancolor => AesColor,
    :stemcolor => AesColor,
    :trunkcolor => AesColor,
    :marker => AesMarker,
    :markersize => AesMarkerSize,
    :linestyle => AesLineStyle,
    :stemlinestyle => AesLineStyle,
    :trunklinestyle => AesLineStyle,
    :linewidth => AesLineWidth,
    :whiskerwidth => AesLineWidth,
    :medianlinewidth => AesLineWidth,
    :trunkwidth => AesLineWidth,
    :stack => AesStack,
    :side => AesViolinSide,
]

function plot_attribute_aesthetics(T::Type{<:Plot})
    T === Surface && return Pair{Any,Any}[]
    attrs = Makie.attribute_names(T)
    pairs = Pair{Any,Any}[attr => aes for (attr, aes) in ATTRIBUTE_AESTHETICS if attr in attrs]
    if T === BarPlot
        push!(pairs,
            :width => (:direction => dictionary([:y => AesDeltaX, :x => AesDeltaY])),
            :dodge => (:direction => dictionary([:y => AesDodgeX, :x => AesDodgeY])),
            :fillto => (:direction => dictionary([:y => AesY, :x => AesX])),
        )
    elseif :dodge in attrs
        if :orientation in attrs
            push!(pairs, :dodge => (:orientation => dictionary([:horizontal => AesDodgeY, :vertical => AesDodgeX])))
        elseif :direction in attrs
            push!(pairs, :dodge => (:direction => dictionary([:y => AesDodgeX, :x => AesDodgeY])))
        else
            push!(pairs, :dodge => AesDodgeX)
        end
    end
    return pairs
end

# Default positional mapping for any Makie plot type: (y), (x, y), or (x, y, z) for Normal data,
# and a geometry placeholder for Geometrical data.
positional_aesthetics(::Type{<:Plot}, args::Normal...) = pointlike_positionals(length(args))
positional_aesthetics(::Type{<:Plot}, ::Geometrical) = [1 => AesPlaceholder]

positional_aesthetics(::Type{BarPlot}, ::Normal) =
    [1 => (:direction => dictionary([:y => AesY, :x => AesX]))]
positional_aesthetics(::Type{BarPlot}, ::Normal, ::Normal) = [
    1 => (:direction => dictionary([:y => AesX, :x => AesY])),
    2 => (:direction => dictionary([:y => AesY, :x => AesX])),
]

positional_aesthetics(::Type{<:Union{Violin, RainClouds, BoxPlot}}, ::Normal, ::Normal) = [
    1 => (:orientation => dictionary([:horizontal => AesY, :vertical => AesX])),
    2 => (:orientation => dictionary([:horizontal => AesX, :vertical => AesY])),
]

positional_aesthetics(::Type{CrossBar}, ::Normal, ::Normal, ::Normal, ::Normal) = [
    1 => (:orientation => dictionary([:horizontal => AesY, :vertical => AesX])),
    2 => (:orientation => dictionary([:horizontal => AesX, :vertical => AesY])),
    3 => (:orientation => dictionary([:horizontal => AesX, :vertical => AesY])),
    4 => (:orientation => dictionary([:horizontal => AesX, :vertical => AesY])),
]

positional_aesthetics(::Type{HLines}, ::Normal) = [1 => AesY]
positional_aesthetics(::Type{VLines}, ::Normal) = [1 => AesX]
positional_aesthetics(::Type{HSpan}, ::Normal, ::Normal) = [1 => AesY, 2 => AesY]
positional_aesthetics(::Type{VSpan}, ::Normal, ::Normal) = [1 => AesX, 2 => AesX]
positional_aesthetics(::Type{Heatmap}, ::Normal, ::Normal, ::Normal) = [1 => AesX, 2 => AesY, 3 => AesColor]

positional_aesthetics(::Type{Rangebars}, ::Normal, ::Normal, ::Normal) = [
    1 => (:direction => dictionary([:x => AesY, :y => AesX])),
    2 => (:direction => dictionary([:x => AesX, :y => AesY])),
    3 => (:direction => dictionary([:x => AesX, :y => AesY])),
]

positional_aesthetics(::Type{Errorbars}, ::Normal, ::Normal, ::Normal) = [
    1 => AesX,
    2 => AesY,
    3 => (:direction => dictionary([:x => AesDeltaX, :y => AesDeltaY])),
]
positional_aesthetics(::Type{Errorbars}, ::Normal, ::Normal, ::Normal, ::Normal) = [
    1 => AesX,
    2 => AesY,
    3 => (:direction => dictionary([:x => AesDeltaX, :y => AesDeltaY])),
    4 => (:direction => dictionary([:x => AesDeltaX, :y => AesDeltaY])),
]

positional_aesthetics(::Type{Contour}, ::Normal, ::Normal, ::Normal) = [1 => AesX, 2 => AesY, 3 => AesContourColor]
positional_aesthetics(::Type{Arrows2D}, ::Normal, ::Normal, ::Normal, ::Normal) = [1 => AesX, 2 => AesY, 3 => AesDeltaX, 4 => AesDeltaY]
positional_aesthetics(::Type{LongPoly}, ::Normal, ::Normal, ::Union{Normal, Geometrical}, ::Union{Normal, Geometrical}) =
    [1 => AesX, 2 => AesY, 3 => AesPlaceholder, 4 => AesPlaceholder]

positional_aesthetics(::Type{Band}, ::Normal, ::Normal, ::Normal) = [
    1 => (:direction => dictionary([:x => AesX, :y => AesY])),
    2 => (:direction => dictionary([:x => AesY, :y => AesX])),
    3 => (:direction => dictionary([:x => AesY, :y => AesX])),
]

positional_aesthetics(::Type{ABLines}, ::Normal, ::Normal) = [1 => AesABIntercept, 2 => AesABSlope]
positional_aesthetics(::Type{Density}, ::Normal) = [1 => (:direction => dictionary([:x => AesX, :y => AesY]))]
positional_aesthetics(::Type{ECDFPlot}, ::Normal) = [1 => AesX]
positional_aesthetics(::Type{Hist}, ::Normal) = [1 => (:direction => dictionary([:y => AesX, :x => AesY]))]

positional_aesthetics(::Type{Annotation}, ::Normal, ::Normal) = [1 => AesX, 2 => AesY]
positional_aesthetics(::Type{Annotation}, ::Normal, ::Normal, ::Normal, ::Normal) = [
    1 => (:labelspace => dictionary([:data => AesX, :relative_pixel => AesAnnotationOffsetX])),
    2 => (:labelspace => dictionary([:data => AesY, :relative_pixel => AesAnnotationOffsetY])),
    3 => AesX,
    4 => AesY,
]

function aesthetic_mapping(T::Type{<:Plot}, scitypes::ScientificType...)
    return dictionary([positional_aesthetics(T, scitypes...)..., plot_attribute_aesthetics(T)...])
end

aesname(T::Type{<:Aesthetic}) = replace(string(nameof(T)), r"^Aes" => "")

"""
    show_aesthetics(T::Type{<:Makie.Plot})

Print the positional and named aesthetic mappings inferred for Makie plot type `T`.
"""
show_aesthetics(T::Type{<:Makie.Plot}) = show_aesthetics(stdout, T)

function show_aesthetics(io::IO, T::Type{<:Makie.Plot})
    println(io, "Aesthetic mappings for `$(Makie.plotsym(T))` (attributes from `Makie.attribute_names($T)`):")
    for nargs in 1:3
        scitypes = ntuple(_ -> Continuous(), nargs)
        dict = try
            aesthetic_mapping(T, scitypes...)
        catch
            continue
        end
        println(io)
        printstyled(io, "With $nargs positional argument$(nargs == 1 ? "" : "s"):\n"; bold=true)
        for (key, value) in pairs(dict)
            if value isa Pair
                println(io, " - ", key, " depends on ", value[1], ": ",
                    join(("$k → $(aesname(v))" for (k, v) in pairs(value[2])), ", "))
            else
                println(io, " - ", key, " → ", aesname(value))
            end
        end
    end
    return nothing
end
