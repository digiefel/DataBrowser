"""
    AbstractVisualizer

A way to show a value in a browser window, for example as a table or as a plot.

One visualizer belongs to one window. It holds the settings of that window and what it prepared for
drawing. A visualizer type `V` has:

- a constructor without arguments, `V()`, which the browser calls for a new window;
- a method `prepare!(visualizer::V, value, ctx)` for each type of value it shows;
- a method `draw!(visualizer::V, ctx)`.

It may also have:

- a method `settings(visualizer::V)`, the settings the user may change;
- a method `draw_header!(visualizer::V, ctx)`, for buttons in the header of the window;
- a method `export!(visualizer::V, ctx)`, for what "Export" in the header of the window does. The
  default saves a picture of what `draw!` draws;
- a method `output(visualizer::V)`, the value the window passes on to other windows;
- a method `Base.close(visualizer::V)`, to release what the visualizer holds outside Julia's
  memory, such as a figure on the graphics card. The browser calls it when the window closes or
  changes to another visualizer;
- a method `label(visualizer::V)`, the name of the visualizer in the menus of the browser. The
  default is the name of the type.

Defining the type and these methods is the whole registration: the browser finds a visualizer
through its `prepare!` methods.

`ctx` is what the browser tells the visualizer about its window:

- `ctx.id` names the window. It is unique in the browser and stays the same from frame to frame.
- `ctx.workspace` is the open workspace.
"""
abstract type AbstractVisualizer end

label(visualizer::AbstractVisualizer)::String = String(nameof(typeof(visualizer)))

Base.close(::AbstractVisualizer) = nothing

"""
    prepare!(visualizer, value, ctx)

Take `value` and store in `visualizer` what `draw!` needs. The browser calls `prepare!` when the
value of the window changes, not in every frame, so slow work belongs here.

The methods of `prepare!` also say which values a visualizer shows. The browser offers a visualizer
type for a value when a method written for that type accepts the value. Write one method for each
type of value the visualizer shows, with the concrete visualizer type as the first argument, and no
method that accepts everything else. The browser's "Value" visualizer, which shows any value as
text, is the one exception.

`prepare!` may throw. The window then shows the error in place of the value.
"""
function prepare! end

"""
    Setting(label; options=String[], prepare=true)

Describes one setting of a visualizer to the user. `label` names the setting in the window.

The type of the visualizer's field decides how the user changes the setting:

- a `Bool` field is a checkmark;
- a `String` field is a menu of `options`.

`prepare` says whether the visualizer must take its value again when the setting changes. Pass
`prepare=false` for a setting that only `draw!` reads.
"""
struct Setting
    label::String
    options::Vector{String}
    prepare::Bool
end

Setting(label::AbstractString; options=String[], prepare::Bool=true) =
    Setting(String(label), collect(String, options), prepare)

"""
    settings(visualizer) -> NamedTuple

The settings of `visualizer` that the user may change now. Each name is a field of the visualizer,
and each value is a [`Setting`](@ref). A visualizer without a method has no settings.

    settings(view::TableView) = (provenance_column=Setting("Provenance column"),)

The window draws the settings in its header, so `draw!` does not draw them. When the user changes
one, the browser writes the field. It then calls [`prepare!`](@ref) again, unless the setting says
`prepare=false`.

The browser calls `settings` in every frame, also before the first `prepare!`. Return quickly, and
return only the settings that apply to what the visualizer shows now.

Give each such field a default value. The constructor `V()` then makes a visualizer with the
default settings, and `V(name=value)` makes one with a setting already changed.
"""
settings(::AbstractVisualizer) = (;)

"""
    draw_header!(visualizer, ctx)

Draw the buttons of `visualizer` in the header of its window, after its settings. Use it for an
action, such as saving a figure. A choice that the visualizer keeps belongs in [`settings`](@ref),
where the browser can draw it.

The browser calls `draw_header!` in every frame in which the window is visible. Draw the buttons in
one row.
"""
draw_header!(::AbstractVisualizer, ctx) = nothing

"""
    export!(visualizer, ctx)

Save what the window of `visualizer` shows. The browser calls `export!` when the user clicks
"Export", which every window has in its header.

The default asks for a file and saves there, as PNG, a picture of what [`draw!`](@ref) draws,
without the title and the header of the window. A visualizer that can
save its value better has its own method: a table saves CSV, a plot saves PDF or SVG. Most
methods ask for a file, but `export!` may do anything that saves the value.

`export!` may throw. The window then shows the error above its value.
"""
function export! end

"""
    draw!(visualizer, ctx)

Draw what `prepare!` stored. The browser calls `draw!` in every frame in which the window is
visible, inside the window and below its header, and only after `prepare!` succeeded.
"""
function draw! end

"""
    output(visualizer)

The value the window of `visualizer` passes on to a window that takes its input from it. For
example, a table passes on the rows the user selected, and another window plots them.

A visualizer without a method passes on the value it was given, and so does one that returns
`nothing`.

The browser reads the output in every frame, and hands it to the other window when it is another
object than before. Keep the output in a field and return that field; replace the object when the
output changes.
"""
output(::AbstractVisualizer) = nothing
