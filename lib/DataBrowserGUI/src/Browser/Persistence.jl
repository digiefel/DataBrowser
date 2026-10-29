using TOML

using DataBrowserAPI: AbstractVisualizer, prepare!, project_name, settings
using DataBrowserCore.Catalogs: ItemKey
import DataBrowserCore.Workspace

"""Convert a user path into the stable absolute form used by persistence."""
function _normalize_project_path(path::AbstractString)::String
    return normpath(abspath(expanduser(String(path))))
end

# ---------------------------------------------------------------------------
# Project-local browser state
# ---------------------------------------------------------------------------

const PROJECT_VIEW_FILENAME = "databrowser.toml"

function _project_view_file_path(root_path::AbstractString)::String
    return joinpath(_normalize_project_path(root_path), PROJECT_VIEW_FILENAME)
end

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

function _project_view_from_toml(::Type{Tuple{String,String}}, value::Any)::Tuple{String,String}
    value isa AbstractVector && length(value) == 2 ||
        error("Expected an array of a type name and an id, got $(repr(value))")
    return (_project_view_from_toml(String, value[1]), _project_view_from_toml(String, value[2]))
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
_project_view_to_toml(value::Tuple)::Vector = [_project_view_to_toml(item) for item in value]
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

"""Read project-local browser state when it exists."""
function _load_project_view(root_path::AbstractString)::PersistedProjectView
    path = _project_view_file_path(root_path)
    isfile(path) || return PersistedProjectView()
    return _project_view_from_toml(
        PersistedProjectView,
        TOML.parsefile(path),
    )
end

"""Write project-local browser state beside the source data."""
function _save_project_view(root_path::AbstractString, view::PersistedProjectView)::Nothing
    open(_project_view_file_path(root_path), "w") do io
        TOML.print(io, _project_view_to_toml(view))
    end
    return nothing
end

"""Resolve stable item ids against the items the workspace has now."""
function _items_for_ids(
    state::BrowserState,
    ids::Vector{String},
)::Vector{ItemKey}
    workspace = state.workspace
    workspace isa Workspace.Workspace || return ItemKey[]
    return ItemKey[
        item for item in (Workspace.item(workspace, id) for id in ids) if item !== nothing]
end

"""Capture the browser controls that belong in the source-root state file."""
function _project_view_from_browser(
    state::BrowserState,
)::Union{Nothing,PersistedProjectView}
    workspace = state.workspace
    workspace isa Workspace.Workspace || return nothing

    return PersistedProjectView(
        project=project_name(workspace.project),
        tree=PersistedTreeView(
            expanded=copy(state.expanded_collections),
            selected=copy(workspace.selection.collections),
            filter=state.tree_filter,
        ),
        items=PersistedItemsView(
            selected=copy(workspace.selection.item_ids),
            filter=state.item_filter,
        ),
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
in the file until the browser opens with its visualizer loaded.
"""
function _restore_windows!(state::BrowserState, saved::Vector{PersistedWindow})::Nothing
    foreach(window -> close_window!(state, window), copy(state.windows))
    for window in saved
        V = _visualizer_type(window.visualizer)
        if V === nothing
            @warn "A saved window is not opened until a visualizer called $(window.visualizer) is loaded"
            continue
        end
        values = Pair{Symbol,Any}[]
        for (key, value) in window.settings
            name = Symbol(key)
            hasfield(V, name) || continue
            push!(values, name => fieldtype(V, name) === Symbol ? Symbol(value) : value)
        end
        # TODO: a window of fixed items that are replaced while the browser is open keeps the old ids.
        replaced = state.workspace.selection.replaced
        input = window.input == "items" ? FixedItems([get(replaced, id, id) for id in window.ids]) :
            window.input == "window" ? WindowOutput(only(window.ids)) : LiveSelection()
        opened = open_window!(state, V(; values...); input)
        opened.id = window.id
        opened.arrangement = window.arrangement
        opened.active_item = window.active_item
        opened.initial_size_pending = false
        isempty(window.transform) || transform!(opened, GlobalRef(Main, Symbol(window.transform)))
    end
    # New windows take ids after the saved ones, also those not opened, so ImGui does not give
    # them a saved place.
    numbers = [parse(Int, m.captures[1]) for m in
        (match(r"^window_(\d+)$", window.id) for window in saved) if m !== nothing]
    state.next_window = maximum(numbers; init=0)
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

"""Apply loaded project-local state to browser controls and workspace selection."""
# TODO: Expose view restoration through the browser session API.
function _apply_project_view!(
    state::BrowserState,
    view::PersistedProjectView,
)::Nothing
    workspace = state.workspace::Workspace.Workspace
    state.expanded_collections = copy(view.tree.expanded)
    workspace.selection.collections = copy(view.tree.selected)
    # The items replaced since the view was saved are selected by their new ids.
    replaced = workspace.selection.replaced
    workspace.selection.item_ids = unique!([get(replaced, id, id) for id in view.items.selected])
    state.tree_filter = view.tree.filter
    state.item_filter = view.items.filter
    _restore_windows!(state, view.windows)

    for ext in state.extensions
        id = extension_id(ext)
        haskey(view.extensions, id) && load_view!(ext, state, view.extensions[id])
    end

    _reset_project_filter_widgets!(state)
    return nothing
end

"""
Write project-local state only when its serialized value changed. The frames compare it twice a
second at most; `every=0` compares it now, as when the browser closes.
"""
function _save_project_view_if_changed!(state::BrowserState; every::Real=0.5)::Nothing
    # Building and serializing the view at every frame allocates in proportion to the selection.
    time() - state.project_view_checked < every && return nothing
    state.project_view_checked = time()
    view = _project_view_from_browser(state)
    view === nothing && return nothing
    _project_view_to_toml(state.saved_project_view) ==
        _project_view_to_toml(view) && return nothing
    workspace = state.workspace::Workspace.Workspace
    hasproperty(workspace.source, :root_path) || return nothing
    _save_project_view(workspace.source.root_path, view)
    state.saved_project_view = view
    return nothing
end
