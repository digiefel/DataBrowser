# The panel of the plot builder: the mapping of `@plot`, a card for each layer, the scales, the
# legend and the theme.

# The analyses a layer can choose without typing a Julia expression.
const ANALYSES = ["expectation()", "histogram()", "frequency()", "density()", "linear()", "smooth()"]
# The plot types the menu of a new layer offers.
const PLOT_TYPES = ["Scatter", "Lines", "ScatterLines", "BarPlot", "Errorbars", "Band", "Text"]
# The mappings whose scale `scales(...)` sets.
const SCALED = [:x, :y, :color, :marker, :linestyle, :markersize, :linewidth, :layout, :row, :col]
# The settings the menu of a scale offers: those of an axis for x and y, and those of a scale of
# categories, such as the markers of `marker`, for the other mappings.
# A scale of numbers offers those of its mapping, such as the `colormap` of `color`. A scale not
# drawn yet offers both kinds.
const AXIS_SETTINGS = [:label, :scale, :limits, :reversed, :ticks, :tickformat, :position]
const CATEGORY_SETTINGS = [:label, :palette, :categories, :legend]
const NUMBER_SETTINGS = Dict(:color => [:label, :legend, :colormap, :colorrange, :scale, :lowclip, :highclip, :nan_color],
    :markersize => [:label, :legend, :sizerange, :ticks, :tickformat], :linewidth => [:label, :legend, :sizerange, :ticks, :tickformat])
# What a setting of `legend` or of a scale changes, shown by the info button beside it.
const LEGEND_INFO = Dict(
    :merge => "The mappings that share a section, such as (:color, :linestyle), or true for all of them.",
)
const SCALE_INFO = Dict(
    :scale => "The scale function applies before the analyses run, and can change their results.",
    :limits => "The values outside the limits are removed before the analyses run, and can change their results.",
)
# The figure-wide settings of a theme that the menu of `theme` offers, and the blocks it has groups
# for; it also has a group for each plot type.
const THEME_SETTINGS = [:backgroundcolor, :textcolor, :font, :fontsize, :figure_padding, :rowgap, :colgap,
    :palette, :colormap, :linecolor, :linestyle, :linewidth, :marker, :markercolor, :markersize,
    :markerstrokecolor, :markerstrokewidth, :patchcolor, :patchstrokecolor, :patchstrokewidth]
const THEME_BLOCKS = [:Axis, :Legend, :Colorbar]
# The settings of a group that change what the plot shows, not how it looks, which the menus of a
# theme leave out: `scales` and `visual` set them. `:plots` are those of every plot type.
const NOT_STYLE = Dict(
    :Axis => [:xlabel, :ylabel, :title, :subtitle, :xscale, :yscale, :limits, :xreversed, :yreversed,
        :xticks, :yticks, :xtickformat, :ytickformat],
    :Hist => [:bins, :normalization], :Density => [:bandwidth], :BarPlot => [:direction],
    :plots => [:colorrange, :colorscale])

# The columns a mapping can pick: the selection's metadata, such as `:Wafer`, and the columns of
# its first item's data, such as `:data.V`.
# TODO: the columns of every item's data, read in the background.
# TODO: a column whose name is not an identifier, written as `var"..."`.
function columns(view::BuilderView)::Vector{ListItem}
    view.columns === nothing || return view.columns
    selection = view.selection
    metadata = selection === nothing ? Symbol[] : setdiff(propertynames(selection), [:id, :label, :data])
    data = selection === nothing || isempty(selection) ? Symbol[] : propertynames(first(selection.data))
    view.columns = [[ListItem(String(name); section="Metadata") for name in metadata];
        [ListItem("data.$name"; section="Data") for name in data]]
    return view.columns
end

