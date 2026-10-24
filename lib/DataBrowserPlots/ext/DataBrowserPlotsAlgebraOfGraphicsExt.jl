"""Draw AlgebraOfGraphics declarations with any loaded Makie backend."""
module DataBrowserPlotsAlgebraOfGraphicsExt

import AlgebraOfGraphics as AoG
using AlgebraOfGraphics: data, mapping, visual
using .AoG.Makie: Scatter, Lines
using DataBrowserAPI: @timed_dbg
import DataBrowserPlots: figure, inherit, mappings, resolve
using DataBrowserPlots: @plot, Fit, LegendEntry, PlotLine, PlotLines, PlotTheme, Scaled, Statistic, column, fit_statistic
using DataBrowserAPI: item_data, metadata
using DataBrowserCore: Group, select
using PrecompileTools: @setup_workload, @compile_workload

# The legend is ours, not AoG's: roles share a section when one determines the others
# (plans/graphics-grammar.md). `texts` are the texts of the entries in the section of a role.
function figure(
    specification::Union{AoG.Layer, AoG.Layers, AoG.ProcessedLayer, AoG.ProcessedLayers},
    args...;
    legend=(;),
    texts::Vector{Pair{Symbol,Function}}=Pair{Symbol,Function}[],
    options...,
)
    drawn = @timed_dbg "aog_draw" AoG.draw(drawable(specification), args...; legend=(; show=false), options...)
    get(legend, :show, true) || return drawn.figure
    sections = legend_sections(drawn.grid, texts, get(legend, :merge, false))
    isempty(sections) && return drawn.figure
    position = get(legend, :position, :right)
    settings = (k => v for (k, v) in pairs(legend) if k ∉ (:show, :position, :merge))
    # Makie keeps a row for an empty title, and shows the titles of sections despite `titlevisible`;
    # only a title of `nothing` takes no room.
    shown = get(legend, :titlevisible, true)
    titles = [shown && !isempty(something(s.title, "")) ? s.title : nothing for s in sections]
    AoG.Makie.Legend(AoG.guides_position(drawn.figure, position), [s.samples for s in sections],
        [s.texts for s in sections], titles; orientation=AoG.default_orientation(position), settings...)
    return drawn.figure
end

# The processed layers of each line, drawn or not. A role the line takes from the header is left
# out of the layers whose plot type cannot show it, such as `markersize` of `Lines`. Its values still
# divide the line's points into groups, as other roles' values do.
function processed_lines(plot::PlotLines, settings::AoG.Scales=AoG.scales())::Vector{Vector{AoG.ProcessedLayer}}
    transforms = AoG.axis_transforms_from_scales(settings)
    return map(plot.lines) do line
        map(AoG.ProcessedLayers(drawable(line.layers), transforms).layers) do p
            shown = AoG.aesthetic_mapping(p)
            skipped = [key for key in line.shared if !haskey(shown, key) && AoG.hardcoded_mapping(key) === nothing]
            primary, named, labels = copy(p.primary), copy(p.named), copy(p.labels)
            for key in skipped, values in (primary, named, labels)
                haskey(values, key) && delete!(values, key)
            end
            AoG.ProcessedLayer(p; primary, named, labels)
        end
    end
end

function figure(plot::PlotLines, args...; options...)
    settings = !isempty(args) && first(args) isa AoG.Scales ? first(args) : AoG.scales()
    drawn = [layers for (line, layers) in zip(plot.lines, processed_lines(plot, settings)) if line.drawn]
    return figure(AoG.ProcessedLayers(reduce(vcat, drawn; init=AoG.ProcessedLayer[])), args...; options...)
end

# The named roles each line can show: those of its plot types, and those of the layout.
# TODO: the lines are processed again when drawn; process them once for both.
function mappings(plot::PlotLines)::Vector{Vector{Symbol}}
    layout = [:layout, :row, :col, :group]
    return map(processed_lines(plot)) do layers
        union((Symbol[key for key in keys(AoG.aesthetic_mapping(p)) if key isa Symbol] for p in layers)..., layout)
    end
end
mappings(plot::Scaled) = mappings(plot.layers)

