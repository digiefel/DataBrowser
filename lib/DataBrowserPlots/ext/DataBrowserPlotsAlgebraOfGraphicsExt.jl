"""Draw AlgebraOfGraphics declarations with any loaded Makie backend."""
module DataBrowserPlotsAlgebraOfGraphicsExt

import AlgebraOfGraphics as AoG
using AlgebraOfGraphics: data, mapping, visual
using .AoG.Makie: Scatter, Lines
using DataBrowserAPI: @timed_dbg
import DataBrowserPlots: figure, inherit, mappings, over_result, resolve
using DataBrowserPlots: @plot, Aggregate, Fit, LegendEntry, PlotLine, PlotLines, PlotTheme, Scaled, Result, category, column
using DataBrowserAPI: item_data, metadata
using DataBrowserCore: Group, select
using DataBrowserPlots: Tables
using PrecompileTools: @setup_workload, @compile_workload

# The legend is ours, not AoG's: roles share a section when one determines the others
# (plans/graphics-grammar.md). `texts` are the texts of the entries in the section of a role.
# `groups` are the values of every group's roles, as `key => value`, also of the roles that its
# layer cannot show.
function figure(
    specification::Union{AoG.Layer, AoG.Layers, AoG.ProcessedLayer, AoG.ProcessedLayers},
    args...;
    legend=(;),
    texts::Vector{Pair{Symbol,Function}}=Pair{Symbol,Function}[],
    groups::Vector{Dict{Symbol,Any}}=Dict{Symbol,Any}[],
    options...,
)
    drawn = @timed_dbg "aog_draw" AoG.draw(drawable(specification), args...; legend=(; show=false), options...)
    label_inspector!(drawn.grid)
    get(legend, :show, true) || return drawn.figure
    sections = legend_sections(drawn.grid, texts, get(legend, :merge, nothing), groups)
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

# The text the inspector shows for a point: its x and y under the labels of the axes, then the value
# of each role of its group, such as its color, under the title of the role's scale.
# TODO: the items behind the point, and for an analysis, how many values it took.
# TODO: the values of `group`, `layout`, `row` and `col`, which AlgebraOfGraphics has replaced by
# their places in a scale that the drawn figure lacks.
function label_inspector!(grid)
    for entries in grid
        axis = entries.axis
        axis isa AoG.Makie.Axis || continue
        # AlgebraOfGraphics draws a plot for each group of each layer, in the order of the groups. A
        # plot type that draws all groups in one plot, such as `BarPlot`, has a value for each point.
        for (plot, p) in zip(axis.scene.plots, entries.processedlayers)
            mapping = AoG.aesthetic_mapping(p)
            roles = [(AoG.getlabel(scale), Dict(zip(AoG.datavalues(scale), AoG.datalabels(scale))), value)
                for (key, value) in pairs(p.primary)
                for scale in (get(get(entries.categoricalscales, get(mapping, key, nothing), Dict()), nothing, nothing),)
                if scale !== nothing]
            plot.inspector_label = function (_, index, position)
                lines = ["$(axis.xlabel[]): $(inspected(position[1]))", "$(axis.ylabel[]): $(inspected(position[2]))"]
                for (title, names, value) in roles
                    value isa AbstractVector && (value = value[index])
                    push!(lines, "$title: $(get(names, value, value))")
                end
                return join(lines, "\n")
            end
        end
    end
    return nothing
end

# A number as the inspector shows it: four significant digits, and a power of ten for a very large
# or very small one, such as 1.234×10⁻⁵.
function inspected(value)::String
    value isa Real && isfinite(value) || return string(value)
    value == 0 && return "0"
    power = floor(Int, log10(abs(value)))
    # A whole number shows without its ".0".
    digits(x) = replace(string(round(x; sigdigits=4)), r"\.0$" => "")
    -3 <= power < 4 && return digits(value)
    superscript = map(c -> c == '-' ? '⁻' : "⁰¹²³⁴⁵⁶⁷⁸⁹"[nextind("⁰¹²³⁴⁵⁶⁷⁸⁹", 0, c - '0' + 1)], string(power))
    return "$(digits(value / 10.0^power))×10$superscript"
end

