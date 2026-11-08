using TOML
import GLFW

using DataBrowserAPI: AbstractVisualizer, prepare!, project_name, select!, selection, settings
import DataBrowserCore.Workspace

# ---------------------------------------------------------------------------
# The view of the browser, saved in `databrowser.toml`
# ---------------------------------------------------------------------------

const PROJECT_VIEW_FILENAME = "databrowser.toml"

"""
Decode TOML values according to the fields of the requested browser-state type.

Missing fields use the type defaults; incorrectly typed fields are errors.
"""
function _project_view_from_toml(::Type{String}, value::Any)::String
    value isa AbstractString || error("Expected string, got $(typeof(value))")
    return String(value)
end

function _project_view_from_toml(::Type{Bool}, value::Any)::Bool
    value isa Bool || error("Expected boolean, got $(typeof(value))")
    return value
end

function _project_view_from_toml(::Type{Int}, value::Any)::Int
    value isa Integer && !(value isa Bool) || error("Expected integer, got $(typeof(value))")
    return Int(value)
end

function _project_view_from_toml(::Type{Vector{T}}, value::Any)::Vector{T} where {T}
    value isa AbstractVector || error("Expected array, got $(typeof(value))")
    return [_project_view_from_toml(T, item) for item in value]
end

function _project_view_from_toml(::Type{Dict{String,String}}, value::Any)::Dict{String,String}
    value isa AbstractDict || error("Expected table, got $(typeof(value))")
    return Dict(String(key) => _project_view_from_toml(String, item) for (key, item) in value)
end

function _project_view_from_toml(
    ::Type{Dict{String,Dict{String,Any}}},
    value::Any,
)::Dict{String,Dict{String,Any}}
    value isa AbstractDict || error("Expected table, got $(typeof(value))")
    return Dict(
        String(key) => Dict{String,Any}(
            String(inner_key) => inner_value
            for (inner_key, inner_value) in item
        )
        for (key, item) in value
    )
end

function _project_view_from_toml(::Type{Dict{String,Any}}, value::Any)::Dict{String,Any}
    value isa AbstractDict || error("Expected table, got $(typeof(value))")
    return Dict{String,Any}(String(key) => item for (key, item) in value)
end

function _project_view_from_toml(::Type{T}, data::Any)::T where {T}
    data isa AbstractDict || error("Expected table for $T, got $(typeof(data))")
    defaults = T()
    return T(; (
        name => begin
            key = String(name)
            haskey(data, key) ?
                _project_view_from_toml(fieldtype(T, name), data[key]) :
                getfield(defaults, name)
        end
        for name in fieldnames(T)
    )...)
end

_project_view_to_toml(value::AbstractString)::String = String(value)
_project_view_to_toml(value::Bool)::Bool = value
_project_view_to_toml(value::Real)::Real = value
_project_view_to_toml(value::AbstractVector)::Vector = [_project_view_to_toml(item) for item in value]
_project_view_to_toml(value::AbstractDict)::Dict{String,Any} =
    Dict{String,Any}(String(key) => _project_view_to_toml(item) for (key, item) in value)

"""Convert persisted browser-state structs into values accepted by `TOML.print`."""
function _project_view_to_toml(value::Any)::Dict{String,Any}
    return Dict{String,Any}(
        String(name) => _project_view_to_toml(getfield(value, name))
        for name in fieldnames(typeof(value))
    )
end

"""
Read the saved view of the workspace's project: its table in `databrowser.toml`, in the folder of
the workspace. Without the file or the table, the view has the defaults.
"""
function _load_project_view(workspace::Workspace.Workspace)::PersistedProjectView
    path = joinpath(workspace.folder, PROJECT_VIEW_FILENAME)
    views = isfile(path) ? TOML.parsefile(path) : Dict{String,Any}()
    return _project_view_from_toml(
        PersistedProjectView, get(views, project_name(workspace.project), Dict{String,Any}()))
end