# The role of an aesthetic, as `mapping` names it: `:linestyle` for `AesLineStyle`.
role(aes) = Symbol(lowercase(replace(string(nameof(aes)), r"^Aes" => "")))

# The pieces of a plot, such as its scatter and its lines: the processed layers of one plot type and
# one set of attributes.
piece(p::AoG.ProcessedLayer) = (p.plottype, p.attributes)

# The legend's sections, each as `(; samples, texts, title)`: the categorical scales' sections, then
# one for each continuous scale, then one for the pieces with their own label.
# TODO: legends of additional scales, such as `color=:Chip => scale(:other)`.
function legend_sections(grid, texts::Vector{Pair{Symbol,Function}}, merge)
    scales(kind) = [aes => scale for (aes, d) in pairs(AoG.legendable_scales(Val(kind),
        kind === :categorical ? first(grid).categoricalscales : first(grid).continuousscales))
        for (id, scale) in pairs(d) if id === nothing]
    categorical, continuous = Dict(scales(:categorical)), scales(:continuous)
    order = first.(scales(:categorical))
    processed = mapreduce(entry -> entry.processedlayers, vcat, grid)
    # Each drawn group: its piece, and the value of each categorical legend role it maps.
    groups = map(processed) do p
        mapping = AoG.aesthetic_mapping(p)
        piece(p) => Dict(mapping[key] => value for (key, value) in pairs(p.primary)
            if haskey(categorical, get(mapping, key, nothing)) && !haskey(p.scale_mapping, key))
    end
    for (r, _) in texts
        r in role.(order) || error("The legend text is given for $r, which no categorical role of the plot maps")
    end
    # Each value's name in its scale, for every role: a text may read a role outside its section.
    names = Dict(role(aes) => Dict{Any,String}(zip(AoG.datavalues(scale), string.(AoG.datalabels(scale))))
        for (aes, scale) in categorical)
    sections = map(section_roles(order, groups, merge)) do section
        given = [text for (r, text) in texts if r in role.(section)]
        length(given) <= 1 || error("The legend texts of $(join(role.(section), " and ")) name one section; give one")
        categorical_section(section, categorical, groups, processed, names, isempty(given) ? nothing : only(given))
    end
    append!(sections, [continuous_section(aes, scale, processed) for (aes, scale) in continuous])
    # A piece with its own `label`, as in `visual(Lines; label="model")`, has an entry of its own.
    labelled = unique(piece, filter(p -> haskey(p.attributes, :label), processed))
    labels = unique(p.attributes[:label] for p in labelled)
    isempty(labels) || push!(sections, (; samples=[reduce(vcat, [AoG._legend_elements(p, AoG.MixedArguments())
        for p in labelled if p.attributes[:label] == label]) for label in labels], texts=labels, title=nothing))
    return sections
end

# The values of each drawn group in `section`, a vector of aesthetics: one tuple for each distinct
# combination, from the groups that map all of them.
combinations(section, groups) = unique([Tuple(values[aes] for aes in section)
    for (_, values) in groups if all(aes -> haskey(values, aes), section)])

# The aesthetics of each legend section. Those that `merge` names share one; then sections join
# while one of their aesthetics determines the others: while there are as many combinations of
# their values as one of them has values.
function section_roles(order, groups, merge)
    merged = merge === true ? role.(order) : merge === false ? Symbol[] : collect(merge)
    for r in merged
        r in role.(order) || error("The legend merges $r, which no categorical role of the plot maps")
    end
    sections = [[aes] for aes in order if !(length(merged) > 1 && role(aes) in merged)]
    length(merged) > 1 && pushfirst!(sections, [aes for aes in order if role(aes) in merged])
    function determined(section)
        found = combinations(section, groups)
        return !isempty(found) && length(found) == maximum(k -> length(unique(getindex.(found, k))), eachindex(section))
    end
    i = 1
    while i <= length(sections)
        j = findfirst(j -> j > i && determined([sections[i]; sections[j]]), eachindex(sections))
        j === nothing ? (i += 1) : (append!(sections[i], sections[j]); deleteat!(sections, j))
    end
    return sections