# The processed layers of each line, drawn or not, each with the values of its groups' roles. A
# role the line takes from the header is left out of the layers whose plot type cannot show it, such
# as `markersize` of `Lines`. Its values still divide the line's points into groups, as other roles'
# values do, and stay among the values of the groups for the legend.
function processed_lines(plot::PlotLines, settings::AoG.Scales=AoG.scales())::Vector{Vector{Pair{AoG.ProcessedLayer,Any}}}
    transforms = AoG.axis_transforms_from_scales(settings)
    return map(plot.lines) do line
        map(AoG.ProcessedLayers(drawable(line.layers), transforms).layers) do p
            shown = AoG.aesthetic_mapping(p)
            skipped = [key for key in line.shared if !haskey(shown, key) && AoG.hardcoded_mapping(key) === nothing]
            primary, named, labels = copy(p.primary), copy(p.named), copy(p.labels)
            for key in skipped, values in (primary, named, labels)
                haskey(values, key) && delete!(values, key)
            end
            AoG.ProcessedLayer(p; primary, named, labels) => p.primary
        end
    end
end

function figure(plot::PlotLines, args...; options...)
    settings = !isempty(args) && first(args) isa AoG.Scales ? first(args) : AoG.scales()
    drawn = reduce(vcat, [layers for (line, layers) in zip(plot.lines, processed_lines(plot, settings)) if line.drawn];
        init=Pair{AoG.ProcessedLayer,Any}[])
    # The values of each group's roles, one group for each element of a layer's values.
    groups = [Dict{Symbol,Any}(key => values[i] for (key, values) in pairs(primary))
        for (_, primary) in drawn if !isempty(primary) for i in eachindex(first(values(primary)))]
    return figure(AoG.ProcessedLayers(first.(drawn)), args...; options..., groups)
end

# The named roles each line can show: those of its plot types, and those of the layout.
# TODO: the lines are processed again when drawn; process them once for both.
function mappings(plot::PlotLines)::Vector{Vector{Symbol}}
    layout = [:layout, :row, :col, :group]
    return map(processed_lines(plot)) do layers
        union((Symbol[key for key in keys(AoG.aesthetic_mapping(p)) if key isa Symbol] for (p, _) in layers)..., layout)
    end
end
mappings(plot::Scaled) = mappings(plot.layers)

# The role of an aesthetic, as `mapping` names it: `:linestyle` for `AesLineStyle`.
role(aes) = Symbol(lowercase(replace(string(nameof(aes)), r"^Aes" => "")))

# The pieces of a plot, such as its scatter and its lines: the processed layers of one plot type and
# one set of attributes.
piece(p::AoG.ProcessedLayer) = (p.plottype, p.attributes)

# The legend's sections, each as `(; samples, texts, title)`: the categorical scales' sections, then
# one for each continuous scale, then one for the pieces with their own label. A section without
# entries is left out. `all_groups` are the values of every group's roles, as `figure` takes them.
# TODO: legends of additional scales, such as `color=:Chip => scale(:other)`.
# TODO: plot types that draw all groups in one plot, such as `BarPlot` with `color`, fail here.
function legend_sections(grid, texts::Vector{Pair{Symbol,Function}}, merge, all_groups::Vector{Dict{Symbol,Any}})
    scales(kind) = [aes => scale for (aes, d) in pairs(AoG.legendable_scales(Val(kind),
        kind === :categorical ? first(grid).categoricalscales : first(grid).continuousscales))
        for (id, scale) in pairs(d) if id === nothing]
    categorical, continuous = Dict(scales(:categorical)), scales(:continuous)
    order = first.(scales(:categorical))
    processed = mapreduce(entry -> entry.processedlayers, vcat, grid)
    # Each drawn group: its piece, and the value of each categorical legend role it maps. A role that
    # its piece cannot show, such as `marker` of `Lines`, takes the value of the groups with the same
    # values in the roles the piece shows, when they all have one.
    groups = map(processed) do p
        mapping = AoG.aesthetic_mapping(p)
        values = Dict(mapping[key] => value for (key, value) in pairs(p.primary)
            if haskey(categorical, get(mapping, key, nothing)) && !haskey(p.scale_mapping, key))
        same = filter(g -> all(((key, value),) -> isequal(get(g, key, nothing), value), pairs(p.primary)), all_groups)
        for aes in order
            (haskey(values, aes) || haskey(mapping, role(aes))) && continue
            found = unique(g[role(aes)] for g in same if haskey(g, role(aes)))
            length(found) == 1 && (values[aes] = only(found))
        end
        piece(p) => values
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
    return filter(s -> !isempty(s.texts), sections)
