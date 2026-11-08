import CImGui as ig
import CImGui.CSyntax: @c
using NativeFileDialog: save_file

using DataBrowserAPI: Setting, draw_header!, export!, initial_size, label, settings
import DataBrowserCore.Workspace

"""
Draw the header that every window has: a menu to change the visualizer type, a menu to change the
input, a menu to change the function that the value passes through, and "Live", which makes the
visualizer follow the selection. Each changes the visualizer of the window, for every client.
"""
function _render_window_header!(state::BrowserState, window::Window)::Nothing
    v = window.visualizer
    (; type, label, input, transform) = @atomic v.definition
    if ig.BeginCombo("##visualizer", label, ig.ImGuiComboFlags_WidthFitPreview)
        for candidate in visualizers(typeof(window.value))
            current = typeof(candidate) === type
            ig.Selectable(DataBrowserAPI.label(candidate), current) && !current && Workspace.visualizer!(v, candidate)
        end
        ig.EndCombo()
    end

    ig.SameLine()
    ig.AlignTextToFramePadding()
    ig.TextDisabled("from")
    ig.SameLine()
    # TODO: two visualizers that show the same items with the same visualizer type have the same
    # name here. Let the user name a visualizer.
    name(other) = "$((@atomic other.definition).label): $(title(state, other))"
    selection = input isa Union{Workspace.LiveSelection,Workspace.FixedItems}
    preview = input isa Workspace.Visualizer ? name(input) : selection ? "Selection" : "Function"
    # As wide as the name, up to a limit: the names of several items must not take the whole row.
    ig.SetNextItemWidth(min(ig.CalcTextSize(preview).x + 2 * ig.GetFrameHeight(), 220.0f0))
    if ig.BeginCombo("##input", preview)
        ig.Selectable("Selection", selection) && !selection && Workspace.input!(v, Workspace.LiveSelection())
        for other in (@atomic state.workspace.shared).visualizers
            (other === v || Workspace.follows(other, v)) && continue
            current = input === other
            ig.Selectable("$(name(other))###$(id(other))", current) && !current && Workspace.input!(v, other)
        end
        ig.EndCombo()
    end
    ig.SetItemTooltip("Where the value comes from: the selection, or another visualizer.")

    ig.SameLine()
    ig.AlignTextToFramePadding()
    ig.TextDisabled("through")
    ig.SameLine()
    through = transform === nothing ? "nothing" : String(transform.name)
    if ig.BeginCombo("##transform", through, ig.ImGuiComboFlags_WidthFitPreview)
        ig.Selectable("nothing", transform === nothing) && Workspace.transform!(v, nothing)
        for ref in transforms()
            ig.Selectable(String(ref.name), ref == transform) && Workspace.transform!(v, ref)
        end
        ig.EndCombo()
    end
    ig.SetItemTooltip("A function of the project that the value passes through before it is shown.")

    # TODO: "Live" for the output of another visualizer: when off, keep the value it has now.
    selection || return nothing
    ig.SameLine()
    live = input isa Workspace.LiveSelection
    if @c ig.Checkbox("Live", &live)
        ## Off keeps the items the window shows now.
        Workspace.input!(v, live ? Workspace.LiveSelection() : Workspace.FixedItems(copy(Workspace.item_ids(v))))
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
Draw the settings the visualizer type declared, in the row of the header. What the user changes
changes the visualizer of the window, for every client.
"""
function _render_window_settings!(window::Window)::Nothing
    # TODO: start a new row when the window is too narrow for the next setting.
    for (name, setting) in pairs(settings(window.instance))
        setting.visible || continue
        ig.SameLine()
        current = getproperty(window.instance, name)
        chosen = _render_setting!(setting, current)
        chosen == current || setproperty!(window.visualizer, name, chosen)
    end
    return nothing
end

"""
Draw "Export", which every window has, and save what the window shows when the user clicks it.
"""
function _render_export_button!(state::BrowserState, window::Window)::Nothing
    clicked = ig.Button("Export")
    ig.SetItemTooltip("Save what the window shows")
    try
        if clicked
            visualizer = window.instance
            # The file types the visualizer saves. Without one, and for a grid of several cells,
            # the browser saves a picture of the window. `showable` is a dynamic call: packages add
            # methods for their visualizers when they load, and a static call would make each of them
            # invalidate the compiled code here.
            extensions = [extension[2:end] for (extension, mime) in DataBrowserAPI.MIME_TYPES
                          if window.arrangement != "grid" && Base.invokelatest(showable, mime, visualizer)]
            picture = isempty(extensions)
            picture && push!(extensions, "png")
            path = save_file("$(title(state, window.visualizer)).$(first(extensions))"; filterlist=join(extensions, ","))
            if !isempty(path)
                isempty(splitext(path)[2]) && (path *= ".$(first(extensions))")
                if picture
                    WINDOW_PICTURE[] = WindowPicture(window.id, path, 0, 0, 0, 0, UInt8[])
                else
                    export!(visualizer, path)
                end
            end
        end
        # The picture of the window, when "Export" asked for one in the last frame.
        save_window_picture!(window.id)
        clicked && (window.export_error = "")
    catch err
        window.export_error, _ = DataBrowserAPI.report_error("Export failed", err, catch_backtrace())
    end
    return nothing
end

"""
Draw every window that shows a visualizer: first open those that `visualize!` opened, and remove
those that `close` closed or whose visualizer left the workspace. A window that is not visible, for
example behind another tab, is not brought up to date.
"""
function render_windows!(state::BrowserState)::Nothing
    # The plots drawn with ImPlot need its context.
    _init_implot_context!(state)
    _release_retired_window_previews!()
    while isready(state.opening)
        push!(state.windows, take!(state.opening))
    end
    present = (@atomic state.workspace.shared).visualizers
    for window in copy(state.windows)
        ((@atomic window.closing) || !any(v -> v === window.visualizer, present)) && _close_window!(state, window)
    end
    _finish_closed_windows!(state)
    for window in copy(state.windows)
        _finish_preparation!(window)
        # Restored windows can reuse a closed window's id. Release the old owner before drawing
        # a replacement whose preparation has just finished.
        _finish_closed_windows!(state)
        open = Ref(true)
        window.initial_size_pending && ig.SetNextWindowDockID(0, ig.ImGuiCond_Always)
        condition = window.initial_size_pending ? ig.ImGuiCond_Always : ig.ImGuiCond_FirstUseEver
        size = preparing(window) ? window.preparation.initial_size : initial_size(window.instance)
        ig.SetNextWindowSize(size, condition)
        window.initial_size_pending = false
        # ImGui knows the window by the part after "###", so the title can change.
        if ig.Begin(_window_caption(state, window), open, _preparing_window_flags(window))
            content_position, content_size = _window_preview_region()
            ctx = WindowContext(state, window)
            # An error of the visualizer, or of the code it runs, leaves the rest of the window and
            # the browser working; the window shows the error where the drawing stopped.
            window.draw_error = guarded_draw("Window: $(window.definition.label) failed to draw", window.draw_error) do
                if preparing(window)
                    _draw_window_preview!(window.id, content_position, content_size)
                    return nothing
                end
                _render_window_header!(state, window)
                _render_arrangement!(state, window)
                _render_window_settings!(window)
                ig.SameLine()
                _render_export_button!(state, window)
                # A group is one item of the row, also when the visualizer draws no button.
                ig.SameLine()
                ig.BeginGroup()
                before = Dict{Symbol,Any}(
                    name => getproperty(window.instance, name) for name in keys(settings(window.instance)))
                # A dynamic call: packages add `draw_header!` methods for their visualizers when they
                # load, and a static call would make each of them invalidate the compiled code here.
                Base.invokelatest(draw_header!, window.instance, ctx)
                for (name, value) in before
                    chosen = getproperty(window.instance, name)
                    isequal(value, chosen) || setproperty!(window.visualizer, name, chosen)
                end
                ig.EndGroup()
                # Every visualizer control runs before handing ownership to preparation.
                result = refresh!(state, window)
                ig.Separator()
                if preparing(window)
                    _draw_window_preview!(window.id, content_position, content_size)
                    return nothing
                end
                _sync_cell_settings!(window)
                isempty(window.export_error) || ig.TextWrapped(window.export_error)
                result.loading && ig.TextDisabled("Loading")
                isempty(result.failed) || ig.TextWrapped("Failed:\n" * result.failed)
                measure_window_picture!(window.id)
                failure = isempty(result.error) ? window.error : result.error
                isempty(failure) ? _draw_presentations!(state, window) : ig.TextWrapped(failure)
            end
            isempty(window.draw_error) || ig.TextWrapped(window.draw_error)
            if open[] && !preparing(window)
                _capture_window_preview!(window.id, content_position, content_size)
            end
        end
        ig.End()
        open[] || close(window)
    end
    return nothing
end
