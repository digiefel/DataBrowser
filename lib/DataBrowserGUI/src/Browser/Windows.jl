# The windows that show a value with a visualizer: which visualizers the browser offers, where a
# window takes its value from, and how the value reaches the visualizer. Nothing here draws.
#
# TODO: these are the actions a script will call (roadmap 0.6). They take the browser state for now.

using DataBrowserAPI: AbstractVisualizer, id, label, prepare!, settings
using DataBrowserCore.Catalogs: ItemKey
import DataBrowserCore.Workspace

"""The items `input` names now, without those the workspace no longer has."""
itemkeys(::LiveSelection, state::BrowserState)::Vector{ItemKey} =
    _project_visible_selection(state)[2]
itemkeys(input::FixedItems, state::BrowserState)::Vector{ItemKey} =
    _items_for_ids(state, input.ids)

"""
The title of `window`: what it shows, not how. Up to three items are named by their labels, more
are counted. The header of the window names the visualizer.
"""
function title(state::BrowserState, window::Window)::String
    workspace = state.workspace::Workspace.Workspace
    items = itemkeys(window.input, state)
    isempty(items) && return "No items"
    length(items) > 3 && return "$(length(items)) items"
    return join((label(workspace, item) for item in items), ", ")
end

"""
    visualizers(T) -> Vector{AbstractVisualizer}

A new visualizer of every loaded visualizer type that shows values of type `T`, sorted by label.
A visualizer type shows such values when one of its `prepare!` methods accepts them. The methods
are read at each call, so a visualizer defined while the browser is open is found at once.
"""
function visualizers(T::Type)::Vector{AbstractVisualizer}
    types = Set{Type}()
    for method in methods(prepare!, Tuple{AbstractVisualizer,T})
        V = Base.unwrap_unionall(method.sig).parameters[2]
        isconcretetype(V) && push!(types, V)
    end
    return sort!(AbstractVisualizer[V() for V in types]; by=label)
end

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
    window = Window("window_$(state.next_window)", visualizer, input, nothing, nothing, (;), "")
    push!(state.windows, window)
    return window
end

"""Remove `window` from the browser."""
function close_window!(state::BrowserState, window::Window)::Nothing
    filter!(!==(window), state.windows)
    return nothing
end

"""
    setting!(window, name, value)

Change the setting `name` of the visualizer of `window`. The visualizer is given the value of the
window again in the next frame.
"""
function setting!(window::Window, name::Symbol, value)::Nothing
    setproperty!(window.visualizer, name, value)
    window.stamp = nothing
    return nothing
end

"""
Bring `window` up to date: read its input and, when the input gives another value than before, load
the value and hand it to the visualizer. A failure is kept in `window.error` for the window to show.

Loading runs in the calling task and waits for items that are not processed yet.
"""
function refresh!(state::BrowserState, window::Window)::Nothing
    workspace = state.workspace::Workspace.Workspace
    # TODO: both inputs name items. An input of another kind, such as the result of a function or
    # what another window offers, needs its own stamp and value.
    items = itemkeys(window.input, state)
    stamp = (
        workspace.scan.epoch,
        [id(workspace, item) for item in items],
        Workspace.revision(workspace, items),
    )
    stamp == window.stamp && return nothing
    window.stamp = stamp
    window.settings = (;)
    visualizer = window.visualizer
    try
        # Narrow the element type, so that `prepare!` methods can dispatch on the type of the items.
        window.value = identity.(Workspace.materialize_items(workspace, items))
        if applicable(prepare!, visualizer, window.value)
            prepare!(visualizer, window.value)
            window.settings = settings(visualizer, window.value)
            window.error = ""
        else
            window.error = "$(label(visualizer)) cannot show these items. Choose another visualizer."
        end
    catch err
        @error "Window: $(label(visualizer)) could not show its value" exception=(err, catch_backtrace())
        summary = first(split(sprint(showerror, err), '\n'; limit=2))
        window.error = "$(label(visualizer)) failed: $summary. See the console for full details."
    end
    return nothing
end
