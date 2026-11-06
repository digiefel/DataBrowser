# An extension draws its windows with the function a visualizer draws with.
import DataBrowserAPI: draw!

"""
    GuiExtension

A package that adds to the browser, such as the plotting package, defines a subtype with a
constructor without arguments and registers it with [`register_gui_extension!`](@ref). The browser
makes one instance of each registered type when it opens, and calls the methods below on it. Each
method does nothing by default; an extension defines those it needs.
"""
abstract type GuiExtension end

"""The name under which the browser saves the view of `ext`: the name of its type."""
extension_id(ext::GuiExtension)::String = String(nameof(typeof(ext)))

"""Called once when the browser opens, before it draws anything."""
init!(ext::GuiExtension, state) = nothing

"""Called at each frame inside the menu bar of the main window, to add menus."""
menu!(ext::GuiExtension, state) = nothing

"""Called at each frame, to draw the windows of `ext`."""
draw!(ext::GuiExtension, state) = nothing

"""Called when the browser switches to another data source, to forget what belongs to the last one."""
reset!(ext::GuiExtension, state) = nothing

"""Called once when the browser closes, while the graphics context is still there."""
shutdown!(ext::GuiExtension, state) = nothing

"""
Whether `ext` is ready for the browser to show its full window. Until every extension is ready, the
browser shows a startup screen and calls [`warmup!`](@ref) at each frame. An extension that the
browser adds after its startup screen is prepared during the following frames instead. Return
quickly, without side effects.
"""
is_ready(ext::GuiExtension, state)::Bool = true

"""
Called at each frame of the startup screen while `ext` is not ready, after the screen has been
shown once. Slow one-time preparation, such as compiling, belongs here.
"""
warmup!(ext::GuiExtension, state) = nothing

"""The view of `ext` to save with the project, as a dictionary of TOML values."""
save_view(ext::GuiExtension, state)::Dict{String,Any} = Dict{String,Any}()

"""Restore the view of `ext` that [`save_view`](@ref) gave, when the project opens again."""
load_view!(ext::GuiExtension, state, view::Dict{String,Any}) = nothing

"""
Called inside the open menu of a row of the tree, to add entries to it. `item_ids()` gives the ids
of the items the menu applies to: the selected items when the item of the clicked row is one of
them, or else that item. Call it only when the user clicks an entry, because it takes time in
proportion to the selection. `label` is the label of the clicked item, and `kind` the name of its
type, or `nothing` while the item has no value yet, as a source item whose `read` runs or failed.
"""
item_context_menu!(ext::GuiExtension, state; item_ids, label, kind) = nothing

const _GUI_EXTENSION_TYPES = Type{<:GuiExtension}[]
# Packages register their types in `__init__`, which can run on any thread.
const _GUI_EXTENSION_LOCK = ReentrantLock()

"""
    register_gui_extension!(T)

Make the browser create an instance of the extension type `T` when it opens. An open browser
creates one at its next frame, so a package loaded while the browser is open can add to it.
Extensions are created and called in the order they were registered; registering a type again moves
it last.
"""
function register_gui_extension!(::Type{T}) where {T<:GuiExtension}
    @lock _GUI_EXTENSION_LOCK begin
        filter!(entry -> entry != T, _GUI_EXTENSION_TYPES)
        push!(_GUI_EXTENSION_TYPES, T)
    end
    return nothing
end

# One instance of each registered extension type.
_instantiate_extensions()::Vector{GuiExtension} =
    @lock _GUI_EXTENSION_LOCK GuiExtension[T() for T in _GUI_EXTENSION_TYPES]

"""
Add an instance of each extension type registered since the browser opened, and open the saved
windows that waited for a visualizer of its package.
"""
function _add_new_extensions!(state)::Nothing
    new = @lock _GUI_EXTENSION_LOCK filter(T -> !any(ext -> ext isa T, state.extensions), _GUI_EXTENSION_TYPES)
    isempty(new) && return nothing
    # The latest world: the package that defines the new types may have loaded during this frame.
    Base.invokelatest() do
        added = GuiExtension[T() for T in new]
        for ext in added
            init!(ext, state)
            view = get(state.saved_project_view.extensions, extension_id(ext), nothing)
            view === nothing || load_view!(ext, state, view)
        end
        # A new list, not a longer one: other threads may be reading the list.
        state.extensions = [state.extensions; added]
        _open_waiting_windows!(state)
        # FIXME: CImGui calls exit handlers in the world the render loop started in. That world lacks
        # the handlers that packages loaded since then registered, such as those of these extensions.
        handlers = ig._exit_handlers
        for (index, handler) in pairs(handlers)
            handler isa LatestCall || (handlers[index] = LatestCall(handler))
        end
    end
    return nothing
end

"""Calls `f` in the latest world when called."""
struct LatestCall <: Function
    f::Any
end
(call::LatestCall)() = Base.invokelatest(call.f)
