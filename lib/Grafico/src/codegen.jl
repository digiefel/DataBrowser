function _format_mapping_entry(m::MappingEntry)::String
    s = "$(m.role) = $(m.value_expr)"
    if m.transform_expr !== nothing && m.label !== nothing
        return "$s => $(m.transform_expr) => $(repr(m.label))"
    elseif m.transform_expr !== nothing
        return "$s => $(m.transform_expr)"
    elseif m.label !== nothing
        return "$s => $(repr(m.label))"
    end
    return s
end

function _format_mapping_call(entries::Vector{MappingEntry})::String
    isempty(entries) && return ""
    return "mapping(" * join([_format_mapping_entry(m) for m in entries], ", ") * ")"
end

function _format_visual_call(plottype_expr::AbstractString, visual_kwargs::Dict{Symbol,EntryValue})::String
    isempty(plottype_expr) && isempty(visual_kwargs) && return ""
    kw_parts = ["$k = $(visual_kwargs[k].expr_text)" for k in sort!(collect(keys(visual_kwargs)))]
    if !isempty(plottype_expr) && !isempty(kw_parts)
        return "visual($plottype_expr; $(join(kw_parts, ", ")))"
    elseif !isempty(plottype_expr)
        return "visual($plottype_expr)"
    else
        return "visual(; $(join(kw_parts, ", ")))"
    end
end

function _format_layer_expr(
    data_expr::Union{Nothing,String},
    mapping_entries::Vector{MappingEntry},
    analysis_expr::Union{Nothing,String},
    plottype_expr::AbstractString,
    visual_kwargs::Dict{Symbol,EntryValue},
)::String
    parts = String[]
    data_expr === nothing || push!(parts, "data($data_expr)")
    isempty(mapping_entries) || push!(parts, _format_mapping_call(mapping_entries))
    (analysis_expr === nothing || isempty(strip(analysis_expr))) || push!(parts, strip(analysis_expr))
    vcall = _format_visual_call(plottype_expr, visual_kwargs)
    isempty(vcall) || push!(parts, vcall)
    return isempty(parts) ? "nothing" : join(parts, " * ")
end

function _format_scales_line(scales_dict::Dict{Symbol,Dict{Symbol,EntryValue}})::String
    parts = String[]
    for role in sort!(collect(keys(scales_dict)))
        inner = scales_dict[role]
        if length(inner) == 1 && haskey(inner, :value)
            push!(parts, "$role = $(inner[:value].expr_text)")
        else
            sub = ["$k = $(inner[k].expr_text)" for k in sort!(collect(keys(inner)))]
            push!(parts, "$role = (; $(join(sub, ", ")))")
        end
    end
    return "scales(" * join(parts, ", ") * ")"
end

function _format_coord_line(step::Dict{Symbol,Any})::String
    pos = String[]
    kws = String[]
    haskey(step, :points) && push!(pos, step[:points].expr_text)
    for k in sort!(collect(keys(step)))
        k === :points && continue
        v = step[k]
        if v isa Dict{Symbol,EntryValue}
            sub = ["$sk = $(v[sk].expr_text)" for sk in sort!(collect(keys(v)))]
            push!(kws, "$k = (; $(join(sub, ", ")))")
        elseif v isa EntryValue
            push!(kws, "$k = $(v.expr_text)")
        end
    end
    if !isempty(pos) && !isempty(kws)
        return "coord($(join(pos, ", ")); $(join(kws, ", ")))"
    elseif !isempty(pos)
        return "coord($(join(pos, ", ")))"
    else
        return "coord($(join(kws, ", ")))"
    end
end

function _format_legend_line(legend_dict::Dict{Symbol,EntryValue})::String
    parts = ["$k = $(legend_dict[k].expr_text)" for k in sort!(collect(keys(legend_dict)))]
    return "legend(" * join(parts, ", ") * ")"
end

function _format_theme_line(th::ThemeSpec)::String
    pos = th.base === nothing ? String[] : String[":$(th.base)"]
    kws = ["$k = $(th.settings[k].expr_text)" for k in sort!(collect(keys(th.settings)))]
    if !isempty(pos) && !isempty(kws)
        return "theme($(pos[1]); $(join(kws, ", ")))"
    elseif !isempty(pos)
        return "theme($(pos[1]))"
    else
        return "theme($(join(kws, ", ")))"
    end
end

