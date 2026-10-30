"""Draw AlgebraOfGraphics declarations with any loaded Makie backend."""
module DataBrowserPlotsAlgebraOfGraphicsExt

import AlgebraOfGraphics as AoG
using AlgebraOfGraphics: data, mapping, visual
using .AoG.Makie: Scatter, Lines
using DataBrowserAPI: @timed_dbg
import DataBrowserPlots: figure, inherit, mappings, over_result, resolve, scale_categories, scale_kinds
using DataBrowserPlots: YScaleLayers, is_y_scale, @plot, Aggregate, Declaration, Fit, ITEM, LegendEntry, PlotLine, PlotLines, PlotTheme, Points, Scaled, Result, category, column, grouping
import DataBrowserAPI
using DataBrowserAPI: id, item_data, metadata
import DataBrowserCore.Workspace
import DataBrowserPlots
using DataBrowserCore: Group, Selection, select
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

function figure(plot::PlotLines, args...; yscales=Dict{Symbol,Any}(), options...)
    any(line -> line.drawn && line.layers isa YScaleLayers, plot.lines) &&
        return scaled_y_figure(plot, yscales, args...; options...)
    settings = !isempty(args) && first(args) isa AoG.Scales ? first(args) : AoG.scales()
    drawn = reduce(vcat, [layers for (line, layers) in zip(plot.lines, processed_lines(plot, settings)) if line.drawn];
        init=Pair{AoG.ProcessedLayer,Any}[])
    # The values of each group's roles, one group for each element of a layer's values.
    groups = [Dict{Symbol,Any}(key => values[i] for (key, values) in pairs(primary))
        for (_, primary) in drawn if !isempty(primary) for i in eachindex(first(values(primary)))]
    return figure(AoG.ProcessedLayers(first.(drawn)), args...; options..., groups)
end

function scaled_y_figure(plot::PlotLines, yscales, args...; legend=(;), texts=Pair{Symbol,Function}[], axis=(;), options...)
    settings = !isempty(args) && first(args) isa AoG.Scales ? first(args) : AoG.scales()
    primarysettings = get(yscales, :y, (;))
    groups = Dict{Symbol,Vector{PlotLine}}(:y => PlotLine[])
    roles = Symbol[:y]
    for line in plot.lines
        line.drawn || continue
        parts = line.layers isa YScaleLayers ? line.layers.layers : [:y => line.layers]
        for (role, layer) in parts
            role in roles || push!(roles, role)
            push!(get!(Vector{PlotLine}, groups, role), PlotLine(layer, line.shared, true))
        end
    end
    config(role) = get(yscales, role, primarysettings)
    scale_settings(role, shared=settings.dict) = AoG.scales(;
        (key => value for (key, value) in pairs(shared) if key !== :Y)...,
        Y=Base.structdiff(config(role), NamedTuple{(:limits, :reversed, :position)}))
    processed = Dict(role => processed_lines(PlotLines(groups[role]), scale_settings(role)) for role in roles)
    shared = Dict{Symbol,Any}(pairs(settings.dict))
    for role in DataBrowserPlots.LEGEND_ROLES
        categories = Any[value for ps in values(processed) for pieces in ps for (p, _) in pieces
            if haskey(p.primary, role) for value in p.primary[role]]
        isempty(categories) && continue
        key = ROLE_SCALES[role]
        scale_options = get(shared, key, (;))
        haskey(scale_options, :categories) && continue
        categories = try sort(unique(categories)) catch; unique(categories) end
        shared[key] = (; pairs(scale_options)..., categories)
    end
    pieces(role) = AoG.ProcessedLayers([p for ps in processed[role] for (p, _) in ps])
    left = pieces(:y)
    secondaryonly = isempty(left.layers)
    if secondaryonly
        left = AoG.ProcessedLayers(data((x=Float64[], y=Float64[])) * mapping(:x, :y) * visual(Lines))
    end
    drawn = AoG.draw(left, scale_settings(:y, shared); legend=(; show=false), axis, options...)
    size(drawn.grid) == (1, 1) || error("Independent y scales currently require one panel")
    primary = only(drawn.grid).axis
    grids = [vec(drawn.grid)]
    for role in roles[2:end]
        scale = config(role)
        secondaryaxis = (; yaxisposition=get(scale, :position, :left), backgroundcolor=:transparent,
            xgridvisible=false, ygridvisible=false, xlabelvisible=false, xticklabelsvisible=false,
            xticksvisible=false, leftspinevisible=get(scale, :position, :left) === :left,
            rightspinevisible=get(scale, :position, :left) === :right,
            bottomspinevisible=false, topspinevisible=false, xscale=primary.xscale[], xreversed=primary.xreversed[])
        grid = AoG.draw!(drawn.figure[1, 1], pieces(role), scale_settings(role, shared); axis=secondaryaxis)
        secondary = only(grid).axis
        AoG.Makie.reset_limits!(secondary)
        haskey(scale, :limits) && AoG.Makie.ylims!(secondary, scale.limits...)
        secondary.yreversed = get(scale, :reversed, false)
        if secondaryonly
            AoG.Makie.hideydecorations!(primary)
            primary.leftspinevisible = false
            bounds = secondary.targetlimits[]
            AoG.Makie.xlims!(primary, bounds.origin[1], bounds.origin[1] + bounds.widths[1])
            secondaryonly = false
        end
        AoG.Makie.linkxaxes!(primary, secondary)
        push!(grids, vec(grid))
    end
    grid = reduce(vcat, grids)
    label_inspector!(grid)
    if get(legend, :show, true)
        all_groups = Dict{Symbol,Any}[Dict{Symbol,Any}(key => entries[i] for (key, entries) in pairs(primary))
            for ps in values(processed) for pieces in ps for (_, primary) in pieces
            if !isempty(primary) for i in eachindex(first(values(primary)))]
        sections = legend_sections(grid, texts, get(legend, :merge, nothing), all_groups)
        if !isempty(sections)
            position = get(legend, :position, :right)
            kwargs = (k => v for (k, v) in pairs(legend) if k ∉ (:show, :position, :merge))
            titles = [get(legend, :titlevisible, true) && !isempty(something(s.title, "")) ? s.title : nothing for s in sections]
            AoG.Makie.Legend(AoG.guides_position(drawn.figure, position), [s.samples for s in sections],
                [s.texts for s in sections], titles; orientation=AoG.default_orientation(position), kwargs...)
        end
    end
    return drawn.figure
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