# A row of the panel: the name of a value, in a column `name_width` wide, and its value, colored as
# code. A click on the value edits it; a marker or a line style of `visual` opens a menu of them,
# each drawn as it looks, and a column of a mapping a menu of the columns. The value is only framed
# when it is `inherited` from the header or `unused` by every drawn layer, and struck through when
# the line's plot type `skipped` it. While the mouse is on the row of a `removable` value, a cross
# before its name removes it. `label` is the name shown. `info` adds an info button with that text.
# Returns the change of the code the user asked for, as a function of no arguments, or `nothing`.
function draw_entry!(view::BuilderView, target, name, value::String; name_width::Float32, inherited::Bool=false,
        unused::Bool=false, skipped::Bool=false, removable::Bool=!inherited, info=nothing,
        label::String=entry_name(name))::Union{Nothing,Function}
    change = nothing
    ig.PushID("$target/$name")
    ig.AlignTextToFramePadding()
    # The room of the cross, which every row keeps so that the names line up.
    row = ig.GetCursorScreenPos()
    gutter = ig.CalcTextSize(ICON_X).x + 6
    if removable && ig.IsMouseHoveringRect(row, (row.x + ig.GetContentRegionAvail().x, row.y + ig.GetFrameHeight()))
        ig.PushStyleVar(ig.ImGuiStyleVar_FramePadding, (2.0f0, unsafe_load(ig.GetStyle()).FramePadding.y))
        call = target_call(view.plot, target)
        written = call !== nothing && any(entry -> entry.name == name, call.entries)
        # A value being added is not in the code yet.
        icon_button(ICON_X, "Remove $(entry_name(name))"; danger=true) &&
            (written ? (change = () -> remove_entry!(view.code, call, name)) : (view.editing = nothing))
        ig.PopStyleVar()
        ig.SameLine(0.0f0, 0.0f0)
    end
    ig.SetCursorScreenPos((row.x + gutter, ig.GetCursorScreenPos().y))
    start = ig.GetCursorPosX()
    label_width = with_font(() -> ig.CalcTextSize(label).x, :code)
    with_font(() -> ig.TextDisabled(label), :code)
    if info !== nothing
        ig.SameLine(0.0f0, 2.0f0)
        ig.TextDisabled(ICON_INFO)
        ig.SetItemTooltip(info)
    end
    # A name longer than the others, such as one being added, pushes its value to the right.
    label_width + unsafe_load(ig.GetStyle()).ItemSpacing.x > name_width ? ig.SameLine() : ig.SameLine(start + name_width)
    edit = view.editing
    editing = edit !== nothing && edit.target == target && edit.name == name
    # A mapping is a column, picked from a menu, or a formula, typed as code. A setting with a
    # widget, such as `limits`, is set with it, or typed as code when its code is more than the
    # widget writes. The badge before either shows which: ƒ for code, otherwise the kind of value
    # the widget writes. A click on it switches.
    mapping = target[1] === :mapping
    parts = mapping && !isempty(value) ? mapping_parts(value) : nothing
    widget = widget_of(view, target, name)
    fields = widget === nothing ? nothing : widget_parts(widget, editing ? unsafe_string(pointer(edit.buffer)) : value)
    formula = editing ? edit.typed : mapping ? parts !== nothing && any(((kind, _),) -> kind === :formula, parts) : fields === nothing
    pick_column = false
    if mapping || widget !== nothing
        icon, role, kind = formula ? ("ƒ", :keyword, "code") : mapping ? (ICON_COLUMN, :symbol, "a column") : badge(widget)
        size = ig.GetFrameHeight()
        switched = ig.InvisibleButton("badge", (size, size))
        low, high = ig.GetItemRectMin(), ig.GetItemRectMax()
        draw_list = ig.GetWindowDrawList()
        ig.AddRectFilled(draw_list, low, high, ig.GetColorU32(code_color(role, ig.IsItemHovered() ? 0.4f0 : 0.2f0)),
            unsafe_load(ig.GetStyle()).FrameRounding, ig.ImDrawFlags_RoundLeft)
        with_font(() -> draw_icon(draw_list, low, high, icon, ig.GetColorU32(code_color(role))), formula ? :code : :interface)
        ig.SetItemTooltip(mapping ? (formula ? "A formula; click to pick a column instead" : "A column; click to write a formula instead") :
            formula ? "Code; click to set the value with the widget" : "Sets $kind; click to write the value as code")
        # The badge is part of the value: the value starts where it ends.
        ig.SameLine(0.0f0, 0.0f0)
        if switched && editing
            edit.typed = !edit.typed
            edit.focus = true
        elseif switched && widget !== nothing
            start_edit!(view, target, name, formula ? "" : value; typed=!formula)
        elseif switched
            formula ? (pick_column = true) : start_edit!(view, target, name, value)
        end
    end
    if widget !== nothing && !formula
        # The parts of a widget of several parts sit on one frame, joined to the badge, in a lighter
        # tint than theirs. The frame has room around them, and they are shorter by as much, so the
        # row is as tall as any other.
        style = unsafe_load(ig.GetStyle())
        drawn = something(fields, widget_parts(widget, ""))
        text = if !framed(widget)
            draw_widget!(view, widget, target, name, drawn, editing && edit.focus)
        else
            room = min(2.0f0, style.FramePadding.y)
            ig.PushStyleVar(ig.ImGuiStyleVar_WindowPadding, (room, room))
            ig.BeginChild("widget", (0.0f0, 0.0f0), ig.ImGuiChildFlags_AutoResizeY | ig.ImGuiChildFlags_AlwaysUseWindowPadding,
                ig.ImGuiWindowFlags_NoScrollbar)
            ig.PopStyleVar()
            ig.PushStyleVar(ig.ImGuiStyleVar_FramePadding, (style.FramePadding.x, style.FramePadding.y - room))
            written = draw_widget!(view, widget, target, name, drawn, editing && edit.focus)
            ig.PopStyleVar()
            ig.EndChild()
            ig.AddRectFilled(ig.GetWindowDrawList(), ig.GetItemRectMin(), ig.GetItemRectMax(), ig.GetColorU32(ig.ImGuiCol_FrameBg, 0.4f0),
                style.FrameRounding, ig.ImDrawFlags_RoundRight)
            written
        end
        editing && (edit.focus = false)
        if text !== nothing
            editing && (view.editing = nothing)
            change = () -> write_entry!(view.code, view.plot, target, name, text)
        end
    elseif editing && !edit.typed
        # A mapping being added: an empty box with the menu of columns open.
        clicked, _, _ = code_box("value", "", max(ig.GetContentRegionAvail().x, 24.0f0))
        (edit.focus || clicked) && (pick_column = true)
        edit.focus = false
    elseif editing
        text = draw_field!(view)
        text === nothing || (change = () -> write_entry!(view.code, view.plot, target, name, text))
    elseif value in ("true", "false")
        checked = Ref(value == "true")
        ig.Checkbox("##value", checked) && (change = () -> write_entry!(view.code, view.plot, target, name, string(checked[])))
    else
        style = unsafe_load(ig.GetStyle())
        dimmed = inherited || unused || skipped
        clicked, hovered, clipped = code_box("value", value, max(ig.GetContentRegionAvail().x, 24.0f0); dimmed, parts)
        low, high = ig.GetItemRectMin(), ig.GetItemRectMax()
        if skipped
            middle = round((low.y + high.y) / 2)
            ig.AddLine(ig.GetWindowDrawList(), (low.x + style.FramePadding.x, middle),
                (high.x - style.FramePadding.x, middle), ig.GetColorU32(ig.ImGuiCol_TextDisabled))
        end
        status = skipped ? "The plot type of this layer does not show $(entry_name(name))" :
            unused ? "No drawn layer shows $(entry_name(name))" :
            inherited ? "From the plot's mapping; click to give this layer its own" : nothing
        whole = clipped || formula || occursin('\n', value)
        if hovered && (whole || status !== nothing)
            ig.BeginTooltip()
            whole && with_font(() -> code_text(value), :code)
            status === nothing || ig.TextDisabled(status)
            ig.EndTooltip()
        end
        if clicked && mapping && !formula
            pick_column = true
        elseif clicked
            start_edit!(view, target, name, value; typed=true)
        end
    end
    if mapping
        if pick_column
            view.picker = ListPicker()
            ig.OpenPopup("names")
        end
        # With several values of y, a named mapping can also show which of them a point shows.
        calls = filter(!isnothing, [view.plot.mapping; [line.mapping for line in view.plot.lines]])
        several = !is_position(name) && any(call -> any(entry -> mapping_order(entry.name)[1] == 1, call.entries), calls)
        offered = several ? [columns(view); ListItem("ydims()"; section="y, y2, …")] : columns(view)
        column = names_menu(view, offered)
        if column !== nothing
            # The column replaces the formula; the title after `=>` stays.
            title = parts === nothing ? nothing : findfirst(((kind, _),) -> kind === :title, parts)
            text = (column == "ydims()" ? column : ":$column") * (title === nothing ? "" : " => $(repr(parts[title][2]))")
            change = () -> write_entry!(view.code, view.plot, target, name, text)
        end
    end
    ig.PopID()
    return change
