"""
    AbstractVisualizer

A way to show a value in a browser window, for example as a table or as a plot.

One visualizer belongs to one window. It holds the settings of that window and what it prepared for
drawing. A visualizer type `V` has:

- a constructor without arguments, `V()`, which the browser calls for a new window;
- a method `prepare!(visualizer::V, value)` for each type of value it shows;
- a method `draw!(visualizer::V, ctx)`;
- optionally a method `settings(visualizer::V, value)`, the settings the user may change;
- optionally a method `label(visualizer::V)`, the name of the visualizer in the menus of the
  browser. The default is the name of the type.

Defining the type and these methods is the whole registration: the browser finds a visualizer
through its `prepare!` methods.
"""
abstract type AbstractVisualizer end

label(visualizer::AbstractVisualizer)::String = String(nameof(typeof(visualizer)))

"""
    prepare!(visualizer, value)

Take `value` and store in `visualizer` what `draw!` needs. The browser calls `prepare!` when the
value of the window changes, not in every frame, so slow work belongs here.

The methods of `prepare!` also say which values a visualizer shows. The browser offers a visualizer
type for a value when a method written for that type accepts the value. Write one method for each
type of value the visualizer shows, with the concrete visualizer type as the first argument, and no
method that accepts everything else.

`prepare!` may throw. The window then shows the error in place of the value.
"""
function prepare! end

"""
    Setting(label)

Describes one setting of a visualizer to the user. `label` names the setting in the window.

The type of the visualizer's field decides how the user changes the setting: a `Bool` field is a
checkmark.
"""
struct Setting
    # TODO: the values the user may choose from, for a setting that is one of several names.
    label::String
end

"""
    settings(visualizer, value) -> NamedTuple

The settings of `visualizer` that the user may change while it shows `value`. Each name is a field
of the visualizer, and each value is a [`Setting`](@ref). A visualizer without a method has no
settings.

    settings(view::TableView, items) = (provenance_column=Setting("Provenance column"),)

The window draws the settings in its header. When the user changes one, the browser
writes the field and calls [`prepare!`](@ref) again, so `draw!` does not draw a setting and does
not watch it for changes.

Give each such field a default value. The constructor `V()` then makes a visualizer with the
default settings, and `V(name=value)` makes one with a setting already changed.
"""
settings(::AbstractVisualizer, value) = (;)

"""
    draw!(visualizer, ctx)

Draw what `prepare!` stored. The browser calls `draw!` in every frame in which the window is
visible, inside the window and below its header, and only after `prepare!` succeeded.

`ctx` is what the browser tells the visualizer about its window. `ctx.id` names the window: it is
unique in the browser and stays the same from frame to frame.
"""
function draw! end
