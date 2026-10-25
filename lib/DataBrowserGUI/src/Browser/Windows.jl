# The windows that show a value with a visualizer: which visualizers the browser offers, where a
# window takes its value from, and how the value reaches the visualizer. Nothing here draws.
#
# TODO: these are the actions a script will call (roadmap 0.6). They take the browser state for now.

import DataBrowserAPI
using DataBrowserAPI: AbstractVisualizer, id, label, prepare!, settings
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
output(window::Window) = something(output(window.visualizer), Some(window.value))

# What tells whether `input` gives another value than before: another stamp means another value.
# Item keys are never reused, so their hash tells the items apart without building their ids.
function stamp(input::Union{LiveSelection,FixedItems}, state::BrowserState)
    workspace = state.workspace::Workspace.Workspace
    items = itemkeys(input, state)
    return (workspace.scan.epoch, hash(items), Workspace.revision(workspace, items))
end
# A visualizer returns the same object until its output changes.
stamp(input::WindowOutput, state::BrowserState) = objectid(output(source(input, state)))

# The value `input` gives now: the items as a `Selection`. This runs in the calling task and waits
# for items that are not processed yet.
value(input::Union{LiveSelection,FixedItems}, state::BrowserState) =
    Workspace.select(state.workspace::Workspace.Workspace, itemkeys(input, state))
value(input::WindowOutput, state::BrowserState) = output(source(input, state))

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
    for method in methods(prepare!, Tuple{AbstractVisualizer,T,Any})
        V = Base.unwrap_unionall(method.sig).parameters[2]
        # `methods` also lists methods that accept only some values of type `T`.
        isconcretetype(V) && hasmethod(prepare!, Tuple{V,T,Any}) && push!(types, V)
    end
    return sort!(AbstractVisualizer[V() for V in types]; by=label)
end

# What `window` tells its visualizer. A window opened from it is drawn from the next frame on, as
# the browser draws a copy of its list of windows.
WindowContext(state::BrowserState, window::Window) = WindowContext(window.id, state.workspace,
    visualizer -> (transform!(open_window!(state, visualizer; input=window.input), window.transform); nothing))

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
    window = Window("window_$(state.next_window)", visualizer, input, nothing, (UInt(0), ""), String[], ItemKey[], nothing, nothing, "", "", "", "")
    push!(state.windows, window)
    return window
end

"""
Remove `window` from the browser. A window that took its value from `window` follows the selection
again.
"""
function close_window!(state::BrowserState, window::Window)::Nothing
    close(window.visualizer)
    computed!(state, window, String[])
    filter!(other -> other !== window, state.windows)
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
selection instead, and returns one value, such as a mean over the items. Each result is an item of
the workspace, under "Computed", computed in the background and computed again when an item it
reads or the code of the function changes. The visualizer shows the selection of these items,
whose data are the results.

A value of the input that is not a selection of items is passed to the function as it is.
"""
function transform!(window::Window, transform::Union{Nothing,GlobalRef})::Nothing
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
    close(window.visualizer)
    window.visualizer = visualizer
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
    visualizer = window.visualizer
    setproperty!(visualizer, name, value)
    settings(visualizer)[name].prepare && (window.stamp = nothing)
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
    input = window.input
    # The other window may not be visible. Its own drawing then does not bring it up to date.
    input isa WindowOutput && refresh!(state, source(input, state))
    workspace = state.workspace::Workspace.Workspace
    current = (stamp(input, state), window.transform, code(window),
        Workspace.revision(workspace, _items_for_ids(state, window.computed)))
    # The value is made again once the items it waits for are ready, or at once when the input
    # changed meanwhile.
    if !isempty(window.waiting)
        current == window.stamp && !Workspace.processed(workspace, window.waiting) && return nothing
        window.waiting = ItemKey[]
        window.stamp = nothing
    end
    current == window.stamp && return nothing
    window.stamp = current
    visualizer = window.visualizer
    ctx = WindowContext(state, window)
    # The computed items the window adds to the workspace: the rows another window passes on, then
    # the results of the transform.
    held = Workspace.Computed[]
    keys_of(values) = ItemKey[something(Workspace.item(workspace, id(value))) for value in values]
    # Whether `items` are ready. Otherwise the window waits for them, and keeps the computed items
    # it shows until it has a new value.
    function ready(items::Vector{ItemKey})::Bool
        Workspace.processed(workspace, items) && return true
        window.waiting = items
        computed!(state, window, union(window.computed, id.(held)))
        return false
    end
    # The computed items that failed, each with the first line of its error.
    failures = String[]
    # The selection of the computed items of `values` that were computed; the others are failures.
    function computed_selection(values)::Workspace.Selection
        ids = String[]
        for value in values
            try
                Workspace.wait_processed(workspace, keys_of([value]))
                push!(ids, id(value))
            catch err
                err isa ErrorException || rethrow()
                push!(failures, "$(label(value)): $(first(split(err.msg, '\n')))")
            end
        end
        return Workspace.select(workspace, ids)
    end
    try
        input isa WindowOutput || ready(itemkeys(input, state)) || return nothing
        given = value(input, state)
        if given isa Vector{Workspace.Computed}
            append!(held, given)
            foreach(value -> push!(workspace, value), held)
            ready(keys_of(held)) || return nothing
            given = computed_selection(held)
        end
        transform = window.transform
        if transform !== nothing
            try
                f = Base.invokelatest(getglobal, transform.mod, transform.name)
                if given isa Workspace.Selection
                    items = Workspace.items(given)
                    # A function with a method for a selection and none for its items combines the
                    # items: it gives one computed item for the whole selection.
                    whole = Base.invokelatest(hasmethod, f, Tuple{Workspace.Selection}) &&
                        !all(item -> Base.invokelatest(applicable, f, item), items)
                    results = whole ? [Workspace.Computed(f, given)] : [Workspace.Computed(f, item) for item in items]
                    foreach(value -> push!(workspace, value), results)
                    append!(held, results)
                    ready(keys_of(results)) || return nothing
                    given = computed_selection(results)
                else
                    # TODO: a value that is not a selection goes through the function in the frame.
                    given = Base.invokelatest(f, given)
                end
            catch err
                window.error, _ = DataBrowserAPI.report_error(
                    "Window: $(transform.name) failed", err, catch_backtrace())
                return nothing
            end
        end
        computed!(state, window, id.(held))
        window.value = given
        window.failed = join(failures, '\n')
        # TODO: `prepare!` runs in the frame; a visualizer that takes long to prepare stops it.
        if applicable(prepare!, visualizer, window.value, ctx)
            prepare!(visualizer, window.value, ctx)
            window.error = ""
        else
            given = window.value isa Workspace.Selection ? "a selection" :
                "a value of type $(nameof(typeof(window.value)))"
            window.error = "$(label(visualizer)) cannot show $given. Choose another visualizer."
        end
    catch err
        window.error, _ = DataBrowserAPI.report_error(
            "Window: $(label(visualizer)) could not show its value", err, catch_backtrace())
    end
    return nothing
end

# Keep `ids` as the computed items of `window`, and remove from the workspace those it kept before
# that no window keeps now.
function computed!(state::BrowserState, window::Window, ids::Vector{String})::Nothing
    before, window.computed = window.computed, ids
    kept = reduce(union, (other.computed for other in state.windows); init=String[])
    foreach(id -> delete!(state.workspace::Workspace.Workspace, id), setdiff(before, kept))
    return nothing
end
