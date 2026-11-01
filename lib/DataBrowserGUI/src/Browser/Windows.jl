# The windows that show a value with a visualizer: which visualizers the browser offers, where a
# window takes its value from, and how the value reaches the visualizer. Nothing here draws.
#
# TODO: these are the actions a script will call (roadmap 0.6). They take the browser state for now.

import DataBrowserAPI
using DataBrowserAPI: AbstractVisualizer, id, label, prepare!, settings
using DataBrowserAPI: @timed_dbg
import DataBrowserAPI: output
using DataBrowserCore.Catalogs: ItemKey
using DataBrowserCore.CodeRevisions: code_revision
import DataBrowserCore.Workspace

"""The items `input` names now, without those the workspace no longer has."""
itemkeys(::LiveSelection, state::BrowserState)::Vector{ItemKey} =
    _project_visible_selection(state)[2]
itemkeys(input::FixedItems, state::BrowserState)::Vector{ItemKey} =
    _items_for_ids(state, input.ids)
itemkeys(input::WindowOutput, state::BrowserState)::Vector{ItemKey} =
    itemkeys(source(input, state).input, state)

"""The window `input` takes its value from."""
source(input::WindowOutput, state::BrowserState)::Window =
    only(window for window in state.windows if window.id == input.window)

"""Whether `window` takes its value from `other`, directly or through other windows."""
function follows(state::BrowserState, window::Window, other::Window)::Bool
    input = window.input
    while input isa WindowOutput
        window = source(input, state)
        window === other && return true
        input = window.input
    end
    return false
end

"""
    output(window)

The value `window` passes on to a window that takes its input from it: the output of its
visualizer, or the value of the window when the visualizer has none.
"""
function output(window::Window)
    _require_available(window)
    # A grid's per-cell interaction has no single combined output contract yet. Its downstream
    # input remains the full value, rather than silently taking the first cell's output.
    window.arrangement == "grid" && return window.value
    return something(output(window.visualizer), Some(window.value))
end

# What tells whether the input of `window` gives another value than before: another stamp means
# another value. Reading the stamp costs time in proportion to the items, so it is read again only
# when what it is read from changed: the input and the object it names (kept items, ids or an
# output, compared by identity), the scan, the status of any stage, or a method definition.
function stamp(window::Window, state::BrowserState)
    workspace = state.workspace
    input = window.input
    named = input isa LiveSelection ? itemkeys(input, state) :
        input isa FixedItems ? input.ids : output(source(input, state))
    basis = (input, named, workspace.scan.epoch, Workspace.status_revision(workspace),
        Base.get_world_counter())
    window.checked !== nothing && first(window.checked) === basis && return last(window.checked)
    current = stamp(input, state)
    window.checked = (basis, current)
    return current
end
# Item keys are never reused, so their hash tells the items apart without building their ids.
function stamp(input::Union{LiveSelection,FixedItems}, state::BrowserState)
    workspace = state.workspace
    items = itemkeys(input, state)
    return (workspace.scan.epoch, hash(items), Workspace.revision(workspace, items))
end
# A visualizer returns the same object until its output changes.
function stamp(input::WindowOutput, state::BrowserState)
    given = output(source(input, state))
    seen = objectid(given)
    if given isa AbstractVector{<:Workspace.Computation}
        for value in given
            seen = hash(Workspace.revision(state.workspace, value), seen)
        end
    end
    return seen
end

# The value `input` gives now: the items as a `Selection`. This runs in the calling task and waits
# for items that are not processed yet.
value(input::Union{LiveSelection,FixedItems}, state::BrowserState) =
    Workspace.select(state.workspace, itemkeys(input, state))
value(input::WindowOutput, state::BrowserState) = output(source(input, state))

"""
The title of `window`: what it shows, not how. Up to three items are named by their labels, more
are counted. The header of the window names the visualizer.
"""
function title(state::BrowserState, window::Window)::String
    workspace = state.workspace
    # TODO(scale): the browser asks for the title at each frame, and the items of fixed ids are
    # looked up again each time; keep the title until the input or the workspace changes.
    items = itemkeys(window.input, state)
    isempty(items) && return "No items"
    length(items) > 3 && return "$(length(items)) items"
    return join((label(workspace, item) for item in items), ", ")
end

