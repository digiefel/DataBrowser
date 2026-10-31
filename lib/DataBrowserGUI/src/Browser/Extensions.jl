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

"""Called once when the browser opens, before it draws anything; `state.workspace` is not set yet."""
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
browser shows a startup screen and calls [`warmup!`](@ref) at each frame. Return quickly, without
side effects.
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
Called inside the open menu of an item in the item panel, to add entries to it. `item_ids()` gives
the ids of the items the menu applies to: the selected items when the clicked item is one of them,
or else the clicked item. Call it only when the user clicks an entry, because it takes time in
proportion to the selection. `label` is the label of the clicked item, and `kind` the name of its
type.
"""
item_context_menu!(ext::GuiExtension, state; item_ids, label, kind) = nothing

const _GUI_EXTENSION_TYPES = Type{<:GuiExtension}[]

"""
    register_gui_extension!(T)

Make the browser create an instance of the extension type `T` when it opens. Extensions are created
and called in the order they were registered; registering a type again moves it last.
"""
function register_gui_extension!(::Type{T}) where {T<:GuiExtension}
    filter!(entry -> entry != T, _GUI_EXTENSION_TYPES)
    push!(_GUI_EXTENSION_TYPES, T)
    return nothing
end

# One instance of each registered extension type.
_instantiate_extensions()::Vector{GuiExtension} = [T() for T in _GUI_EXTENSION_TYPES]
