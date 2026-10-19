import CImGui as ig
import CImGui.CSyntax: @c

using DataBrowserAPI: Setting, draw_header!, export!, id, label, settings
import DataBrowserCore.Workspace

"""
Draw the header that every window has: a menu to change the visualizer, a menu to change the
input, and "Live", which makes the window follow the selection.
"""
function _render_window_header!(state::BrowserState, window::Window)::Nothing
    if ig.BeginCombo("##visualizer", label(window.visualizer), ig.ImGuiComboFlags_WidthFitPreview)
        for candidate in visualizers(typeof(window.value))
            current = typeof(candidate) === typeof(window.visualizer)
            ig.Selectable(label(candidate), current) && !current && visualizer!(window, candidate)
        end
        ig.EndCombo()
    end

    ig.SameLine()
    ig.AlignTextToFramePadding()
    ig.TextDisabled("from")
    ig.SameLine()
    input = window.input
    # TODO: two windows that show the same items with the same visualizer have the same name here.
    # Let the user name a window.
    name(other) = "$(label(other.visualizer)): $(title(state, other))"
    preview = input isa WindowOutput ? name(source(input, state)) : "Selection"
    # As wide as the name, up to a limit: the names of several items must not take the whole row.
    ig.SetNextItemWidth(min(ig.CalcTextSize(preview).x + 2 * ig.GetFrameHeight(), 220.0f0))
    if ig.BeginCombo("##input", preview)
        ig.Selectable("Selection", !(input isa WindowOutput)) && input isa WindowOutput &&
            input!(state, window, LiveSelection())
        for other in state.windows
            (other === window || follows(state, other, window)) && continue
            current = input isa WindowOutput && input.window == other.id
            ig.Selectable("$(name(other))###$(other.id)", current) && !current &&
                input!(state, window, WindowOutput(other.id))
        end
        ig.EndCombo()
    end
    ig.SetItemTooltip("Where the window takes its value from: the selection, or another window.")

    ig.SameLine()
    ig.AlignTextToFramePadding()
    ig.TextDisabled("through")
    ig.SameLine()
    through = window.transform === nothing ? "nothing" : String(window.transform.name)
    if ig.BeginCombo("##transform", through, ig.ImGuiComboFlags_WidthFitPreview)
        ig.Selectable("nothing", window.transform === nothing) && transform!(window, nothing)
        for ref in transforms()
            ig.Selectable(String(ref.name), ref == window.transform) && transform!(window, ref)
        end
        ig.EndCombo()
    end
    ig.SetItemTooltip("A function of the project that the value passes through before it is shown.")

    # TODO: "Live" for the output of another window: when off, keep the value the window has now.
    window.input isa WindowOutput && return nothing
    ig.SameLine()
    live = window.input isa LiveSelection
    if @c ig.Checkbox("Live", &live)
        if live
            input!(state, window, LiveSelection())
        else
            # Keep the items the window shows now.
            workspace = state.workspace::Workspace.Workspace
            ids = [id(workspace, item) for item in itemkeys(window.input, state)]
            input!(state, window, FixedItems(ids))
        end
    end
    ig.SetItemTooltip("Follow the selection. When off, the window keeps the items it shows now.")
    return nothing
end

# How the user changes one setting. The type of the field decides: a `Bool` is a checkmark and a
# `String` is a menu. Each method draws the control and returns the value the user chose, which is
# `current` when the user changed nothing.
function _render_setting!(setting::Setting, current::Bool)::Bool
    chosen = current
    @c ig.Checkbox(setting.label, &chosen)
    return chosen
end

function _render_setting!(setting::Setting, current::String)::String
    chosen = current
    if ig.BeginCombo("##$(setting.label)", current, ig.ImGuiComboFlags_WidthFitPreview)
        for option in setting.options
            ig.Selectable(option, option == current) && (chosen = option)
        end
        ig.EndCombo()
    end
    ig.SetItemTooltip(setting.label)
    return chosen
end

"""
Draw the settings the visualizer declared, in the row of the header, and apply what the user
changes.
"""
function _render_window_settings!(window::Window)::Nothing
    # TODO: start a new row when the window is too narrow for the next setting.
    for (name, setting) in pairs(settings(window.visualizer))
        ig.SameLine()
        current = getproperty(window.visualizer, name)
        chosen = _render_setting!(setting, current)
        chosen == current || setting!(window, name, chosen)
    end
    return nothing
end

"""
Draw "Export", which every window has, and save what the window shows when the user clicks it.
"""
function _render_export_button!(window::Window, ctx::WindowContext)::Nothing
    clicked = ig.Button("Export")
    ig.SetItemTooltip("Save what the window shows")
    try
        clicked && export!(window.visualizer, ctx)
        # The picture of the window, when the default of `export!` asked for one in the last frame.
        save_window_picture!(window.id)
        clicked && (window.export_error = "")
    catch err
        summary = first(split(sprint(showerror, err), '\n'; limit=2))
        window.export_error = "Export failed: $summary. See the console for full details."
        @error("Export failed", exception=(err, catch_backtrace()))
    end
    return nothing
end

"""
Draw every window that shows a value with a visualizer, and remove those the user closed. A window
that is not visible, for example behind another tab, is not brought up to date.
"""
function render_windows!(state::BrowserState)::Nothing
    state.workspace isa Workspace.Workspace || return nothing
    # The plots drawn with ImPlot need its context.
    _init_implot_context!(state)
    for window in copy(state.windows)
        open = Ref(true)
        ig.SetNextWindowSize((900, 600), ig.ImGuiCond_FirstUseEver)
        # ImGui knows the window by the part after "###", so the title can change.
        if ig.Begin("$(title(state, window))###$(window.id)", open)
            refresh!(state, window)
            ctx = WindowContext(window.id, state.workspace)
            # TODO: catch an error of `draw_header!` and `draw!` and show it in the window. ImGui
            # must first be brought back to the state it had before the call.
            _render_window_header!(state, window)
            _render_window_settings!(window)
            ig.SameLine()
            _render_export_button!(window, ctx)
            # A group is one item of the row, also when the visualizer draws no button.
            ig.SameLine()
            ig.BeginGroup()
            draw_header!(window.visualizer, ctx)
            ig.EndGroup()
            ig.Separator()
            isempty(window.export_error) || ig.TextWrapped(window.export_error)
            measure_window_picture!(window.id)
            if isempty(window.error)
                draw!(window.visualizer, ctx)
            else
                ig.TextWrapped(window.error)
            end
        end
        ig.End()
        open[] || close_window!(state, window)
    end
    return nothing
end