end

# The section of categorical aesthetics: one entry for each combination of their values that is
# drawn, in the order of the scales. Its text is `text(entry)`, or the values' names.
function categorical_section(section, scales, groups, processed, names, text)
    looks = [Dict(zip(AoG.datavalues(scales[aes]), AoG.plotvalues(scales[aes]))) for aes in section]
    position(k, value) = findfirst(==(value), AoG.datavalues(scales[section[k]]))
    found = sort(combinations(section, groups); by=c -> [position(k, v) for (k, v) in enumerate(c)])
    samples = map(found) do combination
        entry_samples(Dict(aes => looks[k][combination[k]] for (k, aes) in enumerate(section)),
            Dict(zip(section, combination)), processed, groups)
    end
    texts = map(found) do combination
        entry = LegendEntry(Dict(role(aes) => v for (aes, v) in zip(section, combination)), names)
        text === nothing ? join((names[role(aes)][v] for (aes, v) in zip(section, combination)), ", ") :
            # The text was defined by code the browser ran after this drawing started.
            Base.invokelatest(text, entry)
    end
    title = join(unique(string(AoG.getlabel(scales[aes])) for aes in section), ", ")
    return (; samples, texts, title)
end

# The samples of one entry: one from each piece that drew a group with the entry's `values`, drawn
# with the entry's `looks`, as `aesthetic => look`.
function entry_samples(looks, values, processed, groups)
    samples = AoG.LegendElement[]
    for p in unique(piece, processed)
        mapping = AoG.aesthetic_mapping(p)
        attributes = AoG.MixedArguments()
        for key in [collect(keys(p.primary)); collect(keys(p.named))]
            aes = get(mapping, key, nothing)
            haskey(looks, aes) && !haskey(p.scale_mapping, key) && insert!(attributes, key, looks[aes])
        end
        drew = any(groups) do (drawn_by, group)
            drawn_by == piece(p) && all(aes -> !haskey(group, aes) || group[aes] == values[aes], keys(values))
        end
        isempty(attributes) || !drew || append!(samples, AoG._legend_elements(p, attributes))
    end
    return samples
end

# The section of a continuous scale, such as marker sizes: an entry for each of its ticks.
function continuous_section(aes, scale, processed)
    _, looks, labels = AoG.datavalues_plotvalues_datalabels(aes, scale)
    samples = map(looks) do look
        reduce(vcat, map(unique(piece, processed)) do p
            mapping = AoG.aesthetic_mapping(p)
            attributes = AoG.MixedArguments()
            for key in keys(p.named)
                get(mapping, key, nothing) === aes && insert!(attributes, key, look)
            end
            isempty(attributes) ? AoG.LegendElement[] : AoG._legend_elements(p, attributes)
        end)
    end
    return (; samples, texts=string.(labels), title=string(AoG.getlabel(scale)))
end

# The scale of each role that `scales(...)` can set.
const ROLE_SCALES = Dict(:x => :X, :y => :Y, :color => :Color, :marker => :Marker, :linestyle => :LineStyle,
    :markersize => :MarkerSize, :linewidth => :LineWidth, :layout => :Layout, :col => :Col, :row => :Row)

# A step that runs before the analyses of a layer and removes its points outside the limits of x and
# y, as `limits` of their scales does. `limits[i]` are those of position `i`, or `nothing`.
# TODO: positions that a plot type shows on another axis, such as the first of a horizontal BarPlot.
# TODO: the points that a fit line fits; it is fitted before its layer is drawn.
struct WithinLimits
    limits::Vector{Any}
end

function (step::WithinLimits)(p::AoG.ProcessedLayer)
    # The points of each group that are inside the limits.
    inside = map(eachindex(first(p.positional))) do group
        keep = trues(length(first(p.positional)[group]))
        for (position, limits) in enumerate(step.limits)
            (limits === nothing || position > length(p.positional)) && continue
            keep .&= coalesce.(first(limits) .<= p.positional[position][group] .<= last(limits), false)
        end
        keep
    end
    cut(values) = map(eachindex(values)) do group
        points = values[group]
        points isa AbstractVector && length(points) == length(inside[group]) ? points[inside[group]] : points
    end
    return AoG.ProcessedLayer(p; positional=map(cut, p.positional), named=map(cut, p.named))