"""Capture the browser controls that `databrowser.toml` saves."""
function _project_view_from_browser(
    state::BrowserState,
)::PersistedProjectView
    workspace = state.workspace
    ## An order that code set has no keys: the saved keys stay in the file.
    by = Workspace.order(workspace)
    return PersistedProjectView(
        window_size=Int[GLFW.GetWindowSize(ig.current_window())...],
        window_position=Int[GLFW.GetWindowPos(ig.current_window())...],
        selected=copy((@atomic workspace.shared).selection),
        expanded=sort!(collect(state.expanded)),
        filter=state.tree_filter,
        sort=by isa Workspace.SortKeys ? [[String(key), reverse ? "descending" : "ascending"] for (key, reverse) in by.keys] :
            state.saved_project_view.sort,
        extensions=_persisted_extensions(state),
        windows=[[_persisted_window(state, window) for window in state.windows]; _waiting_windows(state)],
    )
end

"""The saved windows whose visualizer is not loaded now. They stay in the file to open later."""
_waiting_windows(state::BrowserState)::Vector{PersistedWindow} =
    filter(window -> _visualizer_type(window.visualizer) === nothing, state.saved_project_view.windows)

function _persisted_window(state::BrowserState, window::Window)::PersistedWindow
    (; type, settings, input, transform, arrangement, active_item) = @atomic window.visualizer.definition
    # A setting is saved as TOML text, number or boolean; a symbol as its text.
    values = Dict{String,Any}()
    for (name, value) in pairs(settings)
        value isa Symbol && (value = String(value))
        value isa Union{AbstractString,Real} && (values[String(name)] = value)
    end
    ## An input visualizer is saved as the first window that shows it.
    # TODO: an input visualizer that no window shows, and a function, are saved as the selection.
    # Save visualizers with the tab file (@layout, 7 Nov).
    shown = input isa Workspace.Visualizer ? findfirst(other -> other.visualizer === input, state.windows) : nothing
    return PersistedWindow(;
        id=window.id,
        arrangement,
        active_item,
        visualizer=String(nameof(type)),
        input=input isa Workspace.FixedItems ? "items" : shown !== nothing ? "window" : "selection",
        ids=input isa Workspace.FixedItems ? copy(input.ids) : shown !== nothing ? [state.windows[shown].id] : String[],
        transform=transform === nothing ? "" : String(transform.name),
        settings=values,
        selection=preparing(window) ? window.preparation.selection :
            Dict{String,Any}(String(name) => value for (name, value) in pairs(selection(window.instance))),
    )
end

"""The loaded visualizer type named `name`: one with a `prepare!` method, as the browser offers."""
function _visualizer_type(name::AbstractString)::Union{Nothing,Type}
    for method in methods(prepare!)
        V = Base.unwrap_unionall(method.sig).parameters[2]
        V isa DataType && V <: AbstractVisualizer && isconcretetype(V) && String(nameof(V)) == name &&
            return V
    end
    return nothing
end

"""
Open the saved windows again, in place of those the browser shows. A window whose visualizer is not
loaded now is not opened, and stays in the file until its visualizer loads; then
`_open_saved_windows!` opens it.
"""
function _restore_windows!(state::BrowserState, saved::Vector{PersistedWindow})::Nothing
    # TODO: when the browser opens again on a workspace, the visualizers of the windows it showed
    # before stay beside those it opens. Save visualizers with the tab file (@layout, 7 Nov).
    foreach(window -> (close(window.visualizer); _close_window!(state, window)), copy(state.windows))
    _open_saved_windows!(state, saved)
    # New windows take ids after the saved ones, also those not opened, so ImGui does not give
    # them a saved place.
    numbers = [parse(Int, m.captures[1]) for m in
        (match(r"^window_(\d+)$", window.id) for window in saved) if m !== nothing]
    state.next_window[] = maximum(numbers; init=0)
    return nothing
end

