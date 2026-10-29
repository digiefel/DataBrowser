import CImGui as ig
import CImGui.CSyntax: @c

using DataBrowserAPI: Setting, draw_header!, export!, id, initial_size, label, settings
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

# How the user changes one setting. Bool is a checkmark; Int and Float64 are numeric inputs;
# String is a menu or a text field. Each method returns the chosen value, or `current` when the
# user changed nothing.
function _render_setting!(setting::Setting, current::Bool)::Bool
    chosen = current
    @c ig.Checkbox(setting.label, &chosen)
    return chosen
end

function _render_setting!(setting::Setting, current::Int)::Int
    chosen, step, fast = Ref(current), Ref(1), Ref(16)
    datatype = sizeof(Int) == 8 ? ig.ImGuiDataType_S64 : ig.ImGuiDataType_S32
    format = sizeof(Int) == 8 ? "%lld" : "%d"
    ig.SetNextItemWidth(ig.GetFontSize() * 8)
    ig.InputScalar(setting.label, datatype, chosen, step, fast, format,
        ig.ImGuiInputTextFlags_EnterReturnsTrue)
    return chosen[]
end

function _render_setting!(setting::Setting, current::Float64)::Float64
    chosen = Ref(current)
    ig.SetNextItemWidth(ig.GetFontSize() * 7)
    ig.InputDouble(setting.label, chosen, 0, 0, "%.6g", ig.ImGuiInputTextFlags_EnterReturnsTrue)
    return chosen[]
end

function _render_setting!(setting::Setting, current::String)::String
    chosen = current
    # Without options, the user types the text, and the label shows while it is empty. ImGui keeps
    # the text while the user types, and it becomes the setting at Enter.
    if isempty(setting.options)
        buffer = zeros(UInt8, max(sizeof(current) + 256, 1024))
        copyto!(buffer, codeunits(current))
        ig.SetNextItemWidth(ig.GetFontSize() * 12)
        if ig.InputTextWithHint("##$(setting.label)", setting.label, buffer, length(buffer),
                ig.ImGuiInputTextFlags_EnterReturnsTrue)
            chosen = unsafe_string(pointer(buffer))
        end
        ig.SetItemTooltip(setting.label)
        return chosen
    end
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
        setting.visible || continue
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
        if clicked
            if window.arrangement == "grid"
                invoke(export!, Tuple{DataBrowserAPI.AbstractVisualizer,Any}, window.visualizer, ctx)
            else
                export!(window.visualizer, ctx)
            end
        end
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
        window.initial_size_pending && ig.SetNextWindowDockID(0, ig.ImGuiCond_Always)
        condition = window.initial_size_pending ? ig.ImGuiCond_Always : ig.ImGuiCond_FirstUseEver
        ig.SetNextWindowSize(initial_size(window.visualizer), condition)
        window.initial_size_pending = false
        # ImGui knows the window by the part after "###", so the title can change.
        if ig.Begin("$(title(state, window))###$(window.id)", open)
            ctx = WindowContext(state, window)
            # An error of the visualizer, or of the code it runs, leaves the rest of the window and
            # the browser working; the window shows the error where the drawing stopped.
            window.draw_error = guarded_draw("Window: $(label(window.visualizer)) failed to draw", window.draw_error) do
                _render_window_header!(state, window)
                _render_arrangement!(state, window)
                _render_window_settings!(window)
                # After the menus, which may change the visualizer, the input or a setting, so that
                # the visualizer has its value before it draws in this frame.
                refresh!(state, window)
                ig.SameLine()
                _render_export_button!(window, ctx)
                # A group is one item of the row, also when the visualizer draws no button.
                ig.SameLine()
                ig.BeginGroup()
                before = Dict(name => getproperty(window.visualizer, name) for name in keys(settings(window.visualizer)))
                draw_header!(window.visualizer, ctx)
                for (name, value) in before
                    chosen = getproperty(window.visualizer, name)
                    isequal(value, chosen) || setting!(window, name, chosen)
                end
                refresh!(state, window)
                _sync_cell_settings!(window)
                ig.EndGroup()
                ig.Separator()
                isempty(window.export_error) || ig.TextWrapped(window.export_error)
                isempty(window.waiting) || ig.TextDisabled("Loading")
                isempty(window.failed) || ig.TextWrapped("Failed:\n" * window.failed)
                measure_window_picture!(window.id)
                if isempty(window.error)
                    _draw_presentations!(state, window)
                else
                    ig.TextWrapped(window.error)
                end
            end
            isempty(window.draw_error) || ig.TextWrapped(window.draw_error)
        end
        ig.End()
        open[] || close_window!(state, window)
    end
    return nothing
end
