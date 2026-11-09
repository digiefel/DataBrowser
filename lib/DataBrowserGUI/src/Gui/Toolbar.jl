# The toolbar is the bar of menus along the top of the main window of the browser, the window named
# "Data Browser". The other windows of the browser dock in the room below it, and a window dragged
# out of the main window leaves the toolbar there. From left to right, the toolbar holds the status
# of the workspace, the "+ Window" menu that opens a window, the "Debug" menu, and the menus that
# extensions add with `menu!`.

import CImGui as ig

using DataBrowserAPI: label
using DataBrowserCache: ProjectCacheIdentity
import DataBrowserCore.Workspace
using DataBrowserCore.Workspace: can_rebuild_cache, rebuild_cache!

"""
Draw the toolbar. The browser draws it first in each frame, so that the other windows dock below it.
"""
function render_toolbar!(state::BrowserState)::Nothing
    ig.BeginMainMenuBar() || return nothing
    _render_cache_toolbar_button!(state)
    if ig.BeginMenu("+ Window")
        ## The visualizers that show a selection, in a list that the typed letters narrow. The list
        ## starts with nothing typed each time the menu opens.
        ig.IsWindowAppearing() && (state.window_picker = ListPicker())
        choices = visualizers(Workspace.Selection)
        picked = render_list_picker!(state.window_picker, [ListItem(label(choice)) for choice in choices])
        ## A window says so when its visualizer cannot show the value it is given.
        picked === nothing || (visualize!(state, choices[picked]); ig.CloseCurrentPopup())
        ig.EndMenu()
    end
    if ig.BeginMenu("Debug")
        if ig.MenuItem("Performance Window", C_NULL, state.show_performance_window)
            state.show_performance_window = !state.show_performance_window
        end
        ig.Separator()
        render_debug_tools_menu!(state)
        ig.EndMenu()
    end
    for ext in state.extensions
        menu!(ext, state)
    end
    ig.EndMainMenuBar()
    return nothing
end

# ## The status of the workspace
#
# The first item of the toolbar is a button that shows the status of the workspace, in the color of
# its level: blue while it works, green when every result is current. A click on it opens a popup
# with the source, the numbers of source items, items and processed items, the computations that
# failed, and a button that builds the cache again.

"""Brighten or darken an ImGui button color by `delta` per RGB channel, clamped to [0, 1]."""
shifted_color(color::NTuple{4,Float64}, delta::Real)::NTuple{4,Float64} =
    (clamp(color[1] + delta, 0, 1), clamp(color[2] + delta, 0, 1),
     clamp(color[3] + delta, 0, 1), color[4])

"""The color of the status button for the `level` of the status of the workspace."""
function status_color(level::Symbol)::NTuple{4,Float64}
    level === :busy && return (0.18, 0.42, 0.78, 1.0)
    level === :fresh && return (0.20, 0.58, 0.30, 1.0)
    level === :stale && return (0.78, 0.58, 0.12, 1.0)
    level === :missing && return (0.82, 0.48, 0.12, 1.0)
    level === :error && return (0.72, 0.18, 0.18, 1.0)
    return (0.34, 0.34, 0.34, 1.0)
end

"""Draw the status button, and its popup when it is open."""
function _render_cache_toolbar_button!(state::BrowserState)::Nothing
    status = Workspace.workspace_status(state.workspace)
    color = status_color(status.level)
    ig.PushStyleColor(ig.ImGuiCol_Button, color)
    ig.PushStyleColor(ig.ImGuiCol_ButtonHovered, shifted_color(color, 0.10))
    ig.PushStyleColor(ig.ImGuiCol_ButtonActive, shifted_color(color, -0.08))
    if ig.Button("Cache: $(status.label)")
        ig.OpenPopup("cache_toolbar_popup")
    end
    button_min = ig.GetItemRectMin()
    button_max = ig.GetItemRectMax()
    ig.PopStyleColor(3)
    if ig.BeginItemTooltip()
        ig.TextUnformatted(status.detail)
        ig.EndTooltip()
    end
    ig.SetNextWindowPos((button_min.x, button_max.y), ig.ImGuiCond_Always)
    ig.SetNextWindowSize((460, 0), ig.ImGuiCond_Always)
    if ig.BeginPopup("cache_toolbar_popup")
        _render_cache_controls!(state)
        ig.EndPopup()
    end
    return nothing
end