# The kind of each role from the types of its values in each line, `role => type`, as
# AlgebraOfGraphics judges a column of values of that type. A type of `Any` is not known.
function scale_kinds(types::Vector{Pair{Symbol,Any}})::Dict{Symbol,Symbol}
    found = Dict{Symbol,Set{Union{Nothing,Symbol}}}()
    for (role, type) in types
        judged = type === Any ? nothing : AoG.scientific_type(type)
        push!(get!(Set{Union{Nothing,Symbol}}, found, role),
            judged === AoG.continuous ? :continuous : judged === AoG.categorical ? :categorical : nothing)
    end
    return Dict(role => only(kinds) for (role, kinds) in found if length(kinds) == 1 && only(kinds) !== nothing)
end
scale_kinds(declaration::Declaration, input) = scale_kinds(Base.invokelatest(declaration.types, input))

# A plot of data that it holds: the types of the columns of each line's data.
function scale_kinds(plot::PlotLines)::Dict{Symbol,Symbol}
    types = Pair{Symbol,Any}[]
    for line in plot.lines, layer in (line.layers isa AoG.Layers ? line.layers.layers : [line.layers])
        layer isa AoG.Layer && layer.data isa AoG.Columns || continue
        columns = Tables.columns(layer.data.columns)
        type(name::Union{Symbol,AbstractString}) = eltype(Tables.getcolumn(columns, Symbol(name)))
        # A title after `=>` stays out, and a function after it applies to each value.
        type(value::Pair) = last(value) isa AbstractString ? type(first(value)) :
            Base.infer_return_type(last(value) isa Pair ? first(last(value)) : last(value), Tuple{type(first(value))})
        type(_) = Any
        append!(types, [role => type(value) for (role, value) in pairs(layer.named)])
    end
    return scale_kinds(types)
end
scale_kinds(plot::Scaled) = scale_kinds(plot.layers)