end

limited(layer::AoG.Layer, step) = AoG.Layer(; transformation=layer.transformation ∘ step, layer.data, layer.positional, layer.named)
limited(layers::AoG.Layers, step) = AoG.Layers([limited(layer, step) for layer in layers.layers])
limited(plot::PlotLines, step) =
    PlotLines([PlotLine(limited(drawable(line.layers), step), line.shared, line.drawn) for line in plot.lines])

function figure(plot::Scaled, args...; options...)
    for (r, _) in plot.scales
        haskey(ROLE_SCALES, r) || error("scales sets the scale of a role such as color; $r is not one")
    end
    # `limits` and `reversed` of x and y are ours: Makie's axis draws them, and the limits also
    # remove the points outside them before the analyses run.
    limits = Any[nothing, nothing]
    axis = Pair{Symbol,Any}[]
    scales = map(plot.scales) do (r, value)
        r in (:x, :y) && value isa NamedTuple || return r => value
        haskey(value, :limits) && (limits[r === :x ? 1 : 2] = value.limits)
        get(value, :reversed, false) && push!(axis, Symbol(r, :reversed) => true)
        return r => Base.structdiff(value, NamedTuple{(:limits, :reversed)})
    end
    any(!isnothing, limits) && push!(axis, :limits => Tuple(limits))
    settings = AoG.scales(; (ROLE_SCALES[r] => value for (r, value) in scales)...)
    layers = any(!isnothing, limits) ? limited(drawable(plot.layers), WithinLimits(limits)) : drawable(plot.layers)
    legend = (; plot.legend..., get(options, :legend, (;))...)
    draw() = figure(layers, settings, args...; options..., axis=(; axis..., get(options, :axis, (;))...),
        texts=plot.texts, legend)
    return plot.theme === nothing ? draw() : AoG.Makie.with_theme(draw, makie_theme(plot.theme))
end

# A theme from elsewhere, such as Makie's own, can also change what the plot shows, such as the bins
# of `Hist`.
# TODO: show that where it matters.
function makie_theme(theme::PlotTheme)::AoG.Makie.Theme
    # Makie fills in its default theme under any theme, so an empty one is the default.
    base = theme.base === nothing ? AoG.Makie.current_default_theme() :
        theme.base === :default ? AoG.Makie.Theme() : getproperty(AoG.Makie, Symbol(:theme_, theme.base))()
    return merge(AoG.Makie.Theme(; pairs(theme.settings)...), base)
end

function Base.:*(statistic::Statistic, layer::AoG.Layer)
    layer.transformation isa AoG.Visual ||
        error("A fit is drawn with a visual, such as `contacts * visual(Lines)`")
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
    return AoG.data(table) * mapping * layer
end

# A line of a plot as a layer of the header: its positions replace the header's, its named roles add
# to the header's or replace them, and a role set to `nothing` is removed. A line with its own data,
# such as a fit's result, keeps its own mapping.
function inherit(header::AoG.Layer, line::AoG.Layer)
    line.data === nothing || return line
    positional = isempty(line.positional) ? header.positional : line.positional
    # A line with `y` and no `x` takes the header's `x`.
    first(positional, 1) == [nothing] && length(header.positional) >= 1 &&
        (positional = [header.positional[1]; positional[2:end]])
    named = filter(!isnothing, merge(header.named, line.named))
    return AoG.Layer(AoG.:⨟(header.transformation, line.transformation), header.data, positional, named)
end
inherit(header::AoG.Layer, line::AoG.Layers) = AoG.Layers([inherit(header, layer) for layer in line.layers])
inherit(header::AoG.Layer, line::Fit) = inherit(header, AoG.transformation(line))
inherit(header::AoG.Layer, line::Statistic) = drawable(line)

# A fit is a step of a layer, as AoG's analyses are: `mapping(...) * fit(...) * visual(Lines)`.
Base.:*(layer::AoG.AbstractAlgebraic, fit::Fit) = layer * AoG.transformation(fit)
Base.:*(fit::Fit, layer::AoG.AbstractAlgebraic) = AoG.transformation(fit) * layer