"""
Draw the popup of the status button: the source, the numbers of the workspace, its progress, the
computations that failed, and the button that builds the cache again.
"""
function _render_cache_controls!(state::BrowserState)::Nothing
    workspace = state.workspace
    status = Workspace.workspace_status(workspace)

    ## The source, or with the Alt key held, the cache file, and a button that copies its path.
    identity = workspace.cache.identity
    if identity isa ProjectCacheIdentity
        alt_held = unsafe_load(ig.GetIO().KeyAlt)
        name = alt_held ? "Cache" : "Source"
        path = alt_held ? identity.cache_path : identity.source_id
        ig.Text("$name: $(alt_held ? "DuckDB" : identity.source_label)")
        ig.SameLine()
        ig.SmallButton("$ICON_COPY##copy_$(lowercase(name))") && ig.SetClipboardText(String(path))
        if ig.BeginItemTooltip()
            ig.TextUnformatted(alt_held ? "Copy cache database path" : "Copy source path")
            ig.TextUnformatted(path)
            ig.EndTooltip()
        end
    end

    status.progress === nothing && ig.TextWrapped(status.detail)
    counts, issues = status.counts, length(status.errors)
    if ig.BeginTable("counts", 4, ig.ImGuiTableFlags_SizingStretchSame)
        ig.TableNextRow()
        _count_cell("$(counts.sources) Sources", ["$(counts.sources) source items found", "$(counts.read) read"])
        _count_cell("$(counts.items) items", ["$(counts.items) items created"])
        _count_cell("$(counts.processed) processed", ["$(counts.processed) processed"])
        _count_cell("$issues $(issues == 1 ? "issue" : "issues")", ["$issues computations failed"])
        ig.EndTable()
    end
    if status.progress !== nothing
        ig.ProgressBar(status.progress, (-1, 0))
        ig.TextWrapped(status.detail)
    end

    if !isempty(status.errors)
        ig.Separator()
        ig.TextColored((1.0, 0.35, 0.35, 1.0), "Cache Issues")
        ig.TextDisabled("Select an issue to show related items")
        ## The failures with the same first line of their message share one entry, and a click on
        ## it selects the items of all of them.
        ## TODO(scale): goes through every failure in each frame while the popup is open.
        entries = Pair{SubString{String},Vector{String}}[]
        positions = Dict{SubString{String},Int}()
        for (failed, message) in status.errors
            line = first(split(message, '\n'; limit=2))
            position = get!(() -> (push!(entries, line => String[]); length(entries)), positions, line)
            push!(last(entries[position]), failed)
        end
        shown = min(length(entries), 20)
        ig.BeginChild("##cache_errors", (0.0f0, 120.0f0), true)
        for index in 1:shown
            line, failed = entries[index]
            ig.PushID(index)
            link = length(failed) == 1 ? only(failed) : "$(first(failed)) and $(length(failed) - 1) more"
            if ig.TextLink(link) && select_failed!(state, failed)
                state.tree_filter = ""
                _reset_tree_filter!(state)
            end
            ig.TextWrapped(line)
            ig.PopID()
            index < shown && ig.Separator()
        end
        ig.EndChild()
        hidden = sum(entry -> length(last(entry)), entries[shown+1:end]; init=0)
        hidden > 0 && ig.TextDisabled("$hidden more failures")
    end

    ig.Separator()
    disabled = !can_rebuild_cache(workspace)
    disabled && ig.BeginDisabled()
    if ig.Button(status.level === :missing ? "Build Cache" : "Rebuild Cache", (-1, 0))
        ## In another task, which waits for the end of this frame: until the rebuild ends, each
        ## frame shows that the workspace is updating.
        errormonitor(Threads.@spawn rebuild_cache!(workspace))
    end
    disabled && ig.EndDisabled()
    return nothing
end

"""Draw one number of the popup, centered in its cell, with the lines of `tooltip` under the mouse."""
function _count_cell(text::AbstractString, tooltip::Vector{String})::Nothing
    ig.TableNextColumn()
    ig.SetCursorPosX(ig.GetCursorPosX() + max((ig.GetContentRegionAvail().x - ig.CalcTextSize(text).x) / 2, 0))
    ig.TextUnformatted(text)
    if ig.BeginItemTooltip()
        foreach(ig.TextUnformatted, tooltip)
        ig.EndTooltip()
    end
    return nothing
end