# TODO: the lines are processed again here; process them once for `mappings`, this and the drawing.
function scale_categories(plot::PlotLines)::Dict{Symbol,Vector{Any}}
    found = Dict{Symbol,Vector{Any}}()
    for layers in processed_lines(plot), (p, _) in layers, (key, values) in pairs(p.primary)
        key isa Symbol && append!(get!(Vector{Any}, found, key), values)
    end
    # Values that do not sort together, such as numbers and text, keep the order they come in.
    return Dict(key => (try sort(unique(values)) catch; unique(values) end) for (key, values) in found)
end
scale_categories(plot::Scaled) = scale_categories(plot.layers)

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
    scales(kind) = unique(first, [aes => scale for entry in grid
        for (aes, d) in pairs(AoG.legendable_scales(Val(kind),
            kind === :categorical ? entry.categoricalscales : entry.continuousscales))
        for (id, scale) in pairs(d) if id === nothing])
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
retransformed(layers::YScaleLayers, change) = YScaleLayers([role => retransformed(drawable(layer), change) for (role, layer) in layers.layers])
axis_layers(layer::YScaleLayers) = layer
axis_layers(layer) = drawable(layer)
retransformed(plot::PlotLines, change) =
    PlotLines([PlotLine(retransformed(axis_layers(line.layers), change), line.shared, line.drawn) for line in plot.lines])

function figure(plot::Scaled, args...; options...)
    for (r, _) in plot.scales
        is_y_scale(r) && continue
        haskey(ROLE_SCALES, r) || error("scales sets the scale of a role such as color; $r is not one")
    end
    # `limits` and `reversed` of x and y are ours: Makie's axis draws them, and the limits also
    # remove the points outside them before the analyses run.
    limits = Any[nothing, nothing]
    axis = Pair{Symbol,Any}[]
    primary = get(Dict(plot.scales), :y, (;))
    yscales = Dict{Symbol,Any}(role => merge(primary, value) for (role, value) in plot.scales if is_y_scale(role))
    get!(yscales, :y, primary)
    scales = map(filter(pair -> !is_y_scale(first(pair)) || first(pair) === :y, plot.scales)) do (r, value)
        r in (:x, :y) && value isa NamedTuple || return r => value
        haskey(value, :limits) && (limits[r === :x ? 1 : 2] = value.limits)
        get(value, :reversed, false) && push!(axis, Symbol(r, :reversed) => true)
        return r => Base.structdiff(value, NamedTuple{(:limits, :reversed, :position)})
    end
    push!(axis, :yaxisposition => get(primary, :position, :left))
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
    if layers isa PlotLines
        layers = PlotLines([PlotLine(with_scale_limits(line.layers, limits, yscales), line.shared, line.drawn) for line in layers.lines])
    elseif any(!isnothing, limits)
        layers = retransformed(layers, t -> t ∘ WithinLimits(limits))
    end
    isempty(functions) || (layers = retransformed(layers, t -> MovedPoints(functions) ∘ t))
    legend = (; plot.legend..., get(options, :legend, (;))...)
    draw() = figure(layers, settings, args...; options..., axis=(; axis..., get(options, :axis, (;))...),
        texts=plot.texts, legend, (layers isa PlotLines ? (; yscales) : (;))...)
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
        error("A result is drawn by multiplying it with a visual")
    plottype = layer.transformation.plottype
    # An aggregate's values fill the places of the visual after x, in the order of its functions:
    # `aggregate(mean, std) * visual(Errorbars)` draws x, mean and std. A function with several
    # values, such as `extrema`, fills one place for each.
    # TODO: with `direction = :x`, group the points by y and draw the values on x.
    # TODO: `aggregate(y = mean, low = minimum, high = maximum)`, with each value named by its place.
    if !isempty(getfield(result, :scaled))
        groups = getfield(result, :groups)
        places = Pair{Symbol,Vector}[]
        for name in getfield(result, :scaled)
            computed = [metadata(group)[name] for group in groups]
            first(computed) isa Tuple ?
                append!(places, [Symbol(name, "[", i, "]") => getindex.(computed, i) for i in eachindex(first(computed))]) :
                push!(places, name => computed)
        end
        # A third place of `Lines` or `Scatter` is z, which this axis does not draw.
        kinds = try
            AoG.aesthetic_mapping(plottype, ntuple(_ -> AoG.Continuous(), length(places) + 1)...)
        catch err
            err isa MethodError || rethrow()
        end
        (kinds isa MethodError || any(==(AoG.AesZ), values(kinds))) &&
            error("$(plottype) cannot draw the $(length(places)) values of this aggregate at each x: " *
                join(first.(places), ", "))
        # The first value is drawn as the points' y, under its title.
        positional = Any[nothing; [i == 1 ? name => title(getfield(result, :positional)[2]) : name for (i, (name, _)) in enumerate(places)]]
        return over_result(result, (; places...), AoG.Layer(layer.transformation, nothing, positional, layer.named))
    end
    # The data of each fit, its first column as x and its second as y, with the group's value in
    # each role.
    positional = getfield(result, :positional)
    # A role the plot type cannot show, such as `marker` for `Lines`, is left out of its mapping.
    shown = hasmethod(AoG.aesthetic_mapping, Tuple{Type{plottype},Int}) ?
        keys(AoG.aesthetic_mapping(plottype, length(positional))) : keys(Dict(getfield(result, :named)))
    roles = [(role, value, column(value)) for (role, value) in getfield(result, :named) if role in shown]
    drawn = column.(positional)
    columns = Dict{Symbol,Vector{Any}}(name => Any[] for name in [drawn; [c for (_, _, c) in roles]])
    for group in getfield(result, :groups)
        values = item_data(group)
        for (name, value) in zip(drawn, values)
            append!(columns[name], value)
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
# With `points`, the code of the layer's points, and items of a workspace, the workspace computes the
# result (`Analysis`).
function resolve(layer::AoG.Layer, items, axes, points=nothing)
    split = split_y_scales(layer, items, axes, points)
    split === nothing || return split
    named = Pair{Symbol,Any}[role => value for (role, value) in pairs(layer.named)]
    found = steps(layer.transformation)
    computes(step) = step isa Union{Fit,Aggregate}
    if !any(computes, found)
        layer.data isa AoG.Columns || return layer
        table, positional, named = one_y(layer.data.columns, layer.positional, named)
        stacked = AoG.mapping(positional...; named...)
        return AoG.Layer(layer.transformation, AoG.Columns(table), stacked.positional, stacked.named)
    end
    computes(first(found)) && count(computes, found) == 1 ||
        error("A fit or an aggregate takes the points of its line before any visual, as in `fit(...) * visual(Lines)`")
    layer.data isa AoG.Columns || error("A fit or an aggregate needs points: a mapping of x and y, such as mapping(:x, :y)")
    analysis = Analysis(first(found), layer.positional, named, axes, points)
    workspace = items isa Selection ? getfield(items.data, :workspace) : nothing
    result = points === nothing || workspace === nothing ? analysis(layer.data.columns, items) :
        computed(analysis, layer.data.columns, items, workspace)
    after = found[2:end]
    return isempty(after) ? result : result * AoG.Layer(; transformation=foldl(AoG.:⨟, after))
