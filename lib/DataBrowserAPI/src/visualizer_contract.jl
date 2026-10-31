"""
    AbstractVisualizer

A way to show a value in a browser window, for example as a table or as a plot.

A window owns its settings. In Stack the browser passes one selected item's value to one
visualizer. In Grid it manages one visualizer instance per item, with the same declared settings
and separate prepared data and drawing state. The visualizer does not need to know either mode.
Each instance receives its own stable `ctx.id`, including when several draw in the same window.

A visualizer that accepts a whole selection through `prepare!` also supports Overlay: it receives
the selection together and decides how to present its items. Selection-only visualizers receive
a one-item selection in Stack and Grid so they retain the item's metadata.

An instance holds what it prepared for drawing. A visualizer type `V` has:

- a constructor without arguments, `V()`, which the browser calls for a new window;
- a method `prepare!(visualizer::V, value, ctx)` for each type of value it shows;
- a method `draw!(visualizer::V, ctx)`.

It may also have:

- a method `settings(visualizer::V)`, the settings the user may change;
- a method `initial_size(visualizer::V)`, the default width and height of a new window;
- a method `draw_header!(visualizer::V, ctx)`, for buttons in the header of the window;
- a method `show(io, mime, visualizer::V)` for each MIME type that the Export button in the
  header of the window saves, such as `MIME"application/pdf"`, and `showable(mime, visualizer::V)`
  when those types depend on the state of the visualizer. See [`export!`](@ref);
- a method `output(visualizer::V)`, the value the window passes on to other windows;
- methods `select!(visualizer::V; keywords...)` and `selection(visualizer::V)`, to select from code
  what the user selects in the window, such as some rows. The browser saves the selection with the
  window. See [`select!`](@ref);
- a method `Base.close(visualizer::V)`, to release what the visualizer holds outside Julia's
  memory, such as a figure on the graphics card. The browser calls it when the window closes or
  changes to another visualizer, on the UI thread and after any preparation has finished;
- a method `label(visualizer::V)`, the name of the visualizer in the menus of the browser. The
  default is the name of the type.

Defining the type and these methods is the whole registration: the browser finds a visualizer
through its `prepare!` methods.

`ctx` is what the browser tells the visualizer about its window:

- `ctx.id` names the window. It is unique in the browser and stays the same from frame to frame.
- `ctx.workspace` is the open workspace.
- `ctx.open_window(visualizer)` opens a new window that shows the value of this window with
  `visualizer`: it takes its value from the same input and passes it through the same function.
  The window opens after this frame.
- `ctx.prepare()` requests preparation again with the current input, for example after an action
  in `draw!` changes what must be prepared. The request takes effect after drawing returns.

The browser keeps the same instance throughout its lifetime. During background preparation it
keeps its last rendered contents visible, shows a loading indicator in the title, and pauses all
other access to that instance, including its controls, drawing, export and output. Other windows
remain usable. Browser actions on `ctx` are available only to UI callbacks, such as `draw!` and
`draw_header!`.
"""
abstract type AbstractVisualizer end

"""
    initial_size(visualizer) -> (width, height)

Default size of a new visualizer window, in ImGui pixels. The default is `(900, 600)`.
The browser applies it when creating a new window. Restored windows keep their saved size,
and users can resize windows afterward. A docked window takes the size of its docking region.
"""
initial_size(::AbstractVisualizer) = (900, 600)

label(visualizer::AbstractVisualizer)::String = String(nameof(typeof(visualizer)))

Base.close(::AbstractVisualizer) = nothing

"""
    prepare!(visualizer, value, ctx)

Take `value` and store in `visualizer` what `draw!` needs. The browser calls `prepare!` when the
value of the window changes, not in every frame, so slow work belongs here.

Preparation runs on a worker with exclusive access to the same visualizer instance. Its settings
and interaction state remain in that instance. Treat `value` as read-only, and finish all work on
the instance before returning; do not leave a task modifying it afterward. Do not call ImGui,
browser UI actions, or graphics operations that require the UI thread. A plot may construct a new,
unattached Figure here; attachment and release of graphics resources belong to UI callbacks.

The methods of `prepare!` also say which values a visualizer shows. The browser offers a visualizer
type for a value when a method written for that type accepts the value. Write one method for each
type of value the visualizer shows, with the concrete visualizer type as the first argument, and no
method that accepts everything else. The browser's "Value" visualizer, which shows any value as
text, is the one exception.

`prepare!` may throw. The window then shows the error in place of the value.
"""
function prepare! end

"""
    Setting(label; options=String[], prepare=true, visible=true)

Describes one setting of a visualizer to the user. `label` names the setting in the window.

The type of the visualizer's field decides how the user changes the setting:

- a `Bool` field is a checkmark;
- an `Int` field is a numeric input with step buttons;
- a `Float64` field is a numeric input;
- a `String` field is a menu of `options`, or a text field when there are no options.

`prepare` says whether the visualizer must take its value again when the setting changes. Pass
`prepare=false` for a setting that only `draw!` reads.
Pass `visible=false` to hide a control in the current mode while retaining its saved value.
"""
struct Setting
    label::String
    options::Vector{String}
    prepare::Bool
    visible::Bool
