import CImGui as ig
import CImGui.CSyntax: @c

using DataBrowserAPI: kind_label, label
import DataBrowserCore.Workspace

"""Draw the information panel: the type, the source item and the metadata of the selected value."""
function render_info_window(state::BrowserState)::Nothing
    workspace = state.workspace
    selected = _visible_selection(state).ids
    if ig.Begin("Information Panel")
        if length(selected) == 1
            x = only(selected)
            ## The metadata that the project's functions and the visualizers receive: that of the
            ## value, and the computed metadata.
            metadata = Workspace.metadata(workspace, x)
            ig.Text("Title: $(label(workspace, x))")
            ig.Separator()
            kind = _kind(workspace, x)
            kind === nothing || ig.BulletText("Type: $(kind_label(workspace.project, kind))")
            ig.BulletText("Source item: $(Workspace.source_item_id(workspace, x))")
            ig.Separator()
            if !isempty(metadata)
                ig.Text("Metadata")
                for k in sort!(collect(keys(metadata)); by=String)
                    ig.BulletText("$(k) = $(metadata[k])")
                end
            else
                ig.TextDisabled("No metadata")
            end
        elseif isempty(selected)
            ig.TextDisabled("Select an item to view details")
        else
            ig.TextDisabled("Select a single item to view details")
        end
    end
    ig.End()
    return nothing
end

"""Ask before discarding an old generated cache whose schema cannot be opened."""
function render_cache_rebuild_modal(state::BrowserState)::Nothing
    state.cache_rebuild_modal || return nothing

    center = ig.ImGuiViewport_GetCenter(ig.GetMainViewport())
    ig.SetNextWindowPos(center, ig.ImGuiCond_Always, (0.5, 0.5))
    ig.OpenPopup("Cache Rebuild Required")

    opened = state.cache_rebuild_modal
    if @c ig.BeginPopupModal("Cache Rebuild Required", &opened, ig.ImGuiWindowFlags_AlwaysAutoResize)
        ig.TextWrapped("This project cache was made by an older DataBrowser schema.")
        ig.TextWrapped(
            "The workspace is already open without disk persistence. Source data is safe; only " *
            "the generated cache file would be discarded.",
        )
        ig.Separator()
        ig.TextWrapped(state.cache_rebuild_error)
        ig.Spacing()

        if ig.Button("Continue without disk cache")
            opened = false
            state.cache_rebuild_error = ""
            ig.CloseCurrentPopup()
        end
        ig.SameLine()
        if ig.Button("Discard cache and rebuild")
            opened = false
            state.cache_rebuild_modal = false
            state.cache_rebuild_error = ""
            ig.CloseCurrentPopup()
            ## In another task, as for the Rebuild Cache button.
            errormonitor(Threads.@spawn Workspace.modify_workspace!(state.workspace; rebuild=true))
        end
        ig.EndPopup()
    end
    state.cache_rebuild_modal = opened
    return nothing
end
