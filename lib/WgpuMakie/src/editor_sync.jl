# Bi-directional synchronization between the Rust editor panel and Grafico `EditablePlot` or Makie scenes.

function _eval_wgpu_expr(expr_text::AbstractString)
    parsed = Meta.parse(expr_text)
    if parsed isa Symbol
        parsed === :nothing && return nothing
        parsed === :true && return true
        parsed === :false && return false
        isdefined(Makie, parsed) && return getfield(Makie, parsed)
        isdefined(Colors, parsed) && return getfield(Colors, parsed)
        isdefined(Base, parsed) && return getfield(Base, parsed)
    elseif parsed isa QuoteNode
        return parsed.value
    end
    return Base.invokelatest(Core.eval, Makie, parsed)
end

function _serialize_entry_value(ev)
    return Dict{String, Any}(
        "expr" => string(ev.expr_text),
        "is_literal" => Bool(ev.is_literal),
    )
end

function _serialize_mapping_entry(m)
    return Dict{String, Any}(
        "role" => string(m.role),
        "value_expr" => string(m.value_expr),
        "label" => m.label === nothing ? nothing : string(m.label),
        "transform_expr" => m.transform_expr === nothing ? nothing : string(m.transform_expr),
    )
end

function _serialize_coords(coords)
    out = Any[]
    for step in coords
        for k in sort!(collect(keys(step)); by = string)
            v = step[k]
            if k in (:x, :y) && v isa AbstractDict
                for sk in sort!(collect(keys(v)); by = string)
                    push!(out, Any[string(k, sk), _serialize_entry_value(v[sk])])
                end
            elseif hasproperty(v, :expr_text)
                push!(out, Any[string(k), _serialize_entry_value(v)])
            end
        end
    end
    return out
end

function _find_grafico_editable(screen::Screen)
    fig = screen.figure
    isnothing(fig) && return nothing
    haskey(fig.attributes, :_grafico_editable) || return nothing
    ep = fig.attributes[:_grafico_editable][]
    (ep !== nothing && hasproperty(ep, :doc) && hasproperty(ep, :compiled)) || return nothing
    return ep
end

function _build_editor_snapshot(screen::Screen; error::Union{Nothing, String} = screen.last_editor_error)
    ep = _find_grafico_editable(screen)
    if ep !== nothing
        G = parentmodule(typeof(ep))
        doc = ep.doc
        cols = String[]
        try
            cols = G.available_columns(ep)
        catch
        end
        layers = Any[]
        if !doc.has_block && isempty(doc.layers)
            vk = Any[
                Any[string(k), _serialize_entry_value(doc.header_visual_kwargs[k])]
                for k in sort!(collect(keys(doc.header_visual_kwargs)); by = string)
            ]
            push!(layers, Dict{String, Any}(
                "id" => UInt32(0),
                "name" => nothing,
                "visible" => true,
                "data_expr" => doc.header_data_expr,
                "mapping" => Any[],
                "analysis_expr" => doc.header_analysis_expr,
                "plottype_expr" => string(doc.header_plottype_expr),
                "visual_kwargs" => vk,
                "is_statement_only" => false,
            ))
        else
            for l in doc.layers
                vk = Any[
                    Any[string(k), _serialize_entry_value(l.visual_kwargs[k])]
                    for k in sort!(collect(keys(l.visual_kwargs)); by = string)
                ]
                push!(layers, Dict{String, Any}(
                    "id" => UInt32(l.id),
                    "name" => l.name === nothing ? nothing : string(l.name),
                    "visible" => Bool(l.visible),
                    "data_expr" => l.data_expr,
                    "mapping" => Any[_serialize_mapping_entry(m) for m in l.mapping],
                    "analysis_expr" => l.analysis_expr,
                    "plottype_expr" => string(l.plottype_expr),
                    "visual_kwargs" => vk,
                    "is_statement_only" => Bool(l.is_statement_only),
                ))
            end
        end
        scales_vec = Any[]
        for role in sort!(collect(keys(doc.scales)); by = string)
            inner = doc.scales[role]
            inner_vec = Any[
                Any[string(k), _serialize_entry_value(inner[k])]
                for k in sort!(collect(keys(inner)); by = string)
            ]
            push!(scales_vec, Any[string(role), inner_vec])
        end
        legend_vec = Any[
            Any[string(k), _serialize_entry_value(doc.legend[k])]
            for k in sort!(collect(keys(doc.legend)); by = string)
        ]
        theme_dict = if doc.theme === nothing
            nothing
        else
            Dict{String, Any}(
                "base" => doc.theme.base === nothing ? nothing : string(doc.theme.base),
                "settings" => Any[
                    Any[string(k), _serialize_entry_value(doc.theme.settings[k])]
                    for k in sort!(collect(keys(doc.theme.settings)); by = string)
                ],
            )
        end
        insp_dict = if doc.inspector === nothing
            nothing
        else
            ins = doc.inspector
            Dict{String, Any}(
                "show" => Bool(ins.show),
                "title" => ins.title,
                "fields" => String[string(f) for f in ins.fields],
                "show_coords" => Bool(ins.show_coords),
                "digits" => UInt32(ins.digits),
                "has_callback" => (ins.callback !== nothing),
            )
        end
        code = try
            G.to_code(ep; include_imports = screen.editor_include_imports, include_figure = screen.editor_include_figure)
        catch
            ""
        end
        return Dict{String, Any}(
            "revision" => UInt64(ep.revision),
            "has_grafico" => true,
            "available_columns" => cols,
            "header_data_expr" => doc.header_data_expr,
            "header_mapping" => Any[_serialize_mapping_entry(m) for m in doc.header_mapping],
            "layers" => layers,
            "scales" => scales_vec,
            "coords" => _serialize_coords(doc.coords),
            "legend" => legend_vec,
            "theme" => theme_dict,
            "inspector" => insp_dict,
            "code" => code,
            "error" => error,
        )
    end

    readonly_code = ""
    fig = screen.figure
    if !isnothing(fig) && haskey(fig.attributes, :_grafico_compilation)
        try
            comp = fig.attributes[:_grafico_compilation][]
            G = parentmodule(typeof(comp))
            readonly_code = G.to_code(fig; include_imports = screen.editor_include_imports, include_figure = screen.editor_include_figure)
        catch
        end
    end

    return Dict{String, Any}(
        "revision" => UInt64(0),
        "has_grafico" => false,
        "available_columns" => String[],
        "header_data_expr" => nothing,
        "header_mapping" => Any[],
        "layers" => Any[],
        "scales" => Any[],
        "coords" => Any[],
        "legend" => Any[],
        "theme" => nothing,
        "inspector" => nothing,
        "code" => readonly_code,
        "error" => error,
    )