end

Setting(label::AbstractString; options=String[], prepare::Bool=true, visible::Bool=true) =
    Setting(String(label), collect(String, options), prepare, visible)

"""
    settings(visualizer) -> NamedTuple

The settings of `visualizer` that the user may change now. Each name is a field of the visualizer,
and each value is a [`Setting`](@ref). A visualizer without a method has no settings.

    settings(::LinePlotView) = (markers=Setting("Markers"; prepare=false),)

The window draws the settings in its header, so `draw!` does not draw them. When the user changes
one, the browser writes the field. It then calls [`prepare!`](@ref) again, unless the setting says
`prepare=false`.

Grid copies these declared settings to its instances. Keep per-item prepared data and transient
interaction state out of `settings`. A choice made by `draw_header!` must also be a declared setting
if it should be shared across Grid cells.

The browser calls `settings` in every frame, also before the first `prepare!`. Return quickly, and
hide controls that do not apply to the current mode with `visible=false`.
Calls pause while preparation owns the instance.

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

# The MIME type of each file extension that `export!` saves, in the order the Export button
# offers them.
# TODO: let a visualizer that saves another type of file add its extension.
const MIME_TYPES = [
    ".png" => MIME("image/png"),
    ".pdf" => MIME("application/pdf"),
    ".svg" => MIME("image/svg+xml"),
    ".eps" => MIME("application/postscript"),
    ".jpg" => MIME("image/jpeg"),
    ".csv" => MIME("text/csv"),
]

"""
    export!(visualizer, path; options...)

Save what `visualizer` shows to the file at `path`, in the MIME type of its extension: `.png`,
`.pdf`, `.svg`, `.eps`, `.jpg` or `.csv`. The method `show(io, mime, visualizer; options...)` of
the visualizer writes the file. As with Makie's `save`, the options reach that method:

```julia
export!(visualizer, "iv.pdf")
export!(visualizer, "iv.pdf"; backend=CairoMakie)
```

The Export button in the header of a window offers the MIME types for which
`showable(mime, visualizer)` holds, and calls `export!` with the file the user chooses. Without
such a type, it saves a picture of what [`draw!`](@ref) draws as PNG, without the title and the
header of the window.
"""
function export!(visualizer::AbstractVisualizer, path::AbstractString; options...)::Nothing
    extension = lowercase(splitext(path)[2])
    index = findfirst(type -> first(type) == extension, MIME_TYPES)
    index === nothing && error("Export saves $(join(first.(MIME_TYPES), ", ")) files, not \"$extension\"")
    mime = last(MIME_TYPES[index])
    # Write the file only once `show` has finished, so that an error leaves no partial file.
    buffer = IOBuffer()
    show(buffer, mime, visualizer; options...)
    write(path, take!(buffer))
    return nothing
end

"""
    draw!(visualizer, ctx)

Draw what `prepare!` stored. The browser calls `draw!` in every frame in which the window is
visible, inside the window and below its header, and only after `prepare!` succeeded.
It runs on the UI thread, with exclusive access to the instance. Request expensive preparation
with `ctx.prepare()` rather than performing it in this callback.
"""
function draw! end

"""
    output(visualizer)

The value the window of `visualizer` passes on to a window that takes its input from it. For
example, a table passes on the rows the user selected, and another window plots them.

A visualizer without a method passes on the value it was given, and so does one that returns
`nothing`. Stack keeps the whole input in this case; navigating it does not narrow the input of
linked windows. Grid currently passes on the whole input; combining per-cell interaction outputs
is not yet part of the contract.

The browser reads the output in every frame, and hands it to the other window when it is another
object than before. Keep the output in a field and return that field; replace the object when the
output changes.
While preparation owns the instance, output reads and updates to linked windows pause.

An output that is part of what the visualizer shows, such as the rows the user selected, is a view:
`Computation(view, computation(selection, i), s)` for each item `i`, with a selection type `S` of the
visualizer's own and methods `view(data, s::S)` and `getindex(data, s::S)` for the data it shows.
"""
output(::AbstractVisualizer) = nothing

"""
    select!(visualizer; keywords...)

Select part of what `visualizer` shows, as the user does in its window. Each visualizer names its
own keywords, such as `columns` for a table. When the window passes on what is selected, its
[`output`](@ref) changes too.

The browser also calls `select!` before the first `prepare!`, to open a saved window again with what
[`selection`](@ref) returned. The visualizer then keeps the selection until its data arrives.
"""
function select! end

"""
    selection(visualizer) -> NamedTuple

What `visualizer` has selected, under the names of the keywords of [`select!`](@ref): for example
`(columns=["I"],)` for a table. The browser saves it with the window, so each value is text, a
number, a boolean or a list of them. The default, `(;)`, is for a visualizer without a selection.
"""
selection(::AbstractVisualizer) = (;)

