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
    return PersistedProjectView(
        window_size=Int[GLFW.GetWindowSize(ig.current_window())...],
        window_position=Int[GLFW.GetWindowPos(ig.current_window())...],
        selected=copy(workspace.selection.item_ids),
        expanded=sort!(collect(state.expanded)),
        filter=state.tree_filter,
        extensions=_persisted_extensions(state),
        windows=[[_persisted_window(window) for window in state.windows]; _waiting_windows(state)],
    )
end

"""The saved windows whose visualizer is not loaded now. They stay in the file to open later."""
_waiting_windows(state::BrowserState)::Vector{PersistedWindow} =
    filter(window -> _visualizer_type(window.visualizer) === nothing, state.saved_project_view.windows)

function _persisted_window(window::Window)::PersistedWindow
    preparing(window) && return window.preparation.saved
    input = window.input
    visualizer = window.visualizer
    # A setting is saved as TOML text, number or boolean; a symbol as its text.
    values = Dict{String,Any}()
    for name in keys(settings(visualizer))
        value = getproperty(visualizer, name)
        value isa Symbol && (value = String(value))
        value isa Union{AbstractString,Real} && (values[String(name)] = value)
    end
    return PersistedWindow(
        id=window.id,
        arrangement=window.arrangement,
        active_item=window.active_item,
        visualizer=String(nameof(typeof(visualizer))),
        input=input isa FixedItems ? "items" : input isa WindowOutput ? "window" : "selection",
        ids=input isa FixedItems ? copy(input.ids) : input isa WindowOutput ? [input.window] : String[],
        transform=window.transform === nothing ? "" : String(window.transform.name),
        settings=values,
        selection=Dict{String,Any}(String(name) => value for (name, value) in pairs(selection(visualizer))),
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
Open the saved windows again. A window whose visualizer is not loaded now is not opened, and stays
in the file until its visualizer loads; then `_open_waiting_windows!` opens it.
"""
function _restore_windows!(state::BrowserState, saved::Vector{PersistedWindow})::Nothing
    foreach(window -> close_window!(state, window), copy(state.windows))
    for window in saved
        V = _visualizer_type(window.visualizer)
        V === nothing || _open_saved_window!(state, window, V)
    end
    # New windows take ids after the saved ones, also those not opened, so ImGui does not give
    # them a saved place.
    numbers = [parse(Int, m.captures[1]) for m in
        (match(r"^window_(\d+)$", window.id) for window in saved) if m !== nothing]
    state.next_window = maximum(numbers; init=0)
    return nothing
end

"""Open the saved windows whose visualizer has loaded since the browser opened."""
function _open_waiting_windows!(state::BrowserState)::Nothing
    for window in state.saved_project_view.windows
        any(open -> open.id == window.id, state.windows) && continue
        V = _visualizer_type(window.visualizer)
        V === nothing || _open_saved_window!(state, window, V)
    end
    return nothing
end

"""Open the saved `window` with a new visualizer of type `V`."""
function _open_saved_window!(state::BrowserState, window::PersistedWindow, V::Type)::Nothing
    values = Pair{Symbol,Any}[]
    for (key, value) in window.settings
        name = Symbol(key)
        hasfield(V, name) || continue
        push!(values, name => fieldtype(V, name) === Symbol ? Symbol(value) : value)
    end
    # TODO: a window of fixed items that are replaced while the browser is open keeps the old ids.
    input = window.input == "items" ? FixedItems([Workspace.replacement(state.workspace.selection, id) for id in window.ids]) :
        window.input == "window" ? WindowOutput(only(window.ids)) : LiveSelection()
    visualizer = V(; values...)
    # A dynamic call: packages add `select!` methods for their visualizers when they load, and a static
    # call would make each of them invalidate the compiled code here.
    isempty(window.selection) ||
        Base.invokelatest(select!, visualizer; (Symbol(name) => value for (name, value) in window.selection)...)
    opened = open_window!(state, visualizer; input)
    opened.id = window.id
    opened.arrangement = window.arrangement
    opened.active_item = window.active_item
    opened.initial_size_pending = false
    isempty(window.transform) || transform!(opened, GlobalRef(Main, Symbol(window.transform)))
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
    # The items replaced since the view was saved are selected by their new ids.
    # Not `select!`: the saved ids may name items the workspace does not have yet.
    # TODO: restore the selection through a workspace operation (see the TODO above).
    workspace.selection.item_ids = unique!([Workspace.replacement(workspace.selection, id) for id in view.selected])
    workspace.selection.revision += 1
    state.selection_revision = workspace.selection.revision
    state.tree_filter = view.filter
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
twice a second at most; `every=0` compares it now, as when the browser closes.
"""
function _save_project_view_if_changed!(state::BrowserState; every::Real=0.5)::Nothing
    # A failed initial restore must not overwrite the saved view with startup defaults.
    isempty(state.loaded_source_id) && return nothing
    # Building and serializing the view at every frame allocates in proportion to the selection.
    time() - state.project_view_checked < every && return nothing
    state.project_view_checked = time()
    view = _project_view_from_browser(state)
    _project_view_to_toml(state.saved_project_view) ==
        _project_view_to_toml(view) && return nothing
    ## The file holds one table for each project: the tables of other projects stay.
    path = joinpath(state.workspace.folder, PROJECT_VIEW_FILENAME)
    views = isfile(path) ? TOML.parsefile(path) : Dict{String,Any}()
    views[project_name(state.workspace.project)] = _project_view_to_toml(view)
    open(io -> TOML.print(io, views), path, "w")
    state.saved_project_view = view
    return nothing
end