end

# The values of each drawn group in `section`, a vector of aesthetics: one tuple for each distinct
# combination, from the groups that map all of them.
combinations(section, groups) = unique([Tuple(values[aes] for aes in section)
    for (_, values) in groups if all(aes -> haskey(values, aes), section)])

# The aesthetics of each legend section. With `merge = false`, each has its own. Otherwise those
# that `merge` names share one; then sections join while one of their aesthetics determines the
# others: while there are as many combinations of their values as one of them has values.
function section_roles(order, groups, merge)
    merge === false && return [[aes] for aes in order]
    merged = merge === true ? role.(order) : merge === nothing ? Symbol[] : collect(merge)
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
# drawn, in the order of the scales. Its text is `text(entry)`, or the values' names, each name once.
# Its title joins the titles of the scales, each once, without the empty ones.
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
        text === nothing ? join(unique(names[role(aes)][v] for (aes, v) in zip(section, combination)), ", ") :
            # The text was defined by code the browser ran after this drawing started.
            Base.invokelatest(text, entry)
    end
    title = join(filter(!isempty, unique(string(AoG.getlabel(scales[aes])) for aes in section)), ", ")
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
struct WithinLimits
    limits::Vector{Any}
end

function (step::WithinLimits)(p::AoG.ProcessedLayer)
    # The points of each group that are inside the limits.
    inside = map(eachindex(first(p.positional))) do group
        keep = trues(length(first(p.positional)[group]))
        for (position, limits) in enumerate(step.limits)
            (limits === nothing || position > length(p.positional)) && continue
            # A bound of `nothing` is Makie's own, so it removes no points.
            low, high = something(first(limits), -Inf), something(last(limits), Inf)
            keep .&= coalesce.(low .<= p.positional[position][group] .<= high, false)
        end
        keep
    end
    cut(values) = map(eachindex(values)) do group
        points = values[group]
        points isa AbstractVector && length(points) == length(inside[group]) ? points[inside[group]] : points
    end
    return AoG.ProcessedLayer(p; positional=map(cut, p.positional), named=map(cut, p.named))
end

# A step of `coord` that runs after the analyses of a layer and moves its points: `functions` take
# the x and y of a point and give where it is drawn, in order.
# TODO: plot types that draw shapes around their points, such as the cells of a Heatmap, the bars of
# a BarPlot and the lengths of Errorbars, keep their shapes upright.
struct MovedPoints
    functions::Vector{Any}
end

function (step::MovedPoints)(p::AoG.ProcessedLayer)
    length(p.positional) >= 2 || error("coord moves points by their x and y; this layer has one position")
    x, y = copy(p.positional[1]), copy(p.positional[2])
    for group in eachindex(x)
        moved = map(x[group], y[group]) do a, b
            foldl((point, f) -> f(point...), step.functions; init=(a, b))
        end
        x[group], y[group] = first.(moved), last.(moved)
    end
    return AoG.ProcessedLayer(p; positional=[x, y, p.positional[3:end]...])
end

