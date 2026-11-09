# The windows of the browser, each of which shows a visualizer of the workspace: which visualizers
# the browser offers, how a window opens and closes, and how the value of its visualizer reaches the
# instance that draws it. Nothing here draws.

import DataBrowserAPI
using DataBrowserAPI: AbstractVisualizer, id, label, prepare!, settings
using DataBrowserAPI: @timed_dbg
import DataBrowserAPI: output
import DataBrowserCore: visualize!
import DataBrowserCore.Workspace

"""
    visualize!(browser, v) -> w
    visualize!(browser, visualizer; input=LiveSelection()) -> w

Show the visualizer `v` of the workspace in a new window `w` of `browser`, a
[`BrowserSession`](@ref). Given `visualizer`, a new instance of a visualizer type, first add a
visualizer to the workspace that shows the value of `input` with it, as `visualize!(workspace,
visualizer; input)` does. The window appears in the next frame of the browser.

`w.visualizer` is the visualizer that the window shows. `close(w)` closes the window and leaves the
visualizer in the workspace; `close(w.visualizer)` removes the visualizer and closes every window
that shows it.

```julia
browser = open_browser(workspace; wait=false)
v = visualize!(workspace, PlotView(plot="IV"))
w = visualize!(browser, v)
close(w)
```
"""
function visualize!(browser::BrowserSession, visualizer; kwargs...)::Window
    istaskdone(browser.task) && error("The browser is closed. Open it again with `open_browser`.")
    return visualize!(browser.state, visualizer; kwargs...)
end

visualize!(state::BrowserState, visualizer::AbstractVisualizer; input=Workspace.LiveSelection())::Window =
    visualize!(state, visualize!(state.workspace, visualizer; input), visualizer)

# A window that shows `v` with `instance`, or else with a new instance of the visualizer type of `v`.
# Any thread may call it: the window enters the list of windows in the next frame, as the browser
# draws a copy of the list. Until the window first publishes the output of its instance, visualizers
# that take their input from `v` wait for it.
function visualize!(state::BrowserState, v::Workspace.Visualizer, instance=nothing)::Window
    definition = @atomic v.definition
    window = Window("window_$(Threads.atomic_add!(state.next_window, 1) + 1)", v,
        instance === nothing ? _instance(definition) : instance, definition, nothing, 0, (0, nothing),
        "", "", "", true, definition.arrangement, definition.active_item, VisualizerCell[], UInt(0),
        false, nothing, false)
    Workspace.output!(v, window.published)
    put!(state.opening, window)
    return window
end

# A new instance of the visualizer type of `definition`, with its settings. A dynamic call: a
# package defines its visualizer types after the browser compiled.
function _instance(definition::Workspace.Definition)::AbstractVisualizer
    instance = Base.invokelatest(definition.type)
    for (name, value) in pairs(definition.settings)
        setproperty!(instance, name, value)
    end
    return instance
end

"""
    close(w::Window)

Close the window `w` of the browser in its next frame. The visualizer that it shows stays in the
workspace.
"""
Base.close(window::Window)::Nothing = (@atomic window.closing = true; nothing)

# Remove `window` from the browser, on the UI thread. Visualizers that took the output of its
# instance take the value of its visualizer again.
function _close_window!(state::BrowserState, window::Window)::Nothing
    _discard_window_preview!(window.id)
    filter!(other -> other !== window, state.windows)
    @atomicreplace window.visualizer.output window.published => nothing
    preparing(window) ? push!(state.closing_windows, window) : _close_visualizers!(window)
    return nothing
end