end

# The menu of an analysis tag: the analyses to choose and, for an analysis the layer has, a field
# for its expression and its removal. Returns the changes to the code that the user picked.
function analysis_menu!(view::BuilderView, layer::Int, index::Int; adding::Bool=false)::Vector{Function}
    changes = Function[]
    for choice in ANALYSES
        if ig.Selectable(String(first(split(choice, '('))))
            push!(changes, () -> set_analysis!(view.code, layer, choice; index))
            ig.CloseCurrentPopup()
        end
    end
    adding && return changes
    parts = analysis_factors(view.code, view.plot.lines[layer])
    analyses = filter(part -> !any(name -> is_call(part, name), ("mapping", "visual", "data")), parts)
    index <= length(analyses) || return changes
    ig.Separator()
    source = String(sourcetext(analyses[index]))
    edited = part_field!(view, "analysis_expression", source, max(ig.GetContentRegionAvail().x, 240.0f0);
        hint="Analysis expression", tooltip="Edit the analysis and its arguments")
    edited === nothing || isempty(edited) || push!(changes,
        () -> set_analysis!(view.code, layer, edited; index))
    if ig.Selectable("Remove analysis")
        push!(changes, () -> set_analysis!(view.code, layer, nothing; index))
        ig.CloseCurrentPopup()
    end
    return changes
