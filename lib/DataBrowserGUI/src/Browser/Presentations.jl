# How a window shows a selection: one instance for all items (Overlay), or one cell for each item
# (Stack and Grid). Each instance has the settings of the visualizer of the window, and holds what it
# prepared for its item and its drawing state.

# Close the instances of the cells and of the window. `close` is a dynamic call: packages add `close`
# methods for their visualizers when they load, and a static call would make each of them invalidate
# the compiled code of the browser.
function _close_visualizers!(window::Window)::Nothing
    for cell in window.cells
        cell.visualizer === window.instance || Base.invokelatest(close, cell.visualizer)
    end
    empty!(window.cells)
    Base.invokelatest(close, window.instance)
    return nothing
end

_cell_context(state::BrowserState, window::Window, cell::VisualizerCell) =
    _cell_context(WindowContext(state, window), cell)
_cell_context(parent::WindowContext, cell::VisualizerCell) =
    WindowContext("$(parent.id)/$(cell.id)", parent.workspace, parent.open_window, parent.prepare)

function _sync_cell_settings!(window::Window)::Nothing
    for cell in window.cells, name in keys(settings(window.instance))
        setproperty!(cell.visualizer, name, getproperty(window.instance, name))
    end
    return nothing
end

# A visualizer with a `prepare!` method for a whole selection shows all items together.
_can_overlay(window::Window, ctx) = window.value isa Workspace.Selection &&
    applicable(prepare!, window.instance, window.value, ctx)

# A single preparation lane also serializes use of process-wide plotting defaults. Each window
# still has its own task, and the UI never waits for this lock.
const PREPARATION_LOCK = ReentrantLock()

# Prepare the instance of `window` in a task, with the value of the window.
function _prepare_presentations!(state::BrowserState, window::Window)::Nothing
    chosen = Dict{String,Any}(String(name) => value for (name, value) in pairs(selection(window.instance)))
    name, size = window.definition.label, initial_size(window.instance)
    unavailable() = error("Browser actions are available from draw! and draw_header!, not prepare!")
    ctx = WindowContext(window.id, state.workspace, _ -> unavailable(), unavailable)
    window.presentation_dirty = false
    task = Threads.@spawn :default begin
        retired = AbstractVisualizer[]
        error = ""
        try
            lock(PREPARATION_LOCK) do
                @timed_dbg "visualizer.prepare" Base.invokelatest(_prepare_presentations_value!, window, ctx, retired)
            end
        catch err
            error, _ = DataBrowserAPI.report_error(
                "Window: $name could not show its value", err, catch_backtrace())
        end
        (; retired, error)
    end
    window.preparation = WindowPreparation(task, chosen, size)
    return nothing
end

"""Return ownership to the UI after preparation, and release retired graphics on that thread."""
function _finish_preparation!(window::Window)::Bool
    job = window.preparation
    job === nothing && return true
    istaskdone(job.task) || return false
    result = fetch(job.task)
    window.preparation = nothing
    # A dynamic call, as in `_close_visualizers!`.
    for visualizer in result.retired::Vector{AbstractVisualizer}
        Base.invokelatest(close, visualizer)
    end
    window.error = result.error
    return true
end

function _finish_closed_windows!(state::BrowserState)::Nothing
    for window in copy(state.closing_windows)
        _finish_preparation!(window) || continue
        _close_visualizers!(window)
        filter!(other -> other !== window, state.closing_windows)
    end
    return nothing
end

function _retire_cells!(window::Window, retired)::Nothing
    append!(retired, (cell.visualizer for cell in window.cells if cell.visualizer !== window.instance))
    empty!(window.cells)
    return nothing
end

function _prepare_presentations_value!(window::Window, ctx::WindowContext, retired)::Nothing
    given, visualizer = window.value, window.instance
    if !(given isa Workspace.Selection)
        _retire_cells!(window, retired)
        prepare!(visualizer, given, ctx)
        return nothing
    end
    if window.arrangement == "auto"
        # Do not settle the default before the input has any items.
        if isempty(given)
            _retire_cells!(window, retired)
            return nothing
        end
        # A visualizer that takes the data of one item shows each item in a cell of a stack. One
        # that takes only a whole selection, such as the table, shows all items together.
        native = applicable(prepare!, visualizer, first(given.data), ctx)
        window.arrangement = !native && _can_overlay(window, ctx) ? "overlay" : "stack"
    end
    if window.arrangement == "overlay"
        _retire_cells!(window, retired)
        _can_overlay(window, ctx) || error("$(label(visualizer)) does not support Overlay")
        prepare!(visualizer, given, ctx)
        return nothing
    end
    ids = String.(given.id)
    window.active_item in ids || (window.active_item = isempty(ids) ? "" : first(ids))
    indices = window.arrangement == "stack" ? findall(==(window.active_item), ids) : collect(eachindex(ids))
    existing = Dict(cell.id => cell for cell in window.cells)
    # Stack reuses one instance. Grid reuses it for the first item and has one instance per other item.
    next = VisualizerCell[]
    for (position, i) in enumerate(indices)
        v = position == 1 ? visualizer : haskey(existing, ids[i]) &&
            existing[ids[i]].visualizer !== visualizer ? existing[ids[i]].visualizer : typeof(visualizer)()
        cell = get(existing, ids[i], nothing)
        if cell === nothing || cell.visualizer !== v
            cell = VisualizerCell(ids[i], String(given.label[i]), v, typemax(UInt), "", "")
        end
        push!(next, cell)
    end
    for cell in window.cells
        cell.visualizer === visualizer && continue
        any(other -> other.visualizer === cell.visualizer, next) || push!(retired, cell.visualizer)
    end
    window.cells = next
    _sync_cell_settings!(window)
    # Grid reads the payloads together; Stack loads only its active item.
    data = window.arrangement == "grid" ? collect(given.data) : nothing
    for (cell, i) in zip(window.cells, indices)
        cell.label = String(given.label[i])
        cell.revision == window.presentation_revision && continue
        try
            child_ctx = _cell_context(ctx, cell)
            value = data === nothing ? given.data[i] : data[i]
            # A visualizer that takes only a selection gets a selection of this one item, with its
            # metadata.
            applicable(prepare!, cell.visualizer, value, child_ctx) || (value = given[[i]])
            prepare!(cell.visualizer, value, child_ctx)
            cell.error = cell.draw_error = ""
        catch err
            cell.error, _ = DataBrowserAPI.report_error(
                "$(cell.label): $(label(visualizer)) could not show its value", err, catch_backtrace())
        end
        cell.revision = window.presentation_revision
    end
    return nothing
end