"""
The title of a window that shows `v`: the items it shows. Up to three items are named by their
labels, and more are counted. The header of the window names the visualizer.
"""
function title(state::BrowserState, v::Workspace.Visualizer)::String
    ids = Workspace.item_ids(v)
    isempty(ids) && return "No items"
    length(ids) > 3 && return "$(length(ids)) items"
    return join((label(state.workspace, x) for x in ids), ", ")
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
        ## `methods` also lists methods that accept only some values of type `T`.
        V isa DataType && V <: AbstractVisualizer && isconcretetype(V) &&
            (T <: Workspace.Selection || hasmethod(prepare!, Tuple{V,T,Any})) && push!(types, V)
    end
    return sort!(AbstractVisualizer[V() for V in types]; by=label)
end

# What `window` tells its instance. A window opened from it shows the same input passed through the
# same function.
WindowContext(state::BrowserState, window::Window) = WindowContext(window.id, state.workspace,
    function (visualizer)
        (; input, transform) = @atomic window.visualizer.definition
        Workspace.transform!(visualize!(state, visualizer; input).visualizer, transform)
        return nothing
    end,
    () -> (window.presentation_dirty = true; window.presentation_revision += UInt(1); nothing))

"""Whether preparation has exclusive access to the instance of `window`."""
preparing(window::Window)::Bool = window.preparation !== nothing

"""
    transforms() -> Vector{GlobalRef}

The functions a window can pass its value through: those the project defines in `Main`, sorted by
name.
"""
function transforms()::Vector{GlobalRef}
    ## TODO: also the functions of packages the project develops (`Pkg.develop`).
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
Bring `window` up to date, and return the latest result of its visualizer, as `Workspace.refresh!`
gives it. The window copies to its instance the settings that changed in the visualizer, and gives
the instance the value of each new result, which a task prepares. Then it publishes the output of
the instance for the visualizers that take their input from its visualizer. A failure of the
preparation is kept in `window.error` for the window to show.
"""
function refresh!(state::BrowserState, window::Window)::Workspace.Result
    v = window.visualizer
    _finish_preparation!(window) || return @atomic v.result
    ## A visualizer that takes the output of another one waits for the windows that show it, also
    ## when they are hidden.
    input = (@atomic v.definition).input
    if input isa Workspace.Visualizer
        for other in state.windows
            other.visualizer === input && refresh!(state, other)
        end
    end
    result = @timed_dbg "window.refresh" Workspace.refresh!(v)
    definition, before = (@atomic v.definition), window.definition
    if definition !== before
        window.definition = definition
        if definition.type !== typeof(window.instance)
            _close_visualizers!(window)
            window.instance = _instance(definition)
            window.arrangement = definition.arrangement
            window.presentation_revision += UInt(1)
            window.presentation_dirty = true
        else
            for (name, value) in pairs(definition.settings)
                isequal(value, before.settings[name]) && continue
                setproperty!(window.instance, name, value)
                if settings(window.instance)[name].prepare
                    window.presentation_revision += UInt(1)
                    window.presentation_dirty = true
                end
            end
            if definition.arrangement != before.arrangement && definition.arrangement != window.arrangement
                ## The main instance changes from one item to another or to the full selection.
                window.arrangement = definition.arrangement
                window.presentation_revision += UInt(1)
                window.presentation_dirty = true
            end
            if definition.active_item != before.active_item
                window.active_item = definition.active_item
                window.presentation_dirty = true
            end
        end
        _sync_cell_settings!(window)
    end
    ## After a failure, the window keeps the value it has.
    if result.revision != window.revision && isempty(result.error)
        window.value, window.revision = result.value, result.revision
        window.presentation_revision += UInt(1)
        window.presentation_dirty = true
    end
    window.presentation_dirty && window.revision > 0 && _prepare_presentations!(state, window)
    ## A grid has no single output, and an instance that failed to prepare passes on the value.
    ## TODO: when several windows show one visualizer, the one that published last gives its output.
    if !preparing(window)
        passed = window.revision == 0 || window.arrangement == "grid" || !isempty(window.error) ? nothing :
            output(window.instance)
        published = (window.revision, passed)
        published === window.published || (Workspace.output!(v, published); window.published = published)
    end
    return result
end