# The layers with `change` applied to their transformation, such as `t -> t ∘ step` to run `step`
# before the analyses, or `t -> step ∘ t` after them.
retransformed(layer::AoG.Layer, change) = AoG.Layer(; transformation=change(layer.transformation), layer.data, layer.positional, layer.named)
retransformed(layers::AoG.Layers, change) = AoG.Layers([retransformed(layer, change) for layer in layers.layers])
retransformed(plot::PlotLines, change) =
    PlotLines([PlotLine(retransformed(drawable(line.layers), change), line.shared, line.drawn) for line in plot.lines])

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
    # The `coord` lines only change where the values are drawn, after the analyses: their functions
    # move the points, then Makie's axis draws their scales, limits and reversed axes, and their
    # limits remove no points.
    # TODO: two scales of one axis, and a function after a scale, composed in the order of the lines.
    # TODO: `polar(angle = :x, turn = 2π, start = 0, clockwise = false, inner = 0)` as a `coord` step.
    #   AlgebraOfGraphics draws only on Axis and Axis3, so we draw its processed layers ourselves on
    #   a Makie PolarAxis: each entry of `AoG.compute_axes_grid` holds a plot type, its positions and
    #   its attributes. The settings map to PolarAxis's: `angle = :y` to `theta_as_x = false`, `start`
    #   to `theta_0`, `clockwise` to `direction = -1`, `inner` to `radius_at_origin`. `turn` is the
    #   angle of one unit of the angle values; `turn = :range` stretches their range over one turn,
    #   as ggplot's coord_polar does. Lines bend along circles only if we add points between theirs
    #   before drawing, as ggplot does: PolarAxis draws a straight line between two points.
    # TODO: shapes that move with a function of the points, such as heatmap cells turned into
    #   diamonds: the function becomes Makie's `transform_func` of the axis (`PointTrans{2}`), which
    #   also needs `Makie.inverse_transform` and `Makie.apply_transform(f, ::Rect3)` for the limits.
    #   Only functions with an inverse can do this, so it is a setting of the line, not the default.
    # TODO: a tilted plot, such as one slanted by 45°: Makie's `rotate!` of the axis scene turns the
    #   drawing, and we draw the slanted grid and ticks that the turned axis lacks.
    zoom = Any[nothing, nothing]
    functions, scaled = Any[], false
    for step in plot.coords, (key, value) in pairs(step)
        if key === :points
            scaled && error("A coord line with a function of the points comes before those that set a scale or reversed")
            push!(functions, value)
        elseif key in (:x, :y)
            extra = setdiff(keys(value), (:label, :scale, :limits, :reversed))
            isempty(extra) || error("coord sets the label, scale, limits and reversed of $key, not $(join(extra, ", "))")
            scaled |= haskey(value, :scale) || haskey(value, :reversed)
            haskey(value, :label) && push!(axis, Symbol(key, :label) => value.label)
            haskey(value, :scale) && push!(axis, Symbol(key, :scale) => value.scale)
            haskey(value, :reversed) && push!(axis, Symbol(key, :reversed) => value.reversed)
            haskey(value, :limits) && (zoom[key === :x ? 1 : 2] = value.limits)
        elseif key === :aspect
            push!(axis, :aspect => value)
        else
            error("coord sets x, y and aspect, not $key")
        end
    end
    shown = [z === nothing ? l : z for (z, l) in zip(zoom, limits)]
    any(!isnothing, shown) && push!(axis, :limits => Tuple(shown))
    settings = AoG.scales(; (ROLE_SCALES[r] => value for (r, value) in scales)...)
    layers = drawable(plot.layers)
    any(!isnothing, limits) && (layers = retransformed(layers, t -> t ∘ WithinLimits(limits)))
    isempty(functions) || (layers = retransformed(layers, t -> MovedPoints(functions) ∘ t))
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

# The function that places a value computed after `scale`, the function of an axis, back on that
# axis, such as `exp10` for `log10`.
function unscaled(scale)
    scale === identity && return identity
    inverse = AoG.Makie.inverse_transform(scale)
    inverse === nothing && error("The scale's function $scale has no inverse, so the values computed after it cannot be drawn")
    return inverse
end

function Base.:*(result::Result, layer::AoG.Layer)
    layer.transformation isa AoG.Visual ||
        error("A result is drawn with a visual, such as `contacts * visual(Lines)`")
    # The data of each group, its first column as x and its second as y, with the group's value in
    # each role. An aggregate of several functions has a column for each; a line draws them by
    # mapping them, as in `mapping(y = spread.mean)`.
    plottype = layer.transformation.plottype
    data = item_data(first(getfield(result, :groups)))
    length(data) == 2 || error("A result with the values $(join(keys(data)[2:end], ", ")) is drawn by mapping " *
        "the one to draw, as in `mapping(y = spread.$(keys(data)[2]))` for a result named `spread`")
    positional = getfield(result, :positional)
    # A role the plot type cannot show, such as `marker` for `Lines`, is left out of its mapping.
    shown = hasmethod(AoG.aesthetic_mapping, Tuple{Type{plottype},Int}) ?
        keys(AoG.aesthetic_mapping(plottype, length(positional))) : keys(Dict(getfield(result, :named)))
    roles = [(role, value, column(value)) for (role, value) in getfield(result, :named) if role in shown]
    drawn = column.(positional)
    columns = Dict{Symbol,Vector{Any}}(name => Any[] for name in [drawn; [c for (_, _, c) in roles]])
    # A value computed after the y scale's function, such as an aggregate's `mean`, is placed back.
    y = keys(data)[2] in getfield(result, :scaled) ? unscaled(getfield(result, :scale)) : identity
    for group in getfield(result, :groups)
        values = item_data(group)
        for (name, value) in zip(drawn, values)
            append!(columns[name], name === drawn[2] ? y.(value) : value)
        end
        for (_, _, c) in unique(r -> r[3], roles)
            append!(columns[c], fill(metadata(group)[c], length(first(values))))
        end
    end
    table = NamedTuple{Tuple(keys(columns))}(Tuple(identity.(values(columns))))
    mapping = AoG.mapping(positional...; (role => value for (role, value, _) in roles)...)
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
inherit(header::AoG.Layer, line::Union{Fit,Aggregate}) = inherit(header, AoG.transformation(line))
inherit(header::AoG.Layer, line::Result) = drawable(line)

