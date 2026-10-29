# One window owns the settings; per-item instances own prepared data and drawing state.

function _close_cells!(window::Window)::Nothing
    for cell in window.cells
        cell.visualizer === window.visualizer || close(cell.visualizer)
    end
    empty!(window.cells)
    return nothing
end

_cell_context(state::BrowserState, window::Window, cell::VisualizerCell) =
    _cell_context(WindowContext(state, window), cell)
_cell_context(parent::WindowContext, cell::VisualizerCell) =
    WindowContext("$(parent.id)/$(cell.id)", parent.workspace, parent.open_window, parent.prepare)

function _sync_cell_settings!(window::Window)::Nothing
    for cell in window.cells, name in keys(settings(window.visualizer))
        setproperty!(cell.visualizer, name, getproperty(window.visualizer, name))
    end
    return nothing
end

# Accepting a Selection is the visualizer's existing declaration of whole-selection support.
_can_overlay(window::Window, ctx) = window.value isa Workspace.Selection &&
    applicable(prepare!, window.visualizer, window.value, ctx)

function arrangement!(window::Window, mode::String)::Nothing
    _require_available(window)
    mode in ("stack", "grid", "overlay") || throw(ArgumentError("Unknown arrangement: $mode"))
    window.arrangement == mode && return nothing
    window.arrangement = mode
    # The main instance changes from one item to another or to the full selection.
    window.presentation_revision += UInt(1)
    window.presentation_dirty = true
    return nothing
end

function active_item!(window::Window, id::String)::Nothing
    _require_available(window)
    window.active_item == id && return nothing
    window.active_item = id
    window.presentation_dirty = true
    return nothing
end

# A single preparation lane also serializes use of process-wide plotting defaults. Each window
# still has its own task, and the UI never waits for this lock.
const PREPARATION_LOCK = ReentrantLock()

function _prepare_presentations!(state::BrowserState, window::Window)::Nothing
    preparing(window) && return nothing
    window.has_value || return nothing
    saved = _persisted_window(window)
    name, size = label(window.visualizer), initial_size(window.visualizer)
    unavailable() = error("Browser actions are available from draw! and draw_header!, not prepare!")
    ctx = WindowContext(window.id, state.workspace, _ -> unavailable(), unavailable)
    window.presentation_dirty = false
    task = Threads.@spawn :default lock(PREPARATION_LOCK) do
        retired = AbstractVisualizer[]
        error = ""
        try
            Base.invokelatest(_prepare_presentations_value!, window, ctx, retired)
        catch err
            error, _ = DataBrowserAPI.report_error(
                "Window: $name could not show its value", err, catch_backtrace())
        end
        (; retired, error)
    end
    window.preparation = WindowPreparation(task, saved, name, size)
    return nothing
end

"""Return ownership to the UI after preparation, and release retired graphics on that thread."""
function _finish_preparation!(window::Window)::Bool
    job = window.preparation
    job === nothing && return true
    istaskdone(job.task) || return false
    result = fetch(job.task)
    window.preparation = nothing
    foreach(close, result.retired)
    window.error = result.error
    return true
end

function _finish_closed_windows!(state::BrowserState)::Nothing
    for window in copy(state.closing_windows)
        _finish_preparation!(window) || continue
        _close_cells!(window)
        close(window.visualizer)
        filter!(other -> other !== window, state.closing_windows)
        computed!(state, window, String[])
    end
    return nothing
end

function _retire_cells!(window::Window, retired)::Nothing
    append!(retired, (cell.visualizer for cell in window.cells if cell.visualizer !== window.visualizer))
    empty!(window.cells)
    return nothing
end

function _prepare_presentations_value!(window::Window, ctx::WindowContext, retired)::Nothing
    given, visualizer = window.value, window.visualizer
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
        # Existing selection-only views, e.g. Table and registered plots, stay combined.
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
            # Selection-only visualizers still get the metadata of this one item.
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