# The steps of a layer's transformation, in the order they apply.
steps(transformation::ComposedFunction) = [steps(transformation.inner); steps(transformation.outer)]
steps(transformation) = transformation === identity ? Any[] : Any[transformation]

# A layer whose first step is a fit: the fit's result over the layer's points, drawn by the steps
# after it. `items` are the items whose ids the points' table holds. Other layers stay as they are.
function resolve(layer::AoG.Layer, items)
    found = steps(layer.transformation)
    any(step -> step isa Fit, found) || return layer
    first(found) isa Fit && count(step -> step isa Fit, found) == 1 ||
        error("A fit takes the points of its line before any visual, as in `fit(...) * visual(Lines)`")
    layer.data isa AoG.Columns || error("A fit needs points: a mapping of x and y, such as mapping(:x, :y)")
    named = Pair{Symbol,Any}[role => value for (role, value) in pairs(layer.named)]
    statistic = fit_statistic(first(found), layer.data.columns, layer.positional, named, items)
    after = found[2:end]
    return isempty(after) ? statistic : statistic * AoG.Layer(; transformation=foldl(AoG.:⨟, after))
end
resolve(layers::AoG.Layers, items) = foldl(+, (resolve(layer, items) for layer in layers.layers))

# A statistic without a visual is drawn with its own.
drawable(statistic::Statistic) = statistic * AoG.visual(getproperty(AoG.Makie, statistic.plottype))
# A layer with `y` and no `x`, as in `mapping(; y=:gap) * visual(Hist)`, draws its values against
# the vertical axis: a plot type with a `direction` setting, such as `Hist`, `BarPlot` or `Density`,
# turns to it unless a `visual` sets `direction` already, and other plot types draw the values
# against their index.
# TODO: an analysis without a `visual`, such as `histogram()`, does not turn.
function drawable(layer::AoG.Layer)
    first(layer.positional, 1) == [nothing] && length(layer.positional) == 2 || return layer
    visuals = filter(step -> step isa AoG.Visual, steps(layer.transformation))
    turns = any(v -> :direction in AoG.Makie.attribute_names(v.plottype), visuals) &&
        !any(v -> haskey(v.attributes, :direction), visuals)
    layer = AoG.Layer(layer.transformation, layer.data, layer.positional[2:2], layer.named)
    return turns ? layer * AoG.visual(; direction=:x) : layer
end
drawable(layers::AoG.Layers) = AoG.Layers(map(drawable, layers.layers))
drawable(layers) = layers

Base.:+(a::Statistic, b::Union{Statistic,AoG.AbstractAlgebraic}) = drawable(a) + drawable(b)
Base.:+(a::AoG.AbstractAlgebraic, b::Statistic) = a + drawable(b)

figure(statistic::Statistic, args...; options...) = figure(drawable(statistic), args...; options...)

_precompile_line(x; offset, slope) = offset + slope * x

@setup_workload begin
    rows = [(x=x, y=2x + offset, chip=chip)
        for (chip, offset) in (("A", 1.0), ("B", 3.0)) for x in (1.0, 2.0, 3.0)]
    items = select([Group("$chip$x", Dict{Symbol,Any}(:chip => chip, :x => x), (y=[2x + offset],), [])
        for (chip, offset) in (("A", 1.0), ("B", 3.0)) for x in (1.0, 2.0, 3.0)])
    @compile_workload begin
        # Build figures without a window, so this also runs without a graphics backend.
        ordinary = @plot data(rows) * mapping(:x, :y; color=:chip) begin
            visual(Scatter)
            visual(Lines)
            legend(color = "chip $(:chip)")
        end
        figure(ordinary)
        fitted_plot = @plot mapping(:x, only(:data.y); color=:chip) begin
            visual(Scatter)
            fitted = fit(_precompile_line, (offset=0.0, slope=1.0))
            fitted * visual(Lines)
            legend(color = "$(:chip): $(fitted.offset)")
        end
        figure(fitted_plot, items)
    end
end

end