# A fit or an aggregate is a step of a layer, as AoG's analyses are: `mapping(...) * fit(...) *
# visual(Lines)`.
Base.:*(layer::AoG.AbstractAlgebraic, step::Union{Fit,Aggregate}) = layer * AoG.transformation(step)
Base.:*(step::Union{Fit,Aggregate}, layer::AoG.AbstractAlgebraic) = AoG.transformation(step) * layer

# The steps of a layer's transformation, in the order they apply.
steps(transformation::ComposedFunction) = [steps(transformation.inner); steps(transformation.outer)]
steps(transformation) = transformation === identity ? Any[] : Any[transformation]

# A layer whose first step is a fit or an aggregate: its result over the layer's points, drawn by the
# steps after it. `items` are the items whose ids the points' table holds. The result takes the
# points inside the limits of the x and y scales in `axes`, and the function of the y scale, such as
# `log10`. A layer with several values of y draws them as one y. Other layers stay as they are.
function resolve(layer::AoG.Layer, items, axes)
    if layer.data isa AoG.Columns
        named = Pair{Symbol,Any}[role => value for (role, value) in pairs(layer.named)]
        table, positional, named = one_y(layer.data.columns, layer.positional, named)
        stacked = AoG.mapping(positional...; named...)
        layer = AoG.Layer(layer.transformation, AoG.Columns(table), stacked.positional, stacked.named)
    end
    found = steps(layer.transformation)
    computes(step) = step isa Union{Fit,Aggregate}
    any(computes, found) || return layer
    computes(first(found)) && count(computes, found) == 1 ||
        error("A fit or an aggregate takes the points of its line before any visual, as in `fit(...) * visual(Lines)`")
    layer.data isa AoG.Columns || error("A fit or an aggregate needs points: a mapping of x and y, such as mapping(:x, :y)")
    named = Pair{Symbol,Any}[role => value for (role, value) in pairs(layer.named)]
    setting(r, key, default) = get(get(axes, r, (;)), key, default)
    columns = Tables.columntable(layer.data.columns)
    inside = trues(length(first(columns)))
    for (position, r) in enumerate((:x, :y))
        limits = setting(r, :limits, nothing)
        (limits === nothing || position > length(layer.positional)) && continue
        # A bound of `nothing` is Makie's own, so it removes no points.
        low, high = something(first(limits), -Inf), something(last(limits), Inf)
        value = layer.positional[position]
        inside .&= [v isa Real && low <= v <= high for v in category.(Ref(value), columns[column(value)])]
    end
    table = map(values -> values[inside], columns)
    result = Result(first(found), table, layer.positional, named, items; scale=setting(:y, :scale, identity))
    after = found[2:end]
    return isempty(after) ? result : result * AoG.Layer(; transformation=foldl(AoG.:⨟, after))