"""
    visualizers(T) -> Vector{AbstractVisualizer}

A new visualizer of every loaded visualizer type that shows values of type `T`, sorted by label.
A selection also offers visualizers of individual values, for Stack and Grid. A visualizer type
shows other values when one of its `prepare!` methods accepts them. The methods
are read at each call, so a visualizer defined while the browser is open is found at once.
"""
function visualizers(T::Type)::Vector{AbstractVisualizer}
    types = Set{Type}()
    for method in (T <: Workspace.Selection ? methods(prepare!) : methods(prepare!, Tuple{AbstractVisualizer,T,Any}))
        V = Base.unwrap_unionall(method.sig).parameters[2]
        # `methods` also lists methods that accept only some values of type `T`.
        V isa DataType && V <: AbstractVisualizer && isconcretetype(V) &&
            (T <: Workspace.Selection || hasmethod(prepare!, Tuple{V,T,Any})) && push!(types, V)
    end
    return sort!(AbstractVisualizer[V() for V in types]; by=label)
end

# What `window` tells its visualizer. A window opened from it is drawn from the next frame on, as
# the browser draws a copy of its list of windows.
WindowContext(state::BrowserState, window::Window) = WindowContext(window.id, state.workspace,
    visualizer -> (transform!(open_window!(state, visualizer; input=window.input), window.transform); nothing),
    () -> (window.presentation_dirty = true; window.presentation_revision += UInt(1); nothing))

"""Whether preparation has exclusive access to the visualizer of `window`."""
preparing(window::Window)::Bool = window.preparation !== nothing

function _require_available(window::Window)::Nothing
    preparing(window) && throw(ArgumentError("Window $(window.id) is preparing"))
    return nothing
end

_window_label(window::Window) = preparing(window) ? window.preparation.label : label(window.visualizer)

"""
    open_window!(state, visualizer; input=LiveSelection()) -> Window

Add a window to the browser that shows the value of `input` with `visualizer`.
"""
function open_window!(
    state::BrowserState,
    visualizer::AbstractVisualizer;
    input::WindowInput=LiveSelection(),
)::Window
    state.next_window += 1
    window = Window("window_$(state.next_window)", visualizer, input, nothing, (UInt(0), ""), ItemKey[], nothing, nothing, nothing, "", "", "", "", true, "auto", "", VisualizerCell[], UInt(0), true, false, nothing)
    push!(state.windows, window)
    return window
end

"""
Remove `window` from the browser. A window that took its value from `window` follows the selection
again.
"""
function close_window!(state::BrowserState, window::Window)::Nothing
    _discard_window_preview!(window.id)
    filter!(other -> other !== window, state.windows)
    if preparing(window)
        push!(state.closing_windows, window)
    else
        _close_visualizers!(window)
    end
    for other in state.windows
        input = other.input
        input isa WindowOutput && input.window == window.id && (other.input = LiveSelection())
    end
    return nothing
end

"""
    input!(state, window, input)

Take the value of `window` from another input.
"""
function input!(state::BrowserState, window::Window, input::WindowInput)::Nothing
    _require_available(window)
    if input isa WindowOutput
        other = source(input, state)
        (other === window || follows(state, other, window)) &&
            error("A window cannot take its value from itself, directly or through other windows.")
    end
    window.input = input
    return nothing
end

"""
    transforms() -> Vector{GlobalRef}

The functions a window can pass its value through: those the project defines in `Main`, sorted by
name.
"""
function transforms()::Vector{GlobalRef}
    # TODO: also the functions of packages the project develops (`Pkg.develop`).
    found = GlobalRef[]
    for name in names(Main; all=true)
        (startswith(String(name), '#') || name in (:eval, :include)) && continue
        isdefinedglobal(Main, name) || continue
        f = getglobal(Main, name)
        f isa Function && !(f isa Type) && parentmodule(f) === Main && push!(found, GlobalRef(Main, name))
    end
    return sort!(found; by=ref -> ref.name)
end

"""
    transform!(window, transform)

Pass the value of `window` through the function named by `transform`, a `GlobalRef`, before the
visualizer shows it; `nothing` shows the value unchanged.

The function receives each item of the input, as `process` receives it, and returns the value to
show for it. A function with a method for a `Selection` and none for the items receives the whole
selection instead, and returns one value, such as a mean over the items. The computation is
evaluated in the background and evaluated again when an input or the code of the function
changes. The visualizer receives a selection of the results with their computation references;
viewing them adds no items to the workspace catalog.

A value of the input that is not a selection of items is passed to the function as it is.
"""
function transform!(window::Window, transform::Union{Nothing,GlobalRef})::Nothing
    _require_available(window)
    window.transform = transform
    window.stamp = nothing
    return nothing
end

