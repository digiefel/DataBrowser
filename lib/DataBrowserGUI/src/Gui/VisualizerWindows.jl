import CImGui as ig
import CImGui.CSyntax: @c

using DataBrowserAPI: Setting, draw_header!, id, label, settings
import DataBrowserCore.Workspace

"""
Draw the header that every window has: a menu to change the visualizer, and "Live", which makes
the window follow the selection.
"""
function _render_window_header!(state::BrowserState, window::Window)::Nothing
    if ig.BeginCombo("##visualizer", label(window.visualizer), ig.ImGuiComboFlags_WidthFitPreview)
        for candidate in visualizers(typeof(window.value))
            current = typeof(candidate) === typeof(window.visualizer)
            ig.Selectable(label(candidate), current) && !current && visualizer!(window, candidate)
        end
        ig.EndCombo()
    end

    # TODO: a menu to choose the input, once an input can be something other than items.
    ig.SameLine()
    live = window.input isa LiveSelection
    if @c ig.Checkbox("Live", &live)
        if live
            window.input = LiveSelection()
        else
            # Keep the items the window shows now.
            workspace = state.workspace::Workspace.Workspace
            window.input = FixedItems([id(workspace, item) for item in itemkeys(window.input, state)])
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
Draw every window that shows a value with a visualizer, and remove those the user closed. A window
that is not visible, for example behind another tab, is not brought up to date.
"""
function render_windows!(state::BrowserState)::Nothing
    state.workspace isa Workspace.Workspace || return nothing
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
            # A group is one item of the row, also when the visualizer draws no button.
            ig.SameLine()
            ig.BeginGroup()
            draw_header!(window.visualizer, ctx)
            ig.EndGroup()
            ig.Separator()
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