end
# The points of a layer with several values of y, as `y` and `y2` give, as points of one y: a row
# for each point and each value, with the value in the column `y` and its title in the column
# `ydims`, which the roles that `ydims()` maps take, in the order of the values and without a title
# in the legend. A layer with one y stays as it is.
# TODO: a column of the data named `y` or `ydims`.
function one_y(table, positional::Vector, named::Vector)
    length(positional) == 2 && positional[2] isa AbstractVector || return table, positional, named
    columns = Tables.columntable(table)
    ys = positional[2]
    # The title after `=>`, as in `:I => "V > 0"` and `:I => abs => "V < 0"`, or the column's name.
    title(value) = !(value isa Pair) ? string(column(value)) : last(value) isa AbstractString ? last(value) :
        last(value) isa Pair && last(last(value)) isa AbstractString ? last(last(value)) : string(column(value))
    repeated = [name => reduce(vcat, [columns[name] for _ in ys]) for name in keys(columns)]
    count = length(first(columns))
    # Each value after its transformation, as in `:I => abs => "V < 0"`.
    stacked = (; repeated..., y=reduce(vcat, [category.(Ref(v), columns[column(v)]) for v in ys]),
        ydims=reduce(vcat, [fill(title(v), count) for v in ys]))
    order = AoG.sorter(unique(title.(ys))...)
    named = [role => (column(value) isa AoG.DimsSelector ? :ydims => order => "" : value) for (role, value) in named]
    # TODO: a label of y from the values' own labels.
    return stacked, [positional[1], :y => ""], named
end
resolve(layers::AoG.Layers, items, axes) = foldl(+, (resolve(layer, items, axes) for layer in layers.layers))

# A line that reads the values of a result, drawn over its groups: `table` holds the values the
# line's mapping reads, one row for each group, and the line takes the roles of the result's points,
# such as `color`, so that it shares their legend entries. A line with `y` and no `x` takes the x of
# the result's points, as `mapping(y = spread.mean)`.
function over_result(result::Result, table, layer)
    named = getfield(result, :named)
    groups = getfield(result, :groups)
    roles = [column(value) => [metadata(group)[column(value)] for group in groups] for (_, value) in named]
    x = first(getfield(result, :positional))
    xs = haskey(table, column(x)) ? [] : [column(x) => [metadata(group)[column(x)] for group in groups]]
    with_x(l) = first(l.positional, 1) == [nothing] ? AoG.Layer(l.transformation, l.data, [x; l.positional[2:end]], l.named) : l
    # The values computed after the y scale's function, such as an aggregate's `mean` and `std`,
    # are placed back on the axis by what the visual draws with them: a y value is a position, and
    # the third value of `Errorbars` a length on each side of y, drawn as the distances to the ends.
    # A value read by index, as `spread.extrema[1]`, is one too; a value the line computes itself, as
    # `10^spread.mean`, is drawn as it is.
    scale = getfield(result, :scale)
    # The column of `spread.extrema[1]` is named `(:extrema)[1]`.
    is_computed(name) = any(n -> occursin(Regex("^\\(?:?\\Q$n\\E\\)?(\\[.*\\])?\$"), string(name)), getfield(result, :scaled))
    back = unscaled(scale)
    placed = Dict{Symbol,Any}()
    function on_axis(l)
        bars = any(v -> v isa AoG.Visual && v.plottype <: AoG.Makie.Errorbars, steps(l.transformation))
        positions = map(collect(enumerate(l.positional))) do (index, value)
            (value === nothing || !is_computed(column(value))) && return [value]
            index == 1 && error("$(column(value)) is computed after the scale of y, so it is drawn on y")
            name, label = column(value), value isa Pair ? last(value) : string(column(value))
            if bars && index >= 3
                center = column(l.positional[2])
                m = is_computed(center) ? table[center] : scaled.(scale, table[center])
                low, high = Symbol(name, "#low"), Symbol(name, "#high")
                placed[low] = back.(m) .- back.(m .- table[name])
                placed[high] = back.(m .+ table[name]) .- back.(m)
                return [low => label, high => label]
            end
            placed[Symbol(name, "#placed")] = back.(table[name])
            return [Symbol(name, "#placed") => label]
        end
        return AoG.Layer(l.transformation, l.data, reduce(vcat, positions; init=Any[]), l.named)
    end
    layer = layer isa AoG.Layers ? AoG.Layers(map(on_axis ∘ with_x, layer.layers)) : on_axis(with_x(layer))
    return AoG.data((; pairs(table)..., roles..., xs..., pairs(placed)...)) * AoG.mapping(; named...) * layer
end

# A result without a visual is drawn with its own.
drawable(result::Result) = result * AoG.visual(getproperty(AoG.Makie, getfield(result, :plottype)))
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

Base.:+(a::Result, b::Union{Result,AoG.AbstractAlgebraic}) = drawable(a) + drawable(b)
Base.:+(a::AoG.AbstractAlgebraic, b::Result) = a + drawable(b)

figure(result::Result, args...; options...) = figure(drawable(result), args...; options...)

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