end

function split_y_scales(layer::AoG.Layer, items, axes, points)
    roles = get(axes, :yroles, ())
    isempty(roles) && return nothing
    length(layer.positional) >= 2 || return nothing
    ys = layer.positional[2] isa AbstractVector ? layer.positional[2] : [layer.positional[2]]
    length(roles) == length(ys) || return nothing
    primary = get(axes, :y, (;))
    effective(role) = merge(primary, get(axes, role, (;)))
    assigned = [effective(role) == primary ? :y : role for role in roles]
    all(==(:y), assigned) && return nothing
    parts = Pair{Symbol,Any}[]
    for role in unique(assigned)
        take = findall(==(role), assigned)
        positional = copy(layer.positional)
        positional[2] = length(ys) > 1 ? ys[take] : only(ys)
        piece = AoG.Layer(; layer.transformation, layer.data, positional, layer.named)
        settings = (; x=get(axes, :x, (;)), y=effective(role))
        push!(parts, role => resolve(piece, items, settings, points))
    end
    return YScaleLayers(parts)
end

Base.:+(a::YScaleLayers, b::YScaleLayers) = YScaleLayers([a.layers; b.layers])
Base.:+(a::YScaleLayers, b::Union{AoG.AbstractAlgebraic,Result}) = YScaleLayers([a.layers; :y => b])
Base.:+(a::Union{AoG.AbstractAlgebraic,Result}, b::YScaleLayers) = YScaleLayers([:y => a; b.layers])

