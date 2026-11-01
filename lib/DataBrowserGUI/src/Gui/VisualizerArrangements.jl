"""
Draw the menu that arranges the items of a selection in the window: Stack, Grid or Overlay. In
Stack, the arrows beside it go through the items.
"""
function _render_arrangement!(state::BrowserState, window::Window)::Nothing
    value = window.value
    value isa Workspace.Selection || return nothing
    mode = window.arrangement == "auto" ? "stack" : window.arrangement
    if ig.BeginCombo("##arrangement", uppercasefirst(mode), ig.ImGuiComboFlags_WidthFitPreview)
        ctx = WindowContext(state, window)
        for candidate in ("stack", "grid", "overlay")
            candidate == "overlay" && !_can_overlay(window, ctx) && continue
            ig.Selectable(uppercasefirst(candidate), mode == candidate) && arrangement!(window, candidate)
        end
        ig.EndCombo()
    end
    # A dynamic call: the arrows are compiled for the type of this selection. Compiled for a `Selection`
    # of a type unknown to the compiler, they would make calls that methods of packages loaded later
    # invalidate.
    window.arrangement == "stack" && !isempty(value) && Base.invokelatest(_render_stack_arrows!, window, value)
    return nothing
end

# The arrows that go through the items of a stack, with the position and the label of the item shown.
function _render_stack_arrows!(window::Window, value::Workspace.Selection)::Nothing
    i = something(findfirst(==(window.active_item), value.id), 1)
    ig.SameLine()
    ig.BeginDisabled(i == 1)
    ig.ArrowButton("##previous-item", ig.ImGuiDir_Left) && active_item!(window, String(value.id[i-1]))
    ig.EndDisabled()
    ig.SameLine()
    ig.TextUnformatted("$i / $(length(value)): $(value.label[i])")
    ig.SameLine()
    ig.BeginDisabled(i == length(value))
    ig.ArrowButton("##next-item", ig.ImGuiDir_Right) && active_item!(window, String(value.id[i+1]))
    ig.EndDisabled()
    return nothing
end

function _draw_cell!(state::BrowserState, window::Window, cell::VisualizerCell)::Nothing
    ig.PushID(cell.id)
    if !isempty(cell.error)
        ig.TextWrapped(cell.error)
    else
        cell.draw_error = guarded_draw("$(cell.label): drawing failed", cell.draw_error) do
            draw!(cell.visualizer, _cell_context(state, window, cell))
        end
        isempty(cell.draw_error) || ig.TextWrapped(cell.draw_error)
    end
    ig.PopID()
    return nothing
end

function _draw_presentations!(state::BrowserState, window::Window)::Nothing
    if !window.has_value
        ig.TextDisabled("Waiting for input")
    elseif !(window.value isa Workspace.Selection) || window.arrangement == "overlay"
        draw!(window.visualizer, WindowContext(state, window))
    elseif isempty(window.cells)
        ig.TextDisabled("No items selected")
    elseif window.arrangement == "stack"
        cell = only(filter(cell -> cell.id == window.active_item, window.cells))
        _draw_cell!(state, window, cell)
    else
        columns = max(1, min(length(window.cells), floor(Int, ig.GetContentRegionAvail().x / 420)))
        rows = cld(length(window.cells), columns)
        height = max(280.0f0, (ig.GetContentRegionAvail().y - (rows - 1) * 8) / rows)
        if ig.BeginTable("##visualizer-grid", columns, ig.ImGuiTableFlags_SizingStretchSame)
            for cell in window.cells
                ig.TableNextColumn()
                if ig.BeginChild("cell/$(cell.id)", ig.ImVec2(0, height), ig.ImGuiChildFlags_Borders)
                    ig.TextUnformatted(cell.label)
                    _draw_cell!(state, window, cell)
                end
                ig.EndChild()
            end
            ig.EndTable()
        end
    end
    return nothing
end
