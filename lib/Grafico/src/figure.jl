using Makie: Makie, Axis, Axis3, Figure, Legend, Lines, Scatter
import Makie.SpecApi as S
using Tables: Tables

# The package draws the legend itself, so that roles share a section when one determines the others
# (plans/graphics-grammar.md). `texts` are the texts of the entries in the section of a role.
# `groups` are the values of every group's roles, as `key => value`, also of the roles that its
# layer cannot show.
function figure(
    specification::Union{Layer, Layers, ProcessedLayer, ProcessedLayers},
    args...;
    legend=(;),
    texts::Vector{Pair{Symbol,Function}}=Pair{Symbol,Function}[],
    groups::Vector{Dict{Symbol,Any}}=Dict{Symbol,Any}[],
    options...,
)
    _hasobs(specification) && return _reactive_figure(specification,args...;legend,texts,groups,options...)
    drawn = draw(drawable(specification), args...; legend=(; show=false), options...)
    label_inspector!(drawn.grid)
    get(legend, :show, true) || return drawn.figure
    sections = legend_sections(drawn.grid, texts, get(legend, :merge, nothing), groups)
    isempty(sections) && return drawn.figure
    position = get(legend, :position, :right)
    settings = (k => v for (k, v) in pairs(legend) if k ∉ (:show, :position, :merge))
    shown = get(legend, :titlevisible, true)
    titles = [shown && !isempty(something(s.title, "")) ? s.title : nothing for s in sections]
    Legend(guides_position(drawn.figure, position), [s.samples for s in sections],
        [s.texts for s in sections], titles; orientation=default_orientation(position), settings...)
    return drawn.figure
end

"""
    spec(plot, [input]; options...) -> Makie.GridLayoutSpec

Compile `plot` (and `input` when `plot` is a [`Declaration`](@ref)) into a declarative
`Makie.SpecApi.GridLayout` without creating a `Figure` or `Scene`. Observable data and mappings
are read at their current values; visual and axis settings keep their live connections. Use
`figure(plot)` to connect future data and mapping updates.
"""
function spec(
    specification::Union{Layer, Layers, ProcessedLayer, ProcessedLayers},
    args...;
    legend=(;),
    texts::Vector{Pair{Symbol,Function}}=Pair{Symbol,Function}[],
    groups::Vector{Dict{Symbol,Any}}=Dict{Symbol,Any}[],
    axis=(;),
    facet=(;),
    options...,
)
    settings = !isempty(args) && first(args) isa Scales ? first(args) : scales()
    ae = compute_axes_grid(drawable(specification), settings;
        axis=_kwdict(axis, :axis), facet=_kwdict(facet, :facet))
    cells = Pair{Tuple{Int,Int},Any}[]
    for ase in ae
        plots = Makie.PlotSpec[_entry_spec(entry) for entry in ase.entries]
        ax_spec = _axis_spec(ase.axis,plots)
        push!(cells, ase.axis.position => ax_spec)
    end
    if get(legend, :show, true)
        sections = legend_sections(ae, texts, get(legend, :merge, nothing), groups)
        if !isempty(sections)
            position = get(legend, :position, :right)
            kwargs = (k => v for (k, v) in pairs(legend) if k ∉ (:show, :position, :merge))
            shown = get(legend, :titlevisible, true)
            titles = [shown && !isempty(something(s.title, "")) ? s.title : nothing for s in sections]
            leg_spec = S.Legend([s.samples for s in sections], [s.texts for s in sections], titles;
                orientation=default_orientation(position), kwargs...)
            rows, cols = size(ae)
            if position === :top
                cells = [(r + 1, c) => s for ((r, c), s) in cells]
                push!(cells, (1, 1) => leg_spec)
            elseif position === :left
                cells = [(r, c + 1) => s for ((r, c), s) in cells]
                push!(cells, (1, 1) => leg_spec)
            elseif position === :bottom
                push!(cells, (rows + 1, 1) => leg_spec)
            else
                push!(cells, (1, cols + 1) => leg_spec)
            end
        end
    end
    return S.GridLayout(cells)
end