function with_scale_limits(layers::YScaleLayers, limits, yscales)
    YScaleLayers([role => retransformed(drawable(layer), t -> t ∘ WithinLimits(
        Any[limits[1], get(get(yscales, role, yscales[:y]), :limits, nothing)])) for (role, layer) in layers.layers])
end
with_scale_limits(layer, limits, _) = any(!isnothing, limits) ?
    retransformed(drawable(layer), t -> t ∘ WithinLimits(limits)) : layer

# A fit or an aggregate of a layer's points, with what it needs to compute again: the values the
# layer maps, the settings of its axes, and the code of its points. The types of the step and the
# points hold the types of the functions they call, so a computed item of the analysis is computed
# again when their code changes.
struct Analysis{S<:Union{Fit,Aggregate},P<:Union{Points,Nothing}}
    step::S
    positional::Vector{Any}
    named::Vector{Pair{Symbol,Any}}
    axes::Any
    points::P
end

setting(analysis::Analysis, r, key, default) = get(get(analysis.axes, r, (;)), key, default)

# The points of `columns` that the analysis takes, with their mapping: several values of y as one
# y, inside the limits of the x and y scales.
function taken(analysis::Analysis, columns)
    table, positional, named = one_y(columns, analysis.positional, analysis.named)
    columns = Tables.columntable(table)
    inside = trues(length(first(columns)))
    for (position, r) in enumerate((:x, :y))
        limits = setting(analysis, r, :limits, nothing)
        (limits === nothing || position > length(positional)) && continue
        # A bound of `nothing` is Makie's own, so it removes no points.
        low, high = something(first(limits), -Inf), something(last(limits), Inf)
        value = positional[position]
        inside .&= [v isa Real && low <= v <= high for v in category.(Ref(value), columns[column(value)])]
    end
    # AlgebraOfGraphics draws no plot without points.
    isempty(inside) || any(inside) || error("The limits of the axes remove every point: " * join(
        ("$r = $(setting(analysis, r, :limits, nothing))" for r in (:x, :y) if setting(analysis, r, :limits, nothing) !== nothing), ", "))
    return map(values -> values[inside], columns), positional, named
end

# The result of the analysis over the points of `columns`, whose items are `items`.
function (analysis::Analysis)(columns, items)::Result
    table, positional, named = taken(analysis, columns)
    return Result(analysis.step, table, positional, named, items; scale=setting(analysis, :y, :scale, identity))
end

# The result of the analysis in the workspace of `items`: one computed item for each group of the
# points, such as each chip, which the workspace computes again when an item of the group changes.
# Its id is the code that gives it (`id` below), so a change of the plot's visuals, palette or
# legend computes nothing again.
# TODO: a group whose points the plot no longer has, or an analysis whose code changed, stays in the
# workspace until it closes.
function computed(analysis::Analysis, columns, items::Selection, workspace)::Result
    table, positional, named = taken(analysis, columns)
    roles = grouping(named, table)
    by = unique(Symbol[column(v) for (_, v) in roles])
    keys = [NamedTuple{Tuple(by)}(Tuple(table[k][row] for k in by)) for row in eachindex(table[ITEM])]
    values = map(unique(keys)) do key
        places = sort(unique(table[ITEM][[row for row in eachindex(keys) if isequal(keys[row], key)]]))
        value = Workspace.Computation(analysis, items[places]; group=key)
        push!(workspace, value)
        return value
    end
    drawn = DataBrowserPlots.DRAWN[]
    drawn === nothing || union!(drawn, id.(values))
    groups = @timed_dbg "plot_results" reduce(vcat, Workspace.results(workspace, id.(values)); init=Group[])
    return Result(analysis.step, groups, positional, roles; scale=setting(analysis, :y, :scale, identity))
end

# The analysis of one group of points, as the workspace computes it: the groups of the result over
# the points of `items` in `group`. A fit gives one group, whose parameters are its metadata.
function (analysis::Analysis)(items::Selection; group::NamedTuple)
    table, positional, named = taken(analysis, Tables.columntable(analysis.points.table(items)))
    rows = [row for row in eachindex(table[ITEM]) if all(k -> isequal(table[k][row], group[k]), keys(group))]
    result = Result(analysis.step, map(values -> values[rows], table), positional, named, items;
        scale=setting(analysis, :y, :scale, identity))
    return analysis.step isa Fit ? only(result) : collect(result)