"""
Open the saved windows that the browser does not show, when their visualizer is loaded, each with a
new visualizer of the workspace.
"""
function _open_saved_windows!(state::BrowserState, saved::Vector{PersistedWindow})::Nothing
    ## The windows that `visualize!` opened since the last frame are open too.
    while isready(state.opening)
        push!(state.windows, take!(state.opening))
    end
    opened = Pair{PersistedWindow,Window}[]
    for window in saved
        any(open -> open.id == window.id, state.windows) && continue
        V = _visualizer_type(window.visualizer)
        V === nothing && continue
        values = Pair{Symbol,Any}[]
        for (key, value) in window.settings
            name = Symbol(key)
            hasfield(V, name) || continue
            push!(values, name => fieldtype(V, name) === Symbol ? Symbol(value) : value)
        end
        instance = V(; values...)
        # A dynamic call: packages add `select!` methods for their visualizers when they load, and a
        # static call would make each of them invalidate the compiled code here.
        isempty(window.selection) ||
            Base.invokelatest(select!, instance; (Symbol(name) => value for (name, value) in window.selection)...)
        v = visualize!(state.workspace, instance;
            input=window.input == "items" ? Workspace.FixedItems(collect(String, window.ids)) : Workspace.LiveSelection())
        Workspace.arrangement!(v, window.arrangement)
        Workspace.active_item!(v, window.active_item)
        isempty(window.transform) || Workspace.transform!(v, GlobalRef(Main, Symbol(window.transform)))
        w = visualize!(state, v, instance)
        w.id = window.id
        w.initial_size_pending = false
        push!(opened, window => w)
    end
    ## A window that took its value from another one takes it again, when that window is open.
    # TODO: a window that follows one whose visualizer loads later follows the selection.
    windows = [state.windows; last.(opened)]
    for (window, w) in opened
        window.input == "window" || continue
        i = findfirst(other -> other.id == only(window.ids), windows)
        i === nothing || Workspace.input!(w.visualizer, windows[i].visualizer)
    end
    return nothing
end

"""Merge extension save views with any persisted ids not loaded this session."""
function _persisted_extensions(state::BrowserState)::Dict{String,Dict{String,Any}}
    extensions = Dict{String,Dict{String,Any}}()
    for (id, view) in state.saved_project_view.extensions
        extensions[id] = copy(view)
    end
    for ext in state.extensions
        extensions[extension_id(ext)] = save_view(ext, state)
    end
    return extensions
end

"""Apply a saved view to the browser controls and the workspace selection."""
# TODO: Expose view restoration through the browser session API.
function _apply_project_view!(
    state::BrowserState,
    view::PersistedProjectView,
)::Nothing
    workspace = state.workspace
    state.expanded = Set(view.expanded)
    # Not `select!`: the saved ids may name items the workspace does not have yet. The browser
    # restores the selection without revealing it.
    # TODO: `select!`, once it keeps the ids of items that come later (docs/plans/client-api.md).
    state.selection = collect(String, view.selected)
    Workspace.share!(_ -> (; selection=state.selection), workspace)
    state.tree_filter = view.filter
    ## The order of the Sort menu, unless code set an order with `sort!`.
    if !isempty(view.sort) && Workspace.order(workspace) isa Workspace.SortKeys
        order = Workspace.SortKeys([Symbol(key) => direction == "descending" for (key, direction) in view.sort])
        sort!(workspace; by=order, lt=order)
    end
    _restore_windows!(state, view.windows)

    for ext in state.extensions
        id = extension_id(ext)
        haskey(view.extensions, id) && load_view!(ext, state, view.extensions[id])
    end

    _reset_tree_filter!(state)
    return nothing
end

"""
Write the view to `databrowser.toml` only when its serialized value changed. The frames compare it
twice a second at most, and a task writes the file; `every=0` compares it now and waits for the
file, as when the browser closes.
"""
function _save_project_view_if_changed!(state::BrowserState; every::Real=0.5)::Nothing
    # A failed initial restore must not overwrite the saved view with startup defaults.
    isempty(state.loaded_source_id) && return nothing
    # Building and serializing the view at every frame allocates in proportion to the selection.
    time() - state.project_view_checked < every && return nothing
    ## One write at a time: the frames compare the view again after the running write.
    writing = state.project_view_write
    if writing !== nothing && !istaskdone(writing)
        every == 0 || return nothing
        wait(writing; throw=false)
    end
    state.project_view_checked = time()
    view = _project_view_from_browser(state)
    toml = _project_view_to_toml(view)
    _project_view_to_toml(state.saved_project_view) == toml && return nothing
    state.saved_project_view = view
    ## The file holds one table for each project: the tables of other projects stay. Writing many
    ## selected ids takes tens of milliseconds.
    path = joinpath(state.workspace.folder, PROJECT_VIEW_FILENAME)
    project = project_name(state.workspace.project)
    writing = errormonitor(Threads.@spawn begin
        views = isfile(path) ? TOML.parsefile(path) : Dict{String,Any}()
        views[project] = toml
        open(io -> TOML.print(io, views), path, "w")
    end)
    state.project_view_write = writing
    every == 0 && wait(writing; throw=false)
    return nothing
end