# The text the inspector shows for a point: its x and y under the labels of the axes, then the value
# of each role of its group, such as its color, under the title of the role's scale.
function label_inspector!(grid)
    for entries in grid
        axis = entries.axis
        axis isa Axis || continue
        for (plot, p) in zip(axis.scene.plots, entries.processedlayers)
            mapping = aesthetic_mapping(p)
            roles = [(getlabel(scale), Dict(zip(datavalues(scale), datalabels(scale))), value)
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
    digits(x) = replace(string(round(x; sigdigits=4)), r"\.0$" => "")
    -3 <= power < 4 && return digits(value)
    superscript = map(c -> c == '-' ? '⁻' : "⁰¹²³⁴⁵⁶⁷⁸⁹"[nextind("⁰¹²³⁴⁵⁶⁷⁸⁹", 0, c - '0' + 1)], string(power))
    return "$(digits(value / 10.0^power))×10$superscript"
end

# The processed layers of each line, drawn or not, each with the values of its groups' roles. A
# role the line takes from the header is left out of the layers whose plot type cannot show it, such
# as `markersize` of `Lines`. Its values still divide the line's points into groups, as other roles'
# values do, and stay among the values of the groups for the legend.
function processed_lines(plot::PlotLines, settings::Scales=scales())::Vector{Vector{Pair{ProcessedLayer,Any}}}
    transforms = axis_transforms_from_scales(settings)
    return map(plot.lines) do line
        (line.layers === nothing || line.layers === false) && return Pair{ProcessedLayer,Any}[]
        map(ProcessedLayers(drawable(line.layers), transforms).layers) do p
            shown = aesthetic_mapping(p)
            skipped = [key for key in line.shared if !haskey(shown, key) && hardcoded_mapping(key) === nothing]
            primary, named, labels = copy(p.primary), copy(p.named), copy(p.labels)
            for key in skipped, values in (primary, named, labels)
                haskey(values, key) && delete!(values, key)
            end
            ProcessedLayer(p; primary, named, labels) => p.primary
        end
    end
end

function figure(plot::PlotLines, args...; yscales=Dict{Symbol,Any}(), options...)
    _hasobs(plot) && return _reactive_figure(plot,args...;yscales,options...)
    any(line -> line.drawn && line.layers isa YScaleLayers, plot.lines) &&
        return scaled_y_figure(plot, yscales, args...; options...)
    settings = !isempty(args) && first(args) isa Scales ? first(args) : scales()
    drawn = reduce(vcat, [layers for (line, layers) in zip(plot.lines, processed_lines(plot, settings)) if line.drawn];
        init=Pair{ProcessedLayer,Any}[])
    groups = [Dict{Symbol,Any}(key => values[i] for (key, values) in pairs(primary))
        for (_, primary) in drawn if !isempty(primary) for i in eachindex(first(values(primary)))]
    return figure(ProcessedLayers(first.(drawn)), args...; options..., groups)
end

function spec(plot::PlotLines, args...; yscales=Dict{Symbol,Any}(), options...)
    _hasobs(plot) && return spec(_snapshot(plot),args...;yscales,options...)
    any(line -> line.drawn && line.layers isa YScaleLayers, plot.lines) &&
        return scaled_y_spec(plot, yscales, args...; options...)
    settings = !isempty(args) && first(args) isa Scales ? first(args) : scales()
    drawn = reduce(vcat, [layers for (line, layers) in zip(plot.lines, processed_lines(plot, settings)) if line.drawn];
        init=Pair{ProcessedLayer,Any}[])
    groups = [Dict{Symbol,Any}(key => values[i] for (key, values) in pairs(primary))
        for (_, primary) in drawn if !isempty(primary) for i in eachindex(first(values(primary)))]
    return spec(ProcessedLayers(first.(drawn)), args...; options..., groups)
end

function scaled_y_figure(plot::PlotLines, yscales, args...; legend=(;), texts=Pair{Symbol,Function}[], axis=(;), options...)
    settings = !isempty(args) && first(args) isa Scales ? first(args) : scales()
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
    scale_settings(role, shared=settings.dict) = scales(;
        (key => value for (key, value) in pairs(shared) if key !== :Y)...,
        Y=Base.structdiff(config(role), NamedTuple{(:limits, :reversed, :position)}))
    processed = Dict(role => processed_lines(PlotLines(groups[role]), scale_settings(role)) for role in roles)
    shared = Dict{Symbol,Any}(pairs(settings.dict))
    for role in LEGEND_ROLES
        categories = Any[value for ps in values(processed) for pieces in ps for (p, _) in pieces
            if haskey(p.primary, role) for value in p.primary[role]]
        isempty(categories) && continue
        key = ROLE_SCALES[role]
        scale_options = get(shared, key, (;))
        haskey(scale_options, :categories) && continue
        shared[key] = (; pairs(scale_options)..., categories=category_order(categories))
    end
    pieces(role) = ProcessedLayers([p for ps in processed[role] for (p, _) in ps])
    left = pieces(:y)
    secondaryonly = isempty(left.layers)
    if secondaryonly
        left = ProcessedLayers(data((x=Float64[], y=Float64[])) * mapping(:x, :y) * visual(Lines))
    end
    drawn = draw(left, scale_settings(:y, shared); legend=(; show=false), axis, options...)
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
        grid = draw!(drawn.figure[1, 1], pieces(role), scale_settings(role, shared); axis=secondaryaxis)
        secondary = only(grid).axis
        Makie.reset_limits!(secondary)
        haskey(scale, :limits) && Makie.ylims!(secondary, scale.limits...)
        secondary.yreversed = get(scale, :reversed, false)
        if secondaryonly
            Makie.hideydecorations!(primary)
            primary.leftspinevisible = false
            bounds = secondary.targetlimits[]
            Makie.xlims!(primary, bounds.origin[1], bounds.origin[1] + bounds.widths[1])
            secondaryonly = false
        end
        Makie.linkxaxes!(primary, secondary)
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
            Legend(guides_position(drawn.figure, position), [s.samples for s in sections],
                [s.texts for s in sections], titles; orientation=default_orientation(position), kwargs...)
        end
    end
    return drawn.figure
end

function scaled_y_spec(plot::PlotLines, yscales, args...; legend=(;), texts=Pair{Symbol,Function}[], axis=(;), facet=(;), options...)
    settings = !isempty(args) && first(args) isa Scales ? first(args) : scales()
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
    scale_settings(role, shared=settings.dict) = scales(;
        (key => value for (key, value) in pairs(shared) if key !== :Y)...,
        Y=Base.structdiff(config(role), NamedTuple{(:limits, :reversed, :position)}))
    processed = Dict(role => processed_lines(PlotLines(groups[role]), scale_settings(role)) for role in roles)
    shared = Dict{Symbol,Any}(pairs(settings.dict))
    for role in LEGEND_ROLES
        categories = Any[value for ps in values(processed) for pieces in ps for (p, _) in pieces
            if haskey(p.primary, role) for value in p.primary[role]]
        isempty(categories) && continue
        key = ROLE_SCALES[role]
        scale_options = get(shared, key, (;))
        haskey(scale_options, :categories) && continue
        shared[key] = (; pairs(scale_options)..., categories=category_order(categories))
    end
    pieces(role) = ProcessedLayers([p for ps in processed[role] for (p, _) in ps])
    left = pieces(:y)
    secondaryonly = isempty(left.layers)
    if secondaryonly
        left = ProcessedLayers(data((x=Float64[], y=Float64[])) * mapping(:x, :y) * visual(Lines))
    end
    ae_primary = compute_axes_grid(left, scale_settings(:y, shared);
        axis=_kwdict(axis, :axis), facet=_kwdict(facet, :facet))
    size(ae_primary) == (1, 1) || error("Independent y scales currently require one panel")
    ase_primary = only(ae_primary)
    primary_plots = Makie.PlotSpec[Makie.PlotSpec(e.plottype, e.positional...; pairs(e.named)...) for e in ase_primary.entries]
    primary_spec = S.Axis(; plots=primary_plots, pairs(ase_primary.axis.attributes)...)
    cells = Pair{Tuple{Int,Int},Any}[(1, 1) => primary_spec]
    axes_to_link = [primary_spec]
    aes = [vec(ae_primary)]
    for role in roles[2:end]
        scale = config(role)
        secondaryaxis = (; yaxisposition=get(scale, :position, :left), backgroundcolor=:transparent,
            xgridvisible=false, ygridvisible=false, xlabelvisible=false, xticklabelsvisible=false,
            xticksvisible=false, leftspinevisible=get(scale, :position, :left) === :left,
            rightspinevisible=get(scale, :position, :left) === :right,
            bottomspinevisible=false, topspinevisible=false,
            yreversed=get(scale, :reversed, false),
            (haskey(scale, :limits) ? (; limits=(nothing, scale.limits)) : (;))...)
        ae_sec = compute_axes_grid(pieces(role), scale_settings(role, shared);
            axis=_kwdict(secondaryaxis, :axis), facet=_kwdict(facet, :facet))
        ase_sec = only(ae_sec)
        sec_plots = Makie.PlotSpec[Makie.PlotSpec(e.plottype, e.positional...; pairs(e.named)...) for e in ase_sec.entries]
        sec_spec = S.Axis(; plots=sec_plots, pairs(ase_sec.axis.attributes)...)
        push!(cells, (1, 1) => sec_spec)
        push!(axes_to_link, sec_spec)
        push!(aes, vec(ae_sec))
    end
    if get(legend, :show, true)
        all_groups = Dict{Symbol,Any}[Dict{Symbol,Any}(key => entries[i] for (key, entries) in pairs(primary))
            for ps in values(processed) for pieces in ps for (_, primary) in pieces
            if !isempty(primary) for i in eachindex(first(values(primary)))]
        sections = legend_sections(reduce(vcat, aes), texts, get(legend, :merge, nothing), all_groups)
        if !isempty(sections)
            position = get(legend, :position, :right)
            kwargs = (k => v for (k, v) in pairs(legend) if k ∉ (:show, :position, :merge))
            titles = [get(legend, :titlevisible, true) && !isempty(something(s.title, "")) ? s.title : nothing for s in sections]
            leg_spec = S.Legend([s.samples for s in sections], [s.texts for s in sections], titles;
                orientation=default_orientation(position), kwargs...)
            push!(cells, (1, 2) => leg_spec)
        end
    end
    return S.GridLayout(cells; xaxislinks=[axes_to_link])
end

# The named roles each line can show: those of its plot types, and those of the layout.
function mappings(plot::PlotLines)::Vector{Vector{Symbol}}
    layout = [:layout, :row, :col, :group]
    return map(processed_lines(plot)) do layers
        union((Symbol[key for key in keys(aesthetic_mapping(p)) if key isa Symbol] for (p, _) in layers)..., layout)
    end
end
mappings(plot::Scaled) = mappings(plot.layers)

# The kind of each role from the types of its values in each line, `role => type`, as
# Grafico judges a column of values of that type. A type of `Any` is not known.
function scale_kinds(types::Vector{Pair{Symbol,Any}})::Dict{Symbol,Symbol}
    found = Dict{Symbol,Set{Union{Nothing,Symbol}}}()
    for (role, type) in types
        judged = type === Any ? nothing : scientific_type(type)
        push!(get!(Set{Union{Nothing,Symbol}}, found, role),
            judged === continuous ? :continuous : judged === categorical ? :categorical : nothing)
    end
    return Dict(role => only(kinds) for (role, kinds) in found if length(kinds) == 1 && only(kinds) !== nothing)
end
scale_kinds(declaration::Declaration, input) = scale_kinds(Base.invokelatest(declaration.types, input))

# A plot of data that it holds: the types of the columns of each line's data.
function scale_kinds(plot::PlotLines)::Dict{Symbol,Symbol}
    types = Pair{Symbol,Any}[]
    for line in plot.lines, layer in (line.layers isa Layers ? line.layers.layers : [line.layers])
        layer isa Layer && layer.data isa Columns || continue
        columns = Tables.columns(layer.data.columns)
        type(name::Union{Symbol,AbstractString}) = eltype(Tables.getcolumn(columns, Symbol(name)))
        type(value::Pair) = last(value) isa AbstractString ? type(first(value)) :
            Base.infer_return_type(last(value) isa Pair ? first(last(value)) : last(value), Tuple{type(first(value))})
        type(_) = Any
        append!(types, [role => type(value) for (role, value) in pairs(layer.named)])
    end
    return scale_kinds(types)
end
scale_kinds(plot::Scaled) = scale_kinds(plot.layers)

function scale_categories(plot::PlotLines)::Dict{Symbol,Vector{Any}}
    found = Dict{Symbol,Vector{Any}}()
    for layers in processed_lines(plot), (p, _) in layers, (key, values) in pairs(p.primary)
        key isa Symbol && append!(get!(Vector{Any}, found, key), values)
    end
    return Dict(key => category_order(values) for (key, values) in found)
end

# The values of a scale of categories, each once, in order. Values that do not sort together, such
# as numbers and text, keep the order they come in.
function category_order(values::Vector)::Vector
    values = unique(values)
    try
        return sort(values)
    catch err
        err isa MethodError || rethrow()
        return values
    end
end
scale_categories(plot::Scaled) = scale_categories(plot.layers)

# The role of an aesthetic, as `mapping` names it: `:linestyle` for `AesLineStyle`.
role(aes) = Symbol(lowercase(replace(string(nameof(aes)), r"^Aes" => "")))

# The pieces of a plot, such as its scatter and its lines: the processed layers of one plot type and
# one set of attributes.
piece(p::ProcessedLayer) = (p.plottype, p.attributes)

# The legend's sections, each as `(; samples, texts, title)`: the categorical scales' sections, then
# one for each continuous scale, then one for the pieces with their own label. A section without
# entries is left out. `all_groups` are the values of every group's roles, as `figure` takes them.
function legend_sections(grid, texts::Vector{Pair{Symbol,Function}}, merge, all_groups::Vector{Dict{Symbol,Any}})
    scales(kind) = unique(first, [aes => scale for entry in grid
        for (aes, d) in pairs(legendable_scales(Val(kind),
            kind === :categorical ? entry.categoricalscales : entry.continuousscales))
        for (id, scale) in pairs(d) if id === nothing])
    categorical, continuous = Dict(scales(:categorical)), scales(:continuous)
    order = first.(scales(:categorical))
    processed = mapreduce(entry -> entry.processedlayers, vcat, grid)
    groups = map(processed) do p
        mapping = aesthetic_mapping(p)
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
    names = Dict(role(aes) => Dict{Any,String}(zip(datavalues(scale), string.(datalabels(scale))))
        for (aes, scale) in categorical)
    sections = map(section_roles(order, groups, merge)) do section
        given = [text for (r, text) in texts if r in role.(section)]
        length(given) <= 1 || error("The legend texts of $(join(role.(section), " and ")) name one section; give one")
        categorical_section(section, categorical, groups, processed, names, isempty(given) ? nothing : only(given))
    end
    append!(sections, [continuous_section(aes, scale, processed) for (aes, scale) in continuous])
    labelled = unique(piece, filter(p -> haskey(p.attributes, :label), processed))
    labels = unique(p.attributes[:label] for p in labelled)
    isempty(labels) || push!(sections, (; samples=[reduce(vcat, [_legend_elements(p, MixedArguments())
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
    looks = [Dict(zip(datavalues(scales[aes]), plotvalues(scales[aes]))) for aes in section]
    position(k, value) = findfirst(==(value), datavalues(scales[section[k]]))
    found = sort(combinations(section, groups); by=c -> [position(k, v) for (k, v) in enumerate(c)])
    samples = map(found) do combination
        entry_samples(Dict(aes => looks[k][combination[k]] for (k, aes) in enumerate(section)),
            Dict(zip(section, combination)), processed, groups)
    end
    texts = map(found) do combination
        entry = LegendEntry(Dict(role(aes) => v for (aes, v) in zip(section, combination)), names)
        text === nothing ? join(unique(names[role(aes)][v] for (aes, v) in zip(section, combination)), ", ") :
            Base.invokelatest(text, entry)
    end
    title = join(filter(!isempty, unique(string(getlabel(scales[aes])) for aes in section)), ", ")
    return (; samples, texts, title)
end

# The samples of one entry: one from each piece that drew a group with the entry's `values`, drawn
# with the entry's `looks`, as `aesthetic => look`.
function entry_samples(looks, values, processed, groups)
    samples = LegendElement[]
    for p in unique(piece, processed)
        mapping = aesthetic_mapping(p)
        attributes = MixedArguments()
        for key in [collect(keys(p.primary)); collect(keys(p.named))]
            aes = get(mapping, key, nothing)
            haskey(looks, aes) && !haskey(p.scale_mapping, key) && insert!(attributes, key, looks[aes])
        end
        drew = any(groups) do (drawn_by, group)
            drawn_by == piece(p) && all(aes -> !haskey(group, aes) || group[aes] == values[aes], keys(values))
        end
        isempty(attributes) || !drew || append!(samples, _legend_elements(p, attributes))
    end
    return samples
end

# The section of a continuous scale, such as marker sizes: an entry for each of its ticks.
function continuous_section(aes, scale, processed)
    _, looks, labels = datavalues_plotvalues_datalabels(aes, scale)
    samples = map(looks) do look
        reduce(vcat, map(unique(piece, processed)) do p
            mapping = aesthetic_mapping(p)
            attributes = MixedArguments()
            for key in keys(p.named)
                get(mapping, key, nothing) === aes && insert!(attributes, key, look)
            end
            isempty(attributes) ? LegendElement[] : _legend_elements(p, attributes)
        end)
    end
    return (; samples, texts=string.(labels), title=string(getlabel(scale)))
end

# The scale of each role that `scales(...)` can set.
const ROLE_SCALES = Dict(:x => :X, :y => :Y, :color => :Color, :marker => :Marker, :linestyle => :LineStyle,
    :markersize => :MarkerSize, :linewidth => :LineWidth, :layout => :Layout, :col => :Col, :row => :Row)

# A step that runs before the analyses of a layer and removes its points outside the limits of x and
# y, as `limits` of their scales does. `limits[i]` are those of position `i`, or `nothing`.
struct WithinLimits
    limits::Vector{Any}
end

function (step::WithinLimits)(p::ProcessedLayer)
    inside = map(eachindex(first(p.positional))) do group
        keep = trues(length(first(p.positional)[group]))
        for (position, limits) in enumerate(step.limits)
            (limits === nothing || position > length(p.positional)) && continue
            low, high = something(first(limits), -Inf), something(last(limits), Inf)
            keep .&= coalesce.(low .<= p.positional[position][group] .<= high, false)
        end
        keep
    end
    cut(values) = map(eachindex(values)) do group
        points = values[group]
        points isa AbstractVector && length(points) == length(inside[group]) ? points[inside[group]] : points
    end
    return ProcessedLayer(p; positional=map(cut, p.positional), named=map(cut, p.named))
end

# A step of `coord` that runs after the analyses of a layer and moves its points: `functions` take
# the x and y of a point and give where it is drawn, in order.
struct MovedPoints
    functions::Vector{Any}
end

function (step::MovedPoints)(p::ProcessedLayer)
    length(p.positional) >= 2 || error("coord moves points by their x and y; this layer has one position")
    x, y = copy(p.positional[1]), copy(p.positional[2])
    for group in eachindex(x)
        moved = map(x[group], y[group]) do a, b
            foldl((point, f) -> f(point...), step.functions; init=(a, b))
        end
        x[group], y[group] = first.(moved), last.(moved)
    end
    return ProcessedLayer(p; positional=[x, y, p.positional[3:end]...])
end

# The layers with `change` applied to their transformation, such as `t -> t ∘ step` to run `step`
# before the analyses, or `t -> step ∘ t` after them.
retransformed(::Union{Nothing,Bool}, _) = nothing
retransformed(layer::Layer, change) = Layer(; transformation=change(layer.transformation), layer.data, layer.positional, layer.named)
retransformed(layers::Layers, change) = Layers([retransformed(layer, change) for layer in layers.layers])
retransformed(layers::YScaleLayers, change) = YScaleLayers([role => retransformed(drawable(layer), change) for (role, layer) in layers.layers])
axis_layers(layer::YScaleLayers) = layer
axis_layers(layer) = drawable(layer)
retransformed(plot::PlotLines, change) =
    PlotLines([PlotLine(retransformed(axis_layers(line.layers), change), line.shared, line.drawn) for line in plot.lines])

function prepare_scaled(plot::Scaled; options...)
    for (r, _) in plot.scales
        is_y_scale(r) && continue
        haskey(ROLE_SCALES, r) || error("scales sets the scale of a role such as color; $r is not one")
    end
    limits = Any[nothing, nothing]
    axis = Pair{Symbol,Any}[]
    primary = get(Dict(plot.scales), :y, (;))
    yscales = Dict{Symbol,Any}(role => merge(primary, value) for (role, value) in plot.scales if is_y_scale(role))
    get!(yscales, :y, primary)
    scales_pairs = map(filter(pair -> !is_y_scale(first(pair)) || first(pair) === :y, plot.scales)) do (r, value)
        r in (:x, :y) && value isa NamedTuple || return r => value
        haskey(value, :limits) && (limits[r === :x ? 1 : 2] = value.limits)
        get(value, :reversed, false) && push!(axis, Symbol(r, :reversed) => true)
        return r => Base.structdiff(value, NamedTuple{(:limits, :reversed, :position)})
    end
    push!(axis, :yaxisposition => get(primary, :position, :left))
    zoom = Any[nothing, nothing]
    functions, scaled = Any[], false
    foreach(_validate_coord, plot.coords)
    for step in plot.coords, (key, value) in pairs(step)
        if key === :points
            scaled && error("A coord line with a function of the points comes before those that set a scale or reversed")
            push!(functions, value)
        elseif key in (:x, :y)
            scaled |= haskey(value, :scale) || haskey(value, :reversed)
            haskey(value, :scale) && push!(axis, Symbol(key, :scale) => value.scale)
            haskey(value, :reversed) && push!(axis, Symbol(key, :reversed) => value.reversed)
            haskey(value, :limits) && (zoom[key === :x ? 1 : 2] = value.limits)
        elseif key === :aspect
            push!(axis, :aspect => value)
        else
            throw(ArgumentError("coord accepts x/y coordinates and aspect."))
        end
    end
    shown = [z === nothing ? l : z for (z, l) in zip(zoom, limits)]
    any(!isnothing, shown) && push!(axis, :limits => Tuple(shown))
    settings = scales(; (ROLE_SCALES[r] => value for (r, value) in scales_pairs)...)
    layers = drawable(plot.layers)
    if layers isa PlotLines
        layers = PlotLines([PlotLine(with_scale_limits(line.layers, limits, yscales), line.shared, line.drawn) for line in layers.lines])
    elseif any(!isnothing, limits)
        layers = retransformed(layers, t -> t ∘ WithinLimits(limits))
    end
    isempty(functions) || (layers = retransformed(layers, t -> MovedPoints(functions) ∘ t))
    legend = (; plot.legend..., get(options, :legend, (;))...)
    axis_theme = plot.theme === nothing ? (; ) :
        (; pairs(get(makie_theme(plot.theme), :Axis, Makie.Attributes()))...)
    axis_kw = (; axis_theme..., axis..., get(options, :axis, (;))...)
    return layers, settings, axis_kw, legend, yscales
end

function figure(plot::Scaled, args...; options...)
    (_hasobs(plot) || _axis_reactive(plot)) && return _reactive_figure(plot,args...;options...)
    layers, settings, axis_kw, legend, yscales = prepare_scaled(plot; options...)
    draw_fig() = figure(layers, settings, args...; options..., axis=axis_kw,
        texts=plot.texts, legend, (layers isa PlotLines ? (; yscales) : (;))...)
    return plot.theme === nothing ? draw_fig() : Makie.with_theme(draw_fig, makie_theme(plot.theme))
end

function spec(plot::Scaled, args...; options...)
    _hasobs(plot) && return spec(_snapshot(plot),args...;options...)
    layers, settings, axis_kw, legend, yscales = prepare_scaled(plot; options...)
    build_spec() = spec(layers, settings, args...; options..., axis=axis_kw,
        texts=plot.texts, legend, (layers isa PlotLines ? (; yscales) : (;))...)
    return plot.theme === nothing ? build_spec() : Makie.with_theme(build_spec, makie_theme(plot.theme))
end

# The latest world: code that the browser runs defines the declaration after the caller started.
function figure(declaration::Declaration, input::Makie.Observable, args...; options...)
    return _reactive_figure(declaration,input,args...;options...)
end

figure(declaration::Declaration, input, args...; options...) =
    figure(Base.invokelatest(declaration.layers, input), args...; options...)

spec(declaration::Declaration, input, args...; options...) =
    spec(Base.invokelatest(declaration.layers, input), args...; options...)

function figure(plot::Makie.Observable, args...; options...)
    return _reactive_figure(plot,args...;options...)
end

# A theme from elsewhere, such as Makie's own, can also change what the plot shows, such as the bins
# of `Hist`.
function makie_theme(theme::PlotTheme)::Makie.Theme
    base = theme.base === nothing ? Makie.current_default_theme() :
        theme.base === :default ? Makie.Theme() : getproperty(Makie, Symbol(:theme_, theme.base))()
    return merge(Makie.Theme(; pairs(theme.settings)...), base)
end

# The function that places a value computed after `scale`, the function of an axis, back on that
# axis, such as `exp10` for `log10`.
function unscaled(scale)
    scale === identity && return identity
    inverse = Makie.inverse_transform(scale)
    inverse === nothing && error("The scale's function $scale has no inverse, so the values computed after it cannot be drawn")
    return inverse
end

function Base.:*(result::Result, layer::Layer)
    layer.transformation isa Visual ||
        error("A result is drawn by multiplying it with a visual")
    plottype = layer.transformation.plottype
    if !isempty(getfield(result, :scaled))
        groups = getfield(result, :groups)
        places = Pair{Symbol,Vector}[]
        for name in getfield(result, :scaled)
            computed = [group[name] for group in groups]
            first(computed) isa Tuple ?
                append!(places, [Symbol(name, "[", i, "]") => getindex.(computed, i) for i in eachindex(first(computed))]) :
                push!(places, name => computed)
        end
        kinds = aesthetic_mapping(plottype, ntuple(_ -> Continuous(), length(places) + 1)...)
        any(==(AesZ), values(kinds)) &&
            error("$(plottype) cannot draw the $(length(places)) values of this aggregate at each x: " *
                join(first.(places), ", "))
        positional = Any[nothing; [i == 1 ? name => title(getfield(result, :positional)[2]) : name for (i, (name, _)) in enumerate(places)]]
        return over_result(result, (; places...), Layer(layer.transformation, nothing, positional, layer.named))
    end
    positional = getfield(result, :positional)
    shown = keys(aesthetic_mapping(plottype, ntuple(_ -> Continuous(), length(positional))...))
    roles = [(role, value, column(value)) for (role, value) in getfield(result, :named) if role in shown]
    drawn = column.(positional)
    columns = Dict{Symbol,Vector{Any}}(name => Any[] for name in [drawn; [c for (_, _, c) in roles]])
    for group in getfield(result, :groups)
        values = group.curve
        for (name, value) in zip(drawn, values)
            append!(columns[name], value)
        end
        for (_, _, c) in unique(r -> r[3], roles)
            append!(columns[c], fill(group[c], length(first(values))))
        end
    end
    table = NamedTuple{Tuple(keys(columns))}(Tuple(identity.(values(columns))))
    mapped = mapping(positional...; (role => value for (role, value, _) in roles)...)
    return data(table) * mapped * layer
end

# A line of a plot as a layer of the header: its positions replace the header's, its named roles add
# to the header's or replace them, and a role set to `nothing` is removed. A line with its own data,
# such as a fit's result, keeps its own mapping.
inherit(::Layer, ::Union{Nothing,Bool}) = nothing
function inherit(header::Layer, line::Layer)
    line.data === nothing || return line
    positional = isempty(line.positional) ? header.positional : line.positional
    first(positional, 1) == [nothing] && length(header.positional) >= 1 &&
        (positional = [header.positional[1]; positional[2:end]])
    named = filter(!isnothing, merge(header.named, line.named))
    return Layer(header.transformation ⨟ line.transformation, header.data, positional, named)
end
inherit(header::Layer, line::Layers) = Layers([inherit(header, layer) for layer in line.layers])
inherit(header::Layer, line::Union{Fit,Aggregate}) = inherit(header, transformation(line))
inherit(::Layer, line::Result) = drawable(line)

# A fit or an aggregate is a step of a layer, as built-in analyses are: `mapping(...) * fit(...) *
# visual(Lines)`.
Base.:*(layer::AbstractAlgebraic, step::Union{Fit,Aggregate}) = layer * transformation(step)
Base.:*(step::Union{Fit,Aggregate}, layer::AbstractAlgebraic) = transformation(step) * layer

# The steps of a layer's transformation, in the order they apply.
steps(transformation::ComposedFunction) = [steps(transformation.inner); steps(transformation.outer)]
steps(transformation) = transformation === identity ? Any[] : Any[transformation]

# Default evaluation hook for an `Analysis`. Packages such as DataBrowserPlots specialize this
# on item selections to evaluate analyses as cached workspace computations.
evaluate_analysis(analysis, columns, _) = analysis(columns)

# A layer whose first step is a fit or an aggregate: its result over the layer's points, drawn by the
# steps after it. `items` are the items whose ids the points' table holds. The result takes the
# points inside the limits of the x and y scales in `axes`, and the function of the y scale, such as
# `log10`. A layer with several values of y draws them as one y. Other layers stay as they are.
resolve(::Union{Nothing,Bool}, _, _, _=nothing) = nothing
function resolve(layer::Layer, items, axes, points=nothing)
    split = split_y_scales(layer, items, axes, points)
    split === nothing || return split
    named = Pair{Symbol,Any}[role => value for (role, value) in pairs(layer.named)]
    found = steps(layer.transformation)
    computes(step) = step isa Union{Fit,Aggregate}
    if !any(computes, found)
        layer.data isa Columns || return layer
        table, positional, named = one_y(layer.data.columns, layer.positional, named)
        stacked = mapping(positional...; named...)
        return Layer(layer.transformation, Columns(table), stacked.positional, stacked.named)
    end
    computes(first(found)) && count(computes, found) == 1 ||
        error("A fit or an aggregate takes the points of its line before any visual, as in `fit(...) * visual(Lines)`")
    layer.data isa Columns || error("A fit or an aggregate needs points: a mapping of x and y, such as mapping(:x, :y)")
    analysis = Analysis(first(found), layer.positional, named, axes, points)
    result = points === nothing ? analysis(layer.data.columns) :
        evaluate_analysis(analysis, layer.data.columns, items)
    after = found[2:end]
    return isempty(after) ? result : result * Layer(; transformation=foldl(⨟, after))
end

function split_y_scales(layer::Layer, items, axes, points)
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
        piece = Layer(; layer.transformation, layer.data, positional, layer.named)
        settings = (; x=get(axes, :x, (;)), y=effective(role))
        push!(parts, role => resolve(piece, items, settings, points))
    end
    return YScaleLayers(parts)
end

Base.:+(a::YScaleLayers, b::YScaleLayers) = YScaleLayers([a.layers; b.layers])
Base.:+(a::YScaleLayers, b::Union{AbstractAlgebraic,Result}) = YScaleLayers([a.layers; :y => b])
Base.:+(a::Union{AbstractAlgebraic,Result}, b::YScaleLayers) = YScaleLayers([:y => a; b.layers])

with_scale_limits(::Union{Nothing,Bool}, _, _) = nothing
function with_scale_limits(layers::YScaleLayers, limits, yscales)
    YScaleLayers([role => retransformed(drawable(layer), t -> t ∘ WithinLimits(
        Any[limits[1], get(get(yscales, role, yscales[:y]), :limits, nothing)])) for (role, layer) in layers.layers])
end
with_scale_limits(layer, limits, _) = any(!isnothing, limits) ?
    retransformed(drawable(layer), t -> t ∘ WithinLimits(limits)) : layer

# A fit or an aggregate of a layer's points, with what it needs to compute again: the values the
# layer maps, the settings of its axes, and the code of its points.
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
        low, high = something(first(limits), -Inf), something(last(limits), Inf)
        value = positional[position]
        inside .&= [v isa Real && low <= v <= high for v in category.(Ref(value), columns[column(value)])]
    end
    isempty(inside) || any(inside) || error("The limits of the axes remove every point: " * join(
        ("$r = $(setting(analysis, r, :limits, nothing))" for r in (:x, :y) if setting(analysis, r, :limits, nothing) !== nothing), ", "))
    return map(values -> values[inside], columns), positional, named
end

# The result of the analysis over the points of `columns`.
function (analysis::Analysis)(columns)::Result
    table, positional, named = taken(analysis, columns)
    return Result(analysis.step, table, positional, named; scale=setting(analysis, :y, :scale, identity))
end

# The title of a value of `mapping`: the title after `=>`, as in `:I => "V > 0"` and
# `:I => abs => "V < 0"`, or the column's name.
title(value) = !(value isa Pair) ? string(column(value)) : last(value) isa AbstractString ? last(value) :
    last(value) isa Pair && last(last(value)) isa AbstractString ? last(last(value)) : string(column(value))

# The points of a layer with several values of y, as `y` and `y2` give, as points of one y: a row
# for each point and each value, with the value in the column `y` and its title in the column
# `ydims`, which the roles that `ydims()` maps take, in the order of the values and without a title
# in the legend. A layer with one y stays as it is.
function one_y(table, positional::Vector, named::Vector)
    length(positional) == 2 && positional[2] isa AbstractVector || return table, positional, named
    columns = Tables.columntable(table)
    ys = positional[2]
    repeated = [name => reduce(vcat, [columns[name] for _ in ys]) for name in keys(columns)]
    count = length(first(columns))
    stacked = (; repeated..., y=reduce(vcat, [category.(Ref(v), columns[column(v)]) for v in ys]),
        ydims=reduce(vcat, [fill(title(v), count) for v in ys]))
    order = sorter(unique(title.(ys))...)
    named = [role => (column(value) isa DimsSelector ? :ydims => order => "" : value) for (role, value) in named]
    return stacked, [positional[1], :y => ""], named
end
resolve(layers::Layers, items, axes, points=nothing) = foldl(+, (resolve(layer, items, axes, points) for layer in layers.layers))

# A line that reads the values of a result, drawn over its groups: `table` holds the values the
# line's mapping reads, one row for each group, and the line takes the roles of the result's points,
# such as `color`, so that it shares their legend entries. A line with `y` and no `x` takes the x of
# the result's points, as `mapping(y = result.mean)`.
function over_result(result::Result, table, layer)
    named = getfield(result, :named)
    groups = getfield(result, :groups)
    roles = [column(value) => [group[column(value)] for group in groups] for (_, value) in named]
    x = first(getfield(result, :positional))
    xs = haskey(table, column(x)) ? [] : [column(x) => [group[column(x)] for group in groups]]
    with_x(l) = first(l.positional, 1) == [nothing] ? Layer(l.transformation, l.data, [x; l.positional[2:end]], l.named) : l
    scale = getfield(result, :scale)
    is_computed(name) = any(n -> occursin(Regex("^\\(?:?\\Q$n\\E\\)?(\\[.*\\])?\$"), string(name)), getfield(result, :scaled))
    back = unscaled(scale)
    placed = Dict{Symbol,Any}()
    function on_axis(l)
        bars = any(v -> v isa Visual && v.plottype <: Makie.Errorbars, steps(l.transformation))
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
        return Layer(l.transformation, l.data, reduce(vcat, positions; init=Any[]), l.named)
    end
    layer = layer isa Layers ? Layers(map(on_axis ∘ with_x, layer.layers)) : on_axis(with_x(layer))
    return data((; pairs(table)..., roles..., xs..., pairs(placed)...)) * mapping(; named...) * layer
end

# A result without a visual is drawn with its own.
drawable(result::Result) = result * visual(getproperty(Makie, getfield(result, :plottype)))
# A layer with `y` and no `x`, as in `mapping(; y=:gap) * visual(Hist)`, draws its values against
# the vertical axis: a plot type with a `direction` setting, such as `Hist`, `BarPlot` or `Density`,
# turns to it unless a `visual` sets `direction` already, and other plot types draw the values
# against their index.
function drawable(layer::Layer)
    first(layer.positional, 1) == [nothing] && length(layer.positional) == 2 || return layer
    visuals = filter(step -> step isa Visual, steps(layer.transformation))
    turns = any(v -> :direction in Makie.attribute_names(v.plottype), visuals) &&
        !any(v -> haskey(v.attributes, :direction), visuals)
    layer = Layer(layer.transformation, layer.data, layer.positional[2:2], layer.named)
    return turns ? layer * visual(; direction=:x) : layer
end
drawable(layers::Layers) = Layers(map(drawable, layers.layers))
drawable(layers::YScaleLayers) = reduce(+, [drawable(layer) for (_, layer) in layers.layers])
drawable(layers) = layers

Base.:+(a::Result, b::Union{Result,AbstractAlgebraic}) = drawable(a) + drawable(b)
Base.:+(a::AbstractAlgebraic, b::Result) = a + drawable(b)

figure(result::Result, args...; options...) = figure(drawable(result), args...; options...)
spec(result::Result, args...; options...) = spec(drawable(result), args...; options...)