end

# A layer, as a card: a band with a button that folds it, its eye, its plot type, the names of its analyses and a picture of
# its marker and line, and under it, when open, its `mapping` and `visual`. `takes(line, name)`
# tells whether the line takes a mapping from the header, and `names` are the mappings it can show,
# or `nothing` when unknown. Returns the changes of the code the user asked for.
function draw_layer!(view::BuilderView, index::Int, takes, names)::Vector{Function}
    plot = view.plot
    line = plot.lines[index]
    text(range) = view.code.text[range]
    entries(call) = call === nothing ? EntryCode[] : call.entries
    changes = Function[]
    offer(change) = change === nothing || push!(changes, change)
    adding(target, present) = (edit = view.editing; edit !== nothing && edit.target == target &&
        all(entry -> entry.name != edit.name, present))
    style = unsafe_load(ig.GetStyle())

    # The band's items go on the upper of two layers of the draw list; the band goes under them once
    # their height is known.
    draw_list = ig.GetWindowDrawList()
    ig.ChannelsSplit(draw_list, 2)
    ig.ChannelsSetCurrent(draw_list, 1)
    band = ig.GetCursorScreenPos()
    right = band.x + ig.GetContentRegionAvail().x
    ig.PushStyleVar(ig.ImGuiStyleVar_ItemSpacing, (4.0f0, 2.0f0))
    ig.PushStyleVar(ig.ImGuiStyleVar_FramePadding, (3.0f0, style.FramePadding.y))
    hidden = line.invisible !== nothing
    alpha = hidden ? 0.45f0 : 1.0f0
    ig.AlignTextToFramePadding()
    # Whether the layer shows its `mapping` and `visual`, which ImGui keeps from frame to frame.
    storage, key = ig.GetStateStorage(), ig.GetID("open")
    opened = ig.GetBool(storage, key, true)
    icon_button(opened ? ICON_CHEVRON_DOWN : ICON_CHEVRON_RIGHT, opened ? "Fold the layer" : "Unfold the layer") &&
        ig.SetBool(storage, key, !opened)
    ig.SameLine()
    if icon_button(hidden ? ICON_EYE_OFF : ICON_EYE, hidden ? "Draw the layer" : "Hide the layer, keeping its line")
        # `@invisible` keeps the line in the plot without drawing it.
        start = first(line.range)
        push!(changes, hidden ? () -> edit!(view.code, line.invisible, "") : () -> edit!(view.code, start:start-1, "@invisible "))
    end
    visual = entries(line.visual)
    value(name) = (found = findfirst(entry -> entry.name == name, visual); found === nothing ? nothing : text(visual[found].value))
    plottype = value(1)
    ig.SameLine()
    sample_x = ig.GetCursorPosX()
    draw_sample(plottype, written_symbol(something(value(:marker), "")), written_symbol(something(value(:linestyle), "")), alpha)
    if line.name !== nothing
        ig.SameLine()
        with_font(() -> ig.TextDisabled("$(line.name) ="), :code)
    end
    ig.SameLine()
    if ig.SmallButton(something(plottype, "Plot type") * "##type")
        ig.OpenPopup("visual_type")
    end
    ig.SetItemTooltip("Change the plot type of the layer")
    if ig.BeginPopup("visual_type")
        for type in PLOT_TYPES
            ig.Selectable(type, type == plottype) && push!(changes,
                () -> write_entry!(view.code, plot, (:visual, index), 1, type))
        end
        ig.EndPopup()
    end
    # The tags, on more rows under the picture when they do not fit before the room of the cross.
    for (k, analysis) in enumerate(line.analyses)
        width = with_font(() -> ig.CalcTextSize(analysis).x, :code) + 8
        ig.GetItemRectMax().x + 4 + width > right - 2ig.GetFrameHeight() ? ig.SetCursorPosX(sample_x) : ig.SameLine()
        ig.PushID("analysis$k")
        draw_tag(analysis, alpha) && ig.OpenPopup("analysis")
        ig.SetItemTooltip("Change this analysis or edit its arguments")
        if ig.BeginPopup("analysis")
            append!(changes, analysis_menu!(view, index, k))
            ig.EndPopup()
        end
        ig.PopID()
    end
    ig.SameLine()
    icon_button("+", "Add an analysis") && ig.OpenPopup("add_analysis")
    if ig.BeginPopup("add_analysis")
        append!(changes, analysis_menu!(view, index, length(line.analyses)+1; adding=true))
        ig.EndPopup()
    end
    ig.PopStyleVar(2)
    band_end = (right, ig.GetItemRectMax().y)
    if ig.IsMouseHoveringRect(band, band_end)
        after = ig.GetCursorScreenPos()
        ig.SetCursorScreenPos((right - ig.GetFrameHeight(), band.y))
        icon_button(ICON_X, "Remove the layer"; danger=true) && push!(changes, () -> remove_line!(view.code, line))
        # ImGui asks for an item after the cursor moves back: an empty one where the last item
        # ends, so the cursor lands where it was.
        ig.SetCursorScreenPos((after.x, after.y - style.ItemSpacing.y))
        ig.Dummy((0.0f0, 0.0f0))
    end
    ig.ChannelsSetCurrent(draw_list, 0)
    ig.AddRectFilled(draw_list, band, band_end, ig.GetColorU32(ig.ImGuiCol_Header, 0.45f0), style.FrameRounding)
    ig.ChannelsMerge(draw_list)

    if opened
        ig.Indent(style.FramePadding.x + 4)
        # The line's own mappings, and those it takes from the header: positions first, in order,
        # then the named ones.
        own = entries(line.mapping)
        rows = [[(entry, true) for entry in entries(plot.mapping) if takes(line, entry.name)]; [(entry, false) for entry in own]]
        sort!(rows; by=((entry, _),) -> mapping_order(entry.name))
        named_visual = [entry for entry in visual if entry.name isa Symbol]

        type = plottype === nothing || !isdefined(Makie, Symbol(plottype)) ? nothing : getproperty(Makie, Symbol(plottype))
        attributes = type isa Type && type <: Makie.AbstractPlot ? collect(Makie.attribute_names(type)) : Symbol[]
        # The mappings the layer showed when it was last drawn; before, the settings of its plot type.
        # TODO: mappings of a named line, such as the groups of a fit.
        offered = mapping_offers([entry.name for entry in own], something(names, union(attributes, LAYOUT)))
        name = heading!(view, "mapping", "mapping", offered; tooltip="Add a mapping to this layer")
        name === nothing || start_edit!(view, (:mapping, index), entry_key(name), ""; typed=false)
        width = names_width([entry.name for (entry, _) in rows])
        for (entry, inherited) in rows
            skipped = inherited && names !== nothing && !is_position(entry.name) && !(entry.name in names)
            offer(draw_entry!(view, (:mapping, index), entry.name, text(entry.value); name_width=width, inherited, skipped))
        end
        # A mapping taken from the header is edited in its own row.
        adding((:mapping, index), first.(rows)) && offer(draw_entry!(view, (:mapping, index), view.editing.name, ""; name_width=width))

        ig.Dummy((0.0f0, 2.0f0))
        offered = sort(String.(setdiff(attributes, [entry.name for entry in visual])))
        name = heading!(view, "visual", "visual", offered; tooltip="Add a setting of the plot type")
        name === nothing || start_edit!(view, (:visual, index), Symbol(name), "")
        width = names_width([entry.name for entry in named_visual])
        for entry in named_visual
            offer(draw_entry!(view, (:visual, index), entry.name, text(entry.value); name_width=width))
        end
        adding((:visual, index), visual) && offer(draw_entry!(view, (:visual, index), view.editing.name, ""; name_width=width))
        ig.Unindent(style.FramePadding.x + 4)
    end
    # The frame of the card, around its band and what is under it.
    bottom = ig.GetCursorScreenPos().y
    opened && ig.AddRect(ig.GetWindowDrawList(), band, (band_end[1], bottom), ig.GetColorU32(ig.ImGuiCol_Header, 0.6f0), style.FrameRounding)
    return changes
