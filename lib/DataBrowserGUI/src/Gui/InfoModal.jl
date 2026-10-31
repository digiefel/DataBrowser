import CImGui as ig
import CImGui.CSyntax: @c

using DataBrowserAPI: kind_label, label
import DataBrowserCore.Workspace

"""Draw the information panel: the metadata of the selected collection and of the selected item."""
function render_info_window(state::BrowserState)::Nothing
    workspace = state.workspace
    selected_collections, selected_items, selected_path = _project_visible_selection(state)
    flags = ig.ImGuiTableFlags_Borders | ig.ImGuiTableFlags_RowBg | ig.ImGuiTableFlags_ScrollY
    if ig.Begin("Information Panel") && ig.BeginTable("info_cols", 2, flags)
        ig.TableSetupColumn("Collection")
        ig.TableSetupColumn("Item")
        ig.TableHeadersRow()
        ig.TableNextRow()
        ig.TableNextColumn()

        if length(selected_collections) == 1
            collection = only(selected_collections)
            ig.Text("Location: $(join(selected_path, "/"))")
            ig.Separator()
            metadata = Workspace.metadata(workspace, collection)
            if !isempty(metadata)
                ig.Text("Collection metadata")
                for k in sort!(collect(keys(metadata)); by=String)
                    ig.BulletText("$(k): $(metadata[k])")
                end
            else
                ig.TextDisabled("No collection metadata found")
            end
        elseif isempty(selected_collections)
            ig.TextDisabled("Select a collection to see details")
        else
            ig.TextDisabled("Select a single collection to see details")
        end

        ig.TableNextColumn()
        if length(selected_items) == 1
            item = only(selected_items)
            # The metadata that the project's functions and the visualizers receive: that of the
            # collections above, of the item, and the computed metadata.
            metadata = Workspace.metadata(workspace, item)
            ig.Text("Title: $(label(workspace, item))")
            ig.Separator()
            ig.BulletText("Type: $(kind_label(workspace.project, label(Workspace.valuetype(workspace, item))))")
            source = Workspace.source_item_id(workspace, item)
            source === nothing || ig.BulletText("Source item: $source")
            ig.Separator()
            if !isempty(metadata)
                ig.Text("Metadata")
                for k in sort!(collect(keys(metadata)); by=String)
                    ig.BulletText("$(k) = $(metadata[k])")
                end
            else
                ig.TextDisabled("No metadata")
            end
        elseif isempty(selected_items)
            ig.TextDisabled("Select an item to view details")
        else
            ig.TextDisabled("Select a single item to view details")
        end
        ig.EndTable()
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
            Workspace.modify_workspace!(state.workspace; rebuild=true)
        end
        ig.EndPopup()
    end
    state.cache_rebuild_modal = opened
    return nothing
end