end

"""
    sync_editor_state!(screen; error = screen.last_editor_error)

Push the current Grafico `PlotDocument` snapshot and generated code to the Rust viewer.
"""
function sync_editor_state!(screen::Screen; error::Union{Nothing, String} = screen.last_editor_error)
    (isnothing(screen.viewer) || !screen.open) && return nothing
    state = _build_editor_snapshot(screen; error)
    send_msg!(screen.viewer, Dict{String, Any}(
        "op" => "sync_editor_state",
        "state" => state,
    ))
    return nothing
end

function _attach_editor_observers!(screen::Screen)
    isempty(screen.editor_observers) || return nothing
    ep = _find_grafico_editable(screen)
    isnothing(ep) && return nothing
    weak_scr = WeakRef(screen)
    o = on(ep.compiled) do _
        scr = weak_scr.value
        scr === nothing && return
        scr.syncing_editor[] && return
        !scr.open && return
        _sync_figure_axes!(scr, scr.figure)
        flush_updates!(scr)
        sync_editor_state!(scr)
    end
    push!(screen.editor_observers, o)
    return nothing
end

function _handle_editor_command!(screen::Screen, cmd::AbstractDict)
    kind = string(get(cmd, "cmd", ""))
    if kind == "request_custom_tooltip"
        pid = UInt64(cmd["plot_id"])
        idx0 = UInt32(cmd["element_index"])
        pos = cmd["pos"]
        plt = get(screen.id_to_plot, pid, nothing)
        text = ""
        if !isnothing(plt) && haskey(plt, :inspector_label)
            fn = plt.inspector_label[]
            if fn !== Makie.automatic
                try
                    pt = GeometryBasics.Point3f(Float32(pos[1]), Float32(pos[2]), Float32(pos[3]))
                    text = string(fn(plt, Int(idx0) + 1, pt))
                catch
                end
            end
        end
        if !isempty(text) && !isnothing(screen.viewer) && screen.open
            send_msg!(screen.viewer, Dict{String, Any}(
                "op" => "inspector_tooltip_reply",
                "plot_id" => pid,
                "element_index" => idx0,
                "text" => text,
            ))
        end
        return nothing
    elseif kind == "request_code"
        screen.editor_include_imports = Bool(get(cmd, "include_imports", false))
        screen.editor_include_figure = Bool(get(cmd, "include_figure", false))
        snap = _build_editor_snapshot(screen)
        if !isnothing(screen.viewer) && screen.open
            send_msg!(screen.viewer, Dict{String, Any}(
                "op" => "code_export_reply",
                "code" => snap["code"],
                "include_imports" => screen.editor_include_imports,
                "include_figure" => screen.editor_include_figure,
            ))
        end
        return nothing
    end

    screen.syncing_editor[] = true
    try
        screen.last_editor_error = nothing
        if kind == "set_axis_attr"
            aid = UInt64(cmd["axis_id"])
            ax = get(screen.id_to_axis, aid, nothing)
            isnothing(ax) && return nothing
            key = Symbol(cmd["key"])
            val = _eval_wgpu_expr(string(cmd["expr"]))
            if key === :limits
                ax.limits[] = val
            else
                setproperty!(ax, key, val)
            end
            _sync_figure_axes!(screen, screen.figure)
            flush_updates!(screen)
            sync_editor_state!(screen)
            return nothing
        elseif kind == "set_plot_attr"
            pid = UInt64(cmd["plot_id"])
            plt = get(screen.id_to_plot, pid, nothing)
            isnothing(plt) && return nothing
            key = Symbol(cmd["key"])
            val = _eval_wgpu_expr(string(cmd["expr"]))
            setproperty!(plt, key, val)
            sc = Makie.parent_scene(plt)
            !isnothing(sc) && @lock screen.sync_lock push!(screen.dirty_plots, (sc, plt))
            flush_updates!(screen)
            sync_editor_state!(screen)
            return nothing
        end

        ep = _find_grafico_editable(screen)
        isnothing(ep) && return nothing
        G = parentmodule(typeof(ep))

        if kind == "set_visual"
            G.set_visual_expr!(ep, Int(cmd["layer_id"]), Symbol(cmd["key"]), string(cmd["expr"]))
        elseif kind == "remove_visual"
            G.remove_visual!(ep, Int(cmd["layer_id"]), Symbol(cmd["key"]))
        elseif kind == "set_layer_visible"
            G.set_layer_visible!(ep, Int(cmd["layer_id"]), Bool(cmd["visible"]))
        elseif kind == "set_layer_plottype"
            G.set_layer_plottype!(ep, Int(cmd["layer_id"]), string(cmd["plottype_expr"]))
        elseif kind == "add_layer"
            G.add_layer!(ep; plottype = string(cmd["plottype_expr"]))
        elseif kind == "remove_layer"
            G.remove_layer!(ep, Int(cmd["layer_id"]))
        elseif kind == "move_layer"
            G.move_layer!(ep, Int(cmd["layer_id"]), Int(cmd["delta"]))
        elseif kind == "set_mapping"
            lid = cmd["layer_id"] === nothing ? nothing : Int(cmd["layer_id"])
            G.set_mapping!(
                ep,
                lid,
                Symbol(cmd["role"]),
                string(cmd["value_expr"]);
                label = cmd["label"],
                transform = cmd["transform_expr"],
            )
        elseif kind == "remove_mapping"
            lid = cmd["layer_id"] === nothing ? nothing : Int(cmd["layer_id"])
            G.remove_mapping!(ep, lid, Symbol(cmd["role"]))
        elseif kind == "set_analysis"
            G.set_analysis!(ep, Int(cmd["layer_id"]), cmd["analysis_expr"])
        elseif kind == "set_scale"
            G.set_scale_expr!(ep, Symbol(cmd["role"]), Symbol(cmd["key"]), string(cmd["expr"]))
        elseif kind == "remove_scale"
            k = cmd["key"] === nothing ? nothing : Symbol(cmd["key"])
            G.remove_scale!(ep, Symbol(cmd["role"]), k)
        elseif kind == "set_coord"
            G.set_coord_expr!(ep, Symbol(cmd["key"]), string(cmd["expr"]))
        elseif kind == "set_legend"
            G.set_legend_expr!(ep, Symbol(cmd["key"]), string(cmd["expr"]))
        elseif kind == "remove_legend"
            G.remove_legend!(ep, Symbol(cmd["key"]))
        elseif kind == "set_theme"
            b = cmd["base"] === nothing ? nothing : Symbol(cmd["base"])
            k = cmd["key"] === nothing ? nothing : Symbol(cmd["key"])
            ex = cmd["expr"] === nothing ? nothing : string(cmd["expr"])
            G.set_theme_expr!(ep; base = b, key = k, expr_text = ex)
        elseif kind == "set_inspector"
            fields = Symbol[Symbol(f) for f in cmd["fields"]]
            spec = G.inspector(
                fields...;
                show = Bool(cmd["show"]),
                title = cmd["title"],
                show_coords = Bool(cmd["show_coords"]),
                digits = Int(cmd["digits"]),
            )
            G.set_inspector!(ep, spec)
        end

        _sync_figure_axes!(screen, screen.figure)
        flush_updates!(screen)
        sync_editor_state!(screen)
    catch err
        screen.last_editor_error = sprint(showerror, err)
        sync_editor_state!(screen; error = screen.last_editor_error)
    finally
        screen.syncing_editor[] = false
    end
    return nothing
end