end

# The mapping of `@plot`, its layers and its scales. A change writes the code, as "Save" does.
function draw_panel!(view::BuilderView, ctx)::Nothing
    if view.parsed != view.code.text
        view.plot = tryparse(PlotCode, view.code)
        view.parsed = view.code.text
    end
    plot = view.plot
    if plot === nothing
        ig.TextDisabled("The code has no @plot.")
        return nothing
    end
    text(range) = view.code.text[range]
    entries(call) = call === nothing ? EntryCode[] : call.entries
    header = entries(plot.mapping)
    # A line takes a mapping of the header that it does not set itself; a position of the line
    # replaces all of the header's positions.
    takes(line, name) = line.inherits && all(entry -> entry.name != name, entries(line.mapping)) &&
        !(is_position(name) && any(entry -> is_position(entry.name), entries(line.mapping)))
    # The mappings each line can show, as the last drawing found them; a named line is not drawn.
    drawn_lines = [index for (index, line) in enumerate(plot.lines) if line.name === nothing]
    known = length(drawn_lines) == length(view.mappings)
    shown(index) = known && index in drawn_lines ? view.mappings[findfirst(==(index), drawn_lines)] : nothing
    unused(name) = known && !is_position(name) && !any(drawn_lines) do index
        line = plot.lines[index]
        line.invisible === nothing && takes(line, name) && name in shown(index)
    end
    # The changes the user asked for in this frame; the first one is made.
    changes = Function[]
    offer(change) = change === nothing || push!(changes, change)
    adding(target, present) = (edit = view.editing; edit !== nothing && edit.target == target &&
        all(entry -> entry.name != edit.name, present))
    ig.PushStyleVar(ig.ImGuiStyleVar_ItemSpacing, (6.0f0, 4.0f0))

    if plot.mapping !== nothing
        section("mapping") do
            names = known ? union(view.mappings..., LAYOUT) : LAYOUT
            offered = mapping_offers([entry.name for entry in header], names)
            name = heading!(view, "mapping", "mapping", offered; tooltip="Add a mapping to every layer")
            name === nothing || start_edit!(view, (:mapping, 0), entry_key(name), ""; typed=false)
            width = names_width([entry.name for entry in header])
            for entry in header
                offer(draw_entry!(view, (:mapping, 0), entry.name, text(entry.value); name_width=width,
                    unused=unused(entry.name)))
            end
            adding((:mapping, 0), header) && offer(draw_entry!(view, (:mapping, 0), view.editing.name, ""; name_width=width))
        end
    end

    section("layers") do
        type = heading!(view, "layers", "Layers", PLOT_TYPES; role=:interface, tooltip="Add a layer")
        type === nothing || push!(changes, () -> add_layer!(view.code, Symbol(type)))
        for index in eachindex(plot.lines)
            ig.PushID(index)
            index > 1 && ig.Dummy((0.0f0, 4.0f0))
            append!(changes, draw_layer!(view, index, takes, shown(index)))
            ig.PopID()
        end
    end

    if plot.ending !== nothing
        section("scales") do
            scales = entries(plot.scales)
            # The scales of the mappings the plot has, which `scales` can set.
            used = [entry_name(entry.name) for call in [plot.mapping; [line.mapping for line in plot.lines]] for entry in entries(call)]
            names = union(String.(SCALED), filter(name -> DataBrowserPlots.is_y_scale(Symbol(name)), used))
            offered = filter(name -> name in used && !any(scale -> entry_name(scale.name) == name, scales), names)
            name = heading!(view, "scales", "scales", offered; tooltip="Add the scale of a mapping")
            name === nothing || push!(changes, () -> write_entry!(view.code, plot, (:scales, 0), Symbol(name), "(;)"))
            # The names of the settings of every scale and, after some, an info button.
            present_names = [entry.name for settings in plot.scale_settings if settings !== nothing for entry in settings.entries]
            width = names_width(present_names) + ig.CalcTextSize(ICON_INFO).x + 2
            for (k, scale) in enumerate(scales)
                ig.PushID(k)
                settings = plot.scale_settings[k]
                present = settings === nothing ? EntryCode[] : settings.entries
                # The scale's name, with a "+" for its settings and, under the mouse, a cross.
                row = ig.GetCursorScreenPos()
                row_end = (row.x + ig.GetContentRegionAvail().x, row.y + ig.GetFrameHeight())
                numbers = get(NUMBER_SETTINGS, scale.name, Symbol[])
                kind = get(view.scale_kinds, scale.name, nothing)
                settable = if scale.name === :x
                    setdiff(AXIS_SETTINGS, [:position])
                elseif DataBrowserPlots.is_y_scale(scale.name)
                    AXIS_SETTINGS
                elseif kind === :categorical
                    CATEGORY_SETTINGS
                elseif kind === :continuous
                    numbers
                else
                    union(CATEGORY_SETTINGS, numbers)
                end
                offered = settings === nothing ? String[] : String.(setdiff(settable, [entry.name for entry in present]))
                picked = heading!(view, "scale", entry_name(scale.name), offered; role=:plain, tooltip="Add a setting of this scale")
                picked === nothing || start_edit!(view, (:scale, k), Symbol(picked), "")
                if ig.IsMouseHoveringRect(row, row_end)
                    ig.SameLine(ig.GetWindowWidth() - unsafe_load(ig.GetStyle()).WindowPadding.x - 2ig.GetFrameHeight() - 4)
                    icon_button(ICON_X, "Remove the scale of $(entry_name(scale.name))"; danger=true) &&
                        push!(changes, () -> remove_entry!(view.code, plot.scales, scale.name))
                end
                ig.Indent(8.0f0)
                if settings === nothing
                    # A scale written as other code than a named tuple is edited as code.
                    offer(draw_entry!(view, (:scales, 0), scale.name, text(scale.value); name_width=width, removable=false))
                else
                    for setting in present
                        offer(draw_entry!(view, (:scale, k), setting.name, text(setting.value); name_width=width,
                            info=get(SCALE_INFO, setting.name, nothing)))
                    end
                    adding((:scale, k), present) && offer(draw_entry!(view, (:scale, k), view.editing.name, ""; name_width=width))
                end
                ig.Unindent(8.0f0)
                ig.PopID()
            end
        end
        section("legend") do
            settings = entries(plot.legend)
            # The texts of the entries of the mappings the plot has, then the settings of `figure`'s
            # legend, then those of Makie's `Legend`.
            used = unique(entry.name for call in [plot.mapping; [line.mapping for line in plot.lines]]
                for entry in entries(call) if entry.name isa Symbol && !(entry.name in LAYOUT))
            present = [entry.name for entry in settings]
            offered = [String.(setdiff(used, present)); String.(setdiff([:show, :position, :merge], present));
                sort(String.(setdiff(collect(Makie.attribute_names(Makie.Legend)), present)))]
            name = heading!(view, "legend", "legend", offered; tooltip="Add a setting of the legend")
            name === nothing || start_edit!(view, (:legend, 0), Symbol(name), "")
            width = names_width(present)
            for setting in settings
                offer(draw_entry!(view, (:legend, 0), setting.name, text(setting.value); name_width=width,
                    info=get(LEGEND_INFO, setting.name, nothing)))
            end
            adding((:legend, 0), settings) && offer(draw_entry!(view, (:legend, 0), view.editing.name, ""; name_width=width))
        end
        section("theme") do
            values = entries(plot.theme)
            present = [entry.name for entry in values]
            # Makie's themes as the code names them, then the figure-wide settings, then the groups.
            setting_icon(name) = occursin("color", name) || name in ("palette", "colormap") ? ICON_PALETTE :
                occursin("font", name) ? ICON_TEXT : ICON_SETTING
            offered = [
                (1 in present ? ListItem[] : [ListItem(":$t"; section="Makie themes", icon=ICON_THEME) for t in THEMES]);
                [ListItem(name; section="Figure", icon=setting_icon(name)) for name in String.(setdiff(THEME_SETTINGS, present))];
                [ListItem(name; section="Blocks", icon=ICON_BLOCK) for name in String.(setdiff(THEME_BLOCKS, present))];
                [ListItem(name; section="Plot types", icon=ICON_PLOT) for name in setdiff(PLOT_TYPES, [String(name) for name in present if name isa Symbol])]]
            name = heading!(view, "theme", "theme", offered; tooltip="Add a setting of the theme")
            if name !== nothing && startswith(name, ':')
                push!(changes, () -> write_entry!(view.code, plot, (:theme, 0), 1, name))
            elseif name !== nothing && (Symbol(name) in THEME_BLOCKS || name in PLOT_TYPES)
                push!(changes, () -> write_entry!(view.code, plot, (:theme, 0), Symbol(name), "(;)"))
            elseif name !== nothing
                start_edit!(view, (:theme, 0), Symbol(name), "")
            end
            width = names_width([entry.name for entry in values if entry.name isa Symbol])
            for (k, value) in enumerate(values)
                ig.PushID(k)
                group = plot.theme_groups[k]
                if value.name isa Int
                    offer(draw_entry!(view, (:theme, 0), value.name, text(value.value); name_width=width, label=""))
                elseif group === nothing
                    offer(draw_entry!(view, (:theme, 0), value.name, text(value.value); name_width=width))
                else
                    # A group, such as `Axis = (; ...)`: its name with a "+" for its settings and,
                    # under the mouse, a cross, then its settings.
                    row = ig.GetCursorScreenPos()
                    row_end = (row.x + ig.GetContentRegionAvail().x, row.y + ig.GetFrameHeight())
                    type = isdefined(Makie, value.name) ? getproperty(Makie, value.name) : nothing
                    names = type isa Type ? collect(Makie.attribute_names(type)) : Symbol[]
                    names = setdiff(names, get(NOT_STYLE, value.name, Symbol[]), NOT_STYLE[:plots], [entry.name for entry in group.entries])
                    picked = heading!(view, "group", String(value.name), sort(String.(names)); role=:plain,
                        tooltip="Add a setting of every $(value.name)")
                    picked === nothing || start_edit!(view, (:group, k), Symbol(picked), "")
                    if ig.IsMouseHoveringRect(row, row_end)
                        ig.SameLine(ig.GetWindowWidth() - unsafe_load(ig.GetStyle()).WindowPadding.x - 2ig.GetFrameHeight() - 4)
                        icon_button(ICON_X, "Remove $(value.name)"; danger=true) &&
                            push!(changes, () -> remove_entry!(view.code, plot.theme, value.name))
                    end
                    ig.Indent(8.0f0)
                    inner = names_width([entry.name for entry in group.entries])
                    for setting in group.entries
                        offer(draw_entry!(view, (:group, k), setting.name, text(setting.value); name_width=inner))
                    end
                    adding((:group, k), group.entries) && offer(draw_entry!(view, (:group, k), view.editing.name, ""; name_width=inner))
                    ig.Unindent(8.0f0)
                end
                ig.PopID()
            end
            adding((:theme, 0), values) && offer(draw_entry!(view, (:theme, 0), view.editing.name, ""; name_width=width))
        end
    end
    ig.PopStyleVar()

    if !isempty(changes)
        first(changes)()
        view.editing = nothing
        set_code!(view, view.code.text)
        # A new id for the text box, which shows the edited code.
        view.reads += 1
        save_and_build!(view, ctx)
    end
    return nothing
end