end

Workspace.function_name(analysis::Analysis) = analysis.step isa Fit ? "fit" : "aggregate"
# The code of a fit or an aggregate is the `@plot` that defines its points.
Base.which(value::Workspace.Computation{<:Analysis}) = only(methods(value.f.points.table))

# The code that gives the result of a group, such as
# `fit(line, (a = 1,)) of :V, :I by :Chip; y scale log10 for :Chip = "A"`: the step, the values
# mapped to x and y, the values that form the groups, the limits and the y scale, and the group.
# Titles, transformations and visuals are left out. The code of the functions the step calls, such
# as the curve of a fit, is in the type of the analysis instead. The id ends with a digest of the
# values it is of: the workspace items by id, and the values a window prepared by the computation
# that made them, so that the same plot of other values, such as a table's selected parts, is
# another result.
function DataBrowserAPI.id(value::Workspace.Computation{<:Analysis})
    analysis, group = value.f, value.settings.group
    texts = analysis.points.texts
    text(v) = v isa AbstractVector ? "[" * join(text.(v), ", ") * "]" : get(texts, column(v), repr(column(v)))
    by = sort(unique([text(v) for (_, v) in analysis.named]))
    settings = ["$r limits $(repr(limits))" for r in (:x, :y) for limits in (setting(analysis, r, :limits, nothing),) if limits !== nothing]
    scale = setting(analysis, :y, :scale, identity)
    scale === identity || push!(settings, "y scale $scale")
    return string(analysis.points.step, " of ", join(text.(analysis.positional), ", "),
        isempty(by) ? "" : " by " * join(by, ", "), isempty(settings) ? "" : "; " * join(settings, ", "),
        isempty(group) ? "" : " for " * join(("$(get(texts, k, repr(k))) = $(repr(v))" for (k, v) in pairs(group)), ", "),
        " on ", string(hash(map(only(value.args).id, getfield(only(value.args).data, :items)) do i, ref
            ref isa Workspace.ComputationItem ? hash(ref.computation) : hash(i)
        end); base=62))
end

# The title of a group's result: the step and the group's values, such as
# `fit(line, (a = 1,)) for A`. The id holds the rest of the code.
DataBrowserAPI.label(value::Workspace.Computation{<:Analysis}) = string(value.f.points.step,
    isempty(value.settings.group) ? "" : " for " * join(string.(values(value.settings.group)), ", "))

# The title of a value of `mapping`: the title after `=>`, as in `:I => "V > 0"` and
# `:I => abs => "V < 0"`, or the column's name.
title(value) = !(value isa Pair) ? string(column(value)) : last(value) isa AbstractString ? last(value) :
    last(value) isa Pair && last(last(value)) isa AbstractString ? last(last(value)) : string(column(value))

# The points of a layer with several values of y, as `y` and `y2` give, as points of one y: a row
# for each point and each value, with the value in the column `y` and its title in the column
# `ydims`, which the roles that `ydims()` maps take, in the order of the values and without a title
# in the legend. A layer with one y stays as it is.
# TODO: a column of the data named `y` or `ydims`.
function one_y(table, positional::Vector, named::Vector)
    length(positional) == 2 && positional[2] isa AbstractVector || return table, positional, named
    columns = Tables.columntable(table)
    ys = positional[2]
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
resolve(layers::AoG.Layers, items, axes, points=nothing) = foldl(+, (resolve(layer, items, axes, points) for layer in layers.layers))

# A line that reads the values of a result, drawn over its groups: `table` holds the values the
# line's mapping reads, one row for each group, and the line takes the roles of the result's points,
# such as `color`, so that it shares their legend entries. A line with `y` and no `x` takes the x of
# the result's points, as `mapping(y = result.mean)`.
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
    # A value read by index, as `result.extrema[1]`, is one too; a value the line computes itself, as
    # `10^result.mean`, is drawn as it is.
    scale = getfield(result, :scale)
    # The column of `result.extrema[1]` is named `(:extrema)[1]`.
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
drawable(layers::YScaleLayers) = reduce(+, [drawable(layer) for (_, layer) in layers.layers])
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