function _format_inspector_line(ins::InspectorSpec)::String
    ins.callback !== nothing && return "inspector($(nameof(ins.callback)))"
    if !ins.show && isempty(ins.fields) && ins.title === nothing && ins.show_coords && ins.digits == 4
        return "inspector(false)"
    end
    pos = String[":$f" for f in ins.fields]
    kws = String[]
    ins.show || push!(kws, "show = false")
    ins.title === nothing || push!(kws, "title = $(repr(ins.title))")
    ins.show_coords || push!(kws, "show_coords = false")
    ins.digits == 4 || push!(kws, "digits = $(ins.digits)")
    if !isempty(pos) && !isempty(kws)
        return "inspector($(join(pos, ", ")); $(join(kws, ", ")))"
    elseif !isempty(pos)
        return "inspector($(join(pos, ", ")))"
    elseif !isempty(kws)
        return "inspector($(join(kws, ", ")))"
    else
        return "inspector(true)"
    end
end

function _format_annotate_line(ann::AnnotationDoc)::String
    pos = String[":$(ann.kind)"]
    if ann.source_expr !== nothing
        push!(pos, ann.source_expr)
    elseif !isempty(ann.text) || ann.kind === :text
        push!(pos, repr(ann.text))
    end
    kws = ["$k = $(ann.kwargs[k].expr_text)" for k in sort!(collect(keys(ann.kwargs)))]
    line = isempty(kws) ? "annotate($(join(pos, ", ")))" : "annotate($(join(pos, ", ")); $(join(kws, ", ")))"
    return ann.visible ? line : "@invisible $line"
end

function _format_inset_line(ins::InsetDoc)::String
    kws = ["$k = $(ins.kwargs[k].expr_text)" for k in sort!(collect(keys(ins.kwargs)))]
    line = "inset(" * join(kws, ", ") * ")"
    return ins.visible ? line : "@invisible $line"
end

function _format_kv_call(name::String, dict::Dict{Symbol,EntryValue})::String
    parts = ["$k = $(dict[k].expr_text)" for k in sort!(collect(keys(dict)))]
    return "$name(" * join(parts, ", ") * ")"
end

"""
    to_code(plot; include_imports=false, include_figure=false) -> String

Generate standalone public Grafico source code for `plot` (a [`PlotDocument`](@ref),
[`EditablePlot`](@ref), `@plot` value, or `Figure`).
"""
function to_code(
    doc::PlotDocument;
    include_imports::Bool=false,
    include_figure::Bool=false,
)::String
    need_block = doc.has_block || !isempty(doc.layers) || !isempty(doc.scales) ||
        !isempty(doc.coords) || !isempty(doc.legend) || doc.theme !== nothing ||
        doc.inspector !== nothing || !isempty(doc.annotations) || !isempty(doc.insets) ||
        !isempty(doc.layout_settings) || !isempty(doc.colorbar)

    header_str = if need_block
        _format_layer_expr(doc.header_data_expr, doc.header_mapping, nothing, "", Dict{Symbol,EntryValue}())
    else
        _format_layer_expr(
            doc.header_data_expr,
            doc.header_mapping,
            doc.header_analysis_expr,
            doc.header_plottype_expr,
            doc.header_visual_kwargs,
        )
    end

    plot_code = if !need_block
        "@plot $header_str"
    else
        body = String[]
        for layer in doc.layers
            expr_str = _format_layer_expr(
                layer.data_expr,
                layer.mapping,
                layer.analysis_expr,
                layer.plottype_expr,
                layer.visual_kwargs,
            )
            line_str = layer.name === nothing ? expr_str : "$(layer.name) = $expr_str"
            if !layer.visible && !layer.is_statement_only
                line_str = "@invisible $line_str"
            end
            push!(body, "    $line_str")
        end
        isempty(doc.scales) || push!(body, "    $(_format_scales_line(doc.scales))")
        for step in doc.coords
            push!(body, "    $(_format_coord_line(step))")
        end
        isempty(doc.legend) || push!(body, "    $(_format_legend_line(doc.legend))")
        doc.theme === nothing || push!(body, "    $(_format_theme_line(doc.theme))")
        doc.inspector === nothing || push!(body, "    $(_format_inspector_line(doc.inspector))")
        for ann in doc.annotations
            push!(body, "    $(_format_annotate_line(ann))")
        end
        for ins in doc.insets
            push!(body, "    $(_format_inset_line(ins))")
        end
        isempty(doc.layout_settings) || push!(body, "    $(_format_kv_call("panel_layout", doc.layout_settings))")
        isempty(doc.colorbar) || push!(body, "    $(_format_kv_call("colorbar", doc.colorbar))")
        "@plot $header_str begin\n" * join(body, "\n") * "\nend"
    end

    lines = String[]
    include_imports && push!(lines, "using Makie, Grafico")
    if include_figure
        push!(lines, "plot = $plot_code")
        push!(lines, doc.header_data_expr === nothing ? "fig = figure(plot, data)" : "fig = figure(plot)")
    else
        push!(lines, plot_code)
    end
    return join(lines, "\n")
end

to_code(ep::EditablePlot; kwargs...) = to_code(ep.doc; kwargs...)
to_code(plot; kwargs...) = to_code(document(plot); kwargs...)