# The code revision of the transform of `window`. It is computed again only after a definition.
function code(window::Window)::String
    window.transform === nothing && return ""
    world = Base.get_world_counter()
    if first(window.code) != world
        f = Base.invokelatest(getglobal, window.transform.mod, window.transform.name)
        window.code = (world, code_revision(Any[f]).hash)
    end
    return last(window.code)
end

"""
    visualizer!(window, visualizer)

Show the value of `window` with another visualizer.
"""
function visualizer!(window::Window, visualizer::AbstractVisualizer)::Nothing
    _require_available(window)
    _close_visualizers!(window)
    window.visualizer = visualizer
    window.arrangement = "auto"
    window.presentation_dirty = true
    # The new visualizer is given the value in the next frame.
    window.stamp = nothing
    return nothing
end

"""
    setting!(window, name, value)

Change the setting `name` of the visualizer of `window`. The visualizer is given the value of the
window again in the next frame, unless the setting needs no `prepare!`.
"""
function setting!(window::Window, name::Symbol, value)::Nothing
    _require_available(window)
    visualizer = window.visualizer
    setproperty!(visualizer, name, value)
    if settings(visualizer)[name].prepare
        window.presentation_revision += UInt(1)
        window.presentation_dirty = true
    end
    _sync_cell_settings!(window)
    return nothing
end

"""
Bring `window` up to date: read its input and, when the input gives another value than before or
the code of its transform changed, pass the value through the transform and hand the result to the
visualizer. The items the value needs are processed and computed in the background: until they are
ready, the window keeps what it shows, and `window.waiting` holds them. A failure is kept in
`window.error` for the window to show.
"""
function refresh!(state::BrowserState, window::Window)::Nothing
    return @timed_dbg "window.refresh" _refresh_window!(state, window)
end

function _refresh_window!(state::BrowserState, window::Window)::Nothing
    _finish_preparation!(window) || return nothing
    input = window.input
    if input isa WindowOutput
        upstream = source(input, state)
        refresh!(state, upstream)
        if preparing(upstream) || !upstream.has_value || !isempty(upstream.error)
            window.error = isempty(upstream.error) ? "" :
                "Input window ($(_window_label(upstream))) failed:\n" * upstream.error
            window.stamp = nothing
            return nothing
        end
    end
    workspace = state.workspace
    current = @timed_dbg "window.stamp" (stamp(window, state), window.transform, code(window))
    if current == window.stamp
        window.presentation_dirty && _prepare_presentations!(state, window)
        return nothing
    end
    if !(input isa WindowOutput)
        items = itemkeys(input, state)
        if !Workspace.processed(workspace, items)
            window.waiting = items
            return nothing
        end
    end
    empty!(window.waiting)
    try
        window.value = @timed_dbg "window.input" value(input, state)
        window.has_value = true
        window.stamp = current
        window.presentation_revision += UInt(1)
        window.presentation_dirty = true
        _prepare_presentations!(state, window; resolve_input=true)
    catch err
        window.error, _ = DataBrowserAPI.report_error(
            "Window: $(label(window.visualizer)) could not show its value", err, catch_backtrace())
    end
    return nothing
end

# The value a window shows: its input passed through its function, evaluated on the preparation
# task. Also return why computations failed, one line each; the value leaves out their items.
function _resolve_window_input(workspace, given, transform)
    failures = String[]
    function resolve(values)
        items = DataBrowserAPI.AbstractDataItem[]
        for value in values
            try
                append!(items, Workspace.materialize_items(workspace, [value]))
            catch err
                # The workspace reports a failed computation as an `ErrorException` with its message.
                err isa ErrorException || rethrow()
                push!(failures, "$(label(value)): $(first(split(err.msg, '\n')))")
            end
        end
        return Workspace.Selection(workspace, items)
    end
    given isa AbstractVector{<:Workspace.Computation} && (given = resolve(given))
    if transform !== nothing
        f = Base.invokelatest(getglobal, transform.mod, transform.name)
        if given isa Workspace.Selection
            whole = Base.invokelatest(hasmethod, f, Tuple{Workspace.Selection}) &&
                !all(item -> Base.invokelatest(applicable, f,
                    item isa Workspace.ComputationItem ? item.value : item), Workspace.items(given))
            calls = whole ? [Workspace.Computation(f, given)] :
                [Workspace.Computation(f, Workspace.computation(given, i)) for i in eachindex(given)]
            given = resolve(calls)
        else
            given = Workspace.evaluate(workspace, Workspace.Computation(f, given))
        end
    end
    return given, join(failures, '\n')
end
