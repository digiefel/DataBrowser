import CImGui as ig
import CImGui.CSyntax: @c

using DataBrowserAPI: Setting, id, label
import DataBrowserCore.Workspace

"""
Draw the header that every window has: a menu to change the visualizer, and "Live", which makes
the window follow the selection.
"""
function _render_window_header!(state::BrowserState, window::Window)::Nothing
    if ig.BeginCombo("##visualizer", label(window.visualizer), ig.ImGuiComboFlags_WidthFitPreview)
        for candidate in visualizers(typeof(window.value))
            current = typeof(candidate) === typeof(window.visualizer)
            if ig.Selectable(label(candidate), current) && !current
                window.visualizer = candidate
                # The new visualizer is given the value in the next frame.
                window.stamp = nothing
            end
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

# How the user changes one setting. The type of the field decides: a `Bool` is a checkmark. Each
# method draws the control and returns the value the user chose, which is `current` when the user
# changed nothing.
function _render_setting!(setting::Setting, current::Bool)::Bool
    chosen = current
    @c ig.Checkbox(setting.label, &chosen)
    return chosen
end

"""Draw the settings the visualizer declared, in one row, and apply what the user changes."""
function _render_window_settings!(window::Window)::Nothing
    for (i, (name, setting)) in enumerate(pairs(window.settings))
        i > 1 && ig.SameLine()
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
            _render_window_header!(state, window)
            _render_window_settings!(window)
            ig.Separator()
            if isempty(window.error)
                # TODO: catch an error of `draw!` and show it in the window. ImGui must first be
                # brought back to the state it had before the call.
                draw!(window.visualizer, DrawContext(window.id))
            else
                ig.TextWrapped(window.error)
            end
        end
        ig.End()
        open[] || close_window!(state, window)
    end
    return nothing
end
