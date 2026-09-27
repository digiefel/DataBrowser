# Visualizers

## Goal

Any value in a workspace should be viewable in many ways, and the ways should be easy to combine. A
table can be a grid, an X/Y plot, a histogram of one column, or a summary. A matrix can be a grid, a
heatmap, an image, or one histogram per row. Nested records, spectra, arrays, maps, and fit results
each have their own useful views.

The set of views is open. Generic views, such as tables, line plots, histograms, or heatmaps, cover
common data without any code. Packages add views for their own domains. Projects add their own
figures. All of them are offered in the same way for every value they can show, and no value is
tied to a single view.

Views are building blocks. A user opens as many as they need, over the current selection or a fixed
set of items. They reshape the data on the way with their own code. Later, views link to each other
and compose into figures. The aim is the directness of a patching environment such as Max, where
connecting things shows a result immediately, with the power of a language such as Matlab, where any
code can be a step.

Three properties of Julia and DataBrowser set this design apart:

- **The choice of visualizers follows from dispatch.** A value is offered exactly the visualizers
  whose methods accept it, with no separate declaration.
- **Every step is a Julia function.** A transform is plain Julia code, and a set of connected views
  can be written down as Julia code.
- **Identity runs from file to screen.** Items have stable ids, and every value is kept with the
  items it was computed from, so an element on screen can name the item it came from.

Today the browser has three fixed views: the Table Inspector, the Table Plot, and the plot windows
that draw a project's registered plots. Each has its own code for following the selection, loading
data, reporting errors, and saving its state. This plan replaces them with one mechanism that all
views are built on.

## How a view works

A **view** is a window that shows a selection of items. It has three parts:

1. a **selection**: the items the view shows;
2. a **transform**: a function that turns those items into the value to show;
3. a **visualizer**: the code that draws that value.

For example, a user selects three measurement cycles. They open a view with the table visualizer
and see the cycles' data. They open a second view on the same selection with a line plot. They open
a third with a histogram and the transform
`items -> [metadata(i)[:temperature] for i in items]`, and see the distribution of temperatures
across the three cycles.

```mermaid
flowchart LR
    sel["Selection<br/>live or fixed"] -->|items| tr["Transform<br/>default: identity"]
    tr -->|any value| vis["Visualizer<br/>draws the value"]
```

### Selection

A selection is either **live** or **fixed**. A live selection follows the browser's current
selection, or the output of another view the user connected it to (see
[Interaction between views](#interaction-between-views)). A fixed selection stays the same until the
user changes it. The browser handles both kinds. A visualizer does not know which kind its view has.

### Transform

A transform is a plain Julia function of the view's input: the selected items, or the output of a
connected view. It returns any value. The default is `identity`: the visualizer receives the
selected items themselves.

A transform uses the same functions as any other code that reads items: `item_data(item)`,
`metadata(item)`, `label(item)`, and any function the project defines. Viewing metadata needs no
separate mechanism. A transform that collects metadata produces a value like any other, and any
visualizer can show it. This relies on `metadata(item)` being the only source of an item's metadata.

A transform is a computation over a set of items, like a collection `process` or `analyze`. It runs
when a view needs it, over whatever items the view shows, and its result is not stored in the cache.

### Visualizer

A visualizer receives the transform's result and draws it. It decides how to read the value by
dispatch on the value's type. The same value can have several valid readings: a dictionary of named
vectors is a table to the table visualizer and a set of labelled traces to a line plot. This is
intended. The user chooses the reading by choosing the visualizer, or by changing the transform.

Every value must be viewable, for example by an inspector that accepts any value and shows its
structure. Most visualizers accept only what they are written for, and only those that accept a
value are offered for it. When a visualizer cannot draw a value it accepted, it fails, and the view
shows the error.

## Who writes what

DataBrowser has four kinds of users. Each one touches a different part of this design, and each part
must be as simple as its users need.

| User | Writes | Knows |
| --- | --- | --- |
| Project developer | Item types: `item_data`, `metadata`, `label` | Julia and DataBrowser's type API, nothing internal |
| Plot author (DBPlots) | Figures for their own data, with `register_plot!` | Scripting and data analysis; maybe Makie, maybe only matplotlib, maybe little Julia |
| Recipes user (DBRecipes) | Nothing for viewing: uses the built-in visualizers | Same as the plot author |
| Extension author | New visualizers and browser extensions | DataBrowser's developer documentation and the browser's lifecycle |

Consequences:

- Transforms use only the type API, so any project developer can write one.
- A plot author writes a function that creates a Makie `Figure`, adds axes and plots, and returns
  the figure. They never meet visualizer types, Makie specs, or Makie recipes.
- A recipes user can view tables and any other value without loading Makie, which avoids Makie's
  load and compile time.
- Only extension authors implement visualizers or browser extensions.

## Writing a visualizer

A visualizer is a concrete subtype of `AbstractVisualizer`. One instance belongs to one view. It
holds that view's settings, for example which columns a plot uses as X and Y, and whatever it
prepared for drawing.

```julia
abstract type AbstractVisualizer end

# Called when the view's value changes. May throw.
prepare!(v::AbstractVisualizer, value)

# Called every frame inside the view's window. May throw.
draw!(v::AbstractVisualizer)

# Optional: the view's settings, saved with the browser layout. The defaults save and load nothing.
save_view(v::AbstractVisualizer)::Dict{String,Any}
load_view!(v::AbstractVisualizer, view::Dict{String,Any})
```

`prepare!` does the expensive work once per value. `draw!` runs every frame and only reads what
`prepare!` stored.

Methods of `prepare!` dispatch on the value's type, and the most specific method wins:

```julia
# item_data of each item, shown with an item column
prepare!(v::TableView, items::AbstractVector{<:AbstractDataItem}) = ...
prepare!(v::TableView, x) = (v.columns = Tables.columns(x))     # throws for a non-table
prepare!(v::LinePlot, y::AbstractVector{<:Real}) = ...           # one trace
prepare!(v::LinePlot, traces::AbstractDict) = ...                # one labelled trace per entry
```

The `prepare!` methods are also the visualizer's declaration of what it accepts. The browser offers
a visualizer for a value when `hasmethod(prepare!, Tuple{V, typeof(value)})` is true. `TableView`
above accepts any value, so it is always offered. `LinePlot` is offered only for real vectors and
dictionaries. For this reason no catch-all `prepare!(::AbstractVisualizer, value)` exists, neither
for all visualizers nor for a family.

A visualizer does not check its input beyond its signatures. If a value does not fit, the method it
calls throws, and the browser shows that error in the view. Handling a new kind of value means
adding a method.

The browser finds visualizers through the type hierarchy: every loaded concrete subtype of
`AbstractVisualizer` whose `prepare!` accepts the value. The list is read when the user chooses a
visualizer, so a visualizer or method defined after the browser opened, for example a plot
registered from the REPL, is available at once. Defining the type and its methods is the whole
registration.

### Drawing libraries

Every view is a window of the browser, which is built on ImGui, so `draw!` always runs inside an
ImGui window. What else a visualizer needs depends on the library it draws with:

- **ImGui or ImPlot** (ImPlot is bundled with CImGui): nothing else. The visualizer calls the
  library directly in `draw!`.
- **A library the browser already embeds**, such as Makie through DBPlots: nothing else. The
  visualizer reuses the existing embedding.
- **A library nobody has embedded yet**: an embedding, written once for that library. It renders
  into a texture, shows the texture in the window, forwards mouse and keyboard input, and sets up
  and cleans up the library. The Makie embedding is about 400 lines. Setup and cleanup that happen
  once per session go into a browser extension (next section).

A family of visualizers that shares a library shares its code through an intermediate abstract type:

```julia
abstract type MakieVisualizer <: AbstractVisualizer end

draw!(v::MakieVisualizer) = MakieFigure(v.id, v.figure)     # the shared embedding

struct Histogram <: MakieVisualizer ... end
prepare!(v::Histogram, x::AbstractVector{<:Real}) = ...      # builds v.figure; nothing else to write
```

## Visualizers and browser extensions

A **browser extension** (`GuiExtension`) is how a package plugs into the browser as a whole. The
browser creates one instance of each registered extension type when it opens, and calls that
instance's hooks for the whole session: setup at startup (`init!`, `warmup!`, `is_ready`), cleanup
at shutdown (`shutdown!`), menu entries (`menu!`), item context-menu entries
(`item_context_menu!`), docking (`main_dock_windows`), and package-wide saved state.

A visualizer and an extension have different lifetimes:

- An extension is **one instance per package**, created when the browser opens and shared by
  everything the package shows.
- A visualizer is **one instance per view**, created when the user opens the view, holding that
  view's own settings and prepared data.

Visualizers are therefore not extension types. If they were, the browser would create one instance
of each at startup: a plot registered after the browser opened would have no instance, and each
visualizer would need a second type to hold the state of each of its views.

A package that adds visualizers needs an extension only for what the whole package needs once per
session. DBPlots keeps one extension to warm up Makie at startup and destroy Makie's screens at
shutdown. A package whose visualizers draw with ImGui or ImPlot needs no extension.

The extension hooks for package-wide saved state are renamed from `save_view`/`load_view!` to
`save_state`/`load_state!`. They save package state, not a view, and `save_view` now means the
settings of one view.

## How the browser runs a view

For each view, the browser:

1. follows the selection, live or fixed;
2. requests the selected items from the workspace, with the priority of a visible view;
3. runs the transform and keeps the result together with what it was computed from;
4. calls `prepare!` when the result changes, and `draw!` every frame;
5. shows any error from steps 2–4 inside the view;
6. saves the list of views, each view's selection, transform, and visualizer type, and each
   visualizer's `save_view`.

The record in step 3 is a `Payload`, internal to the browser:

```julia
struct Payload{T}
    key       # the input's item ids and revisions, the connected view's key, and the transform
    value::T  # the transform's result
end
```

The transform runs again only when the key changes. Visualizers receive `payload.value`, never the
`Payload`, so their methods dispatch on the user's own types.

The transform runs as a background job, like the workspace's processing work. Until the new value
is ready, the view keeps showing the previous one, marked as not current. `prepare!` and `draw!` run
on the GUI thread, because they may create graphics resources such as Makie figures.

This depends on the workspace providing a revision for each item's data and accepting requests with
a priority, so that a view knows when its items changed and visible views are served first.

## DBPlots

DBPlots defines the `MakieVisualizer` family and gives plot authors and Makie users entry points
that need no knowledge of visualizers:

- **Registered plots.** `register_plot!` creates one visualizer type for each registered function.
  The plot author's function builds and returns an ordinary `Figure`, as it does today.
  <!-- TODO: re-registering a plot from the REPL must replace its visualizer type cleanly. -->
- **Plain Makie.** A visualizer that calls `plot(value)`. Values Makie already understands, such as
  vectors and matrices, plot with no code. A type that a user has taught Makie through Makie's own
  extension methods plots here too, with no DataBrowser knowledge.

## Interaction between views

Views affect each other in two ways: one view feeds another, and hovering an element highlights the
same item in every view.

### Connected views

By default, a live view follows the browser's selection. The user can connect it to another view
instead, and it then follows that view's output. A view is connected only when the user connects it.
Turning off live freezes the view on its current input, whatever its source.

A view's **output** is its value, or the part of the value the user brushed or clicked. The brushed
part is a value of the same kind, so the connected view's transform and visualizer treat it like any
other value:

| Value | Brushed part | Obtained with |
| --- | --- | --- |
| Vector of items | Vector of items | `getindex` |
| Table | Table with fewer rows | `Tables.subset` |
| `Dict` | `Dict` with fewer keys | `filter` |
| Anything else | The whole value | – |

The item tree acts as the first view: its value is the selected items. A view with the default
transform also has its items as value, so connected views pass items along until a transform
reshapes them.

```mermaid
flowchart LR
    tree["Item tree<br/>value: selected items"] --> A["Scatter<br/>value: items"]
    A -->|brushed items| B["Histogram<br/>transform: temperatures"]
    A -->|brushed items| C["Table"]
    C -->|brushed rows| D["Line plot"]
```

### Identity

The browser always knows which items a value was computed from, through the key of its `Payload`.
Finer identity depends on the value, and a view uses the finest level available:

1. **The items the view shows.** Always available.
2. **The item of each element**, for example the item behind a point. Available when the visualizer
   receives items: it calls `item_data` itself and knows where each row comes from. A transform
   keeps this level only if its result carries the item ids, for example
   `Dict(id(i) => ... for i in items)`.
3. **Elements inside an item**, for example rows of a table. Available for value types that support
   it, starting with Tables.

An aggregate, such as the mean of several items, has only level 1. It belongs to all the items it
was computed from.

### Hover

Hovering an element highlights the same item in every view that shows it. This needs no connection
between the views, and it works in every view that has level 2.

### Brushes, clicks, and queries

- A **brush** is a range on the fields the visualizer plots. When the value changes, the visualizer
  applies the same range to the new value.
- A **click** selects a list of elements.
- A **query** is a transform that filters, for example `t -> filter(r -> r.temperature > 300, t)`.
  The browser never infers a rule from a list of elements.

### To explore on the real thing

These choices are made by trying them in the browser:

- **Where connections are drawn.** CImGui includes imnodes, a node canvas with pins, wires, and any
  ImGui content inside a node, such as a preview of the view. Wires can also be drawn between view
  windows, but only within the main OS window: an undocked window is a separate OS window, and
  nothing can be drawn between OS windows. Drag and drop works between OS windows, so a connection
  can still be made there and shown as a badge on each end. The options are a canvas, connections
  between windows, or both.
- **One output or two.** One output keeps every connection alike. Two outputs, the value and its
  brushed part, let a histogram show all data with the brushed part on top.
- **Several inputs.** Brushes from several views can combine as in Mosaic: union, intersection, or
  crossfilter, where each view ignores its own brush. Alternatively, a view has several inputs and
  its transform takes several arguments, `(a, b) -> ...`, which allows joins and comparisons. Each
  is simple exactly where the other needs code.

## Open design work

- **Transform user experience.** How users write, choose, and combine transforms in the browser, and
  how they reach transforms their project defines. This is decided once views and transforms work.
- **Composed figures.** Figures that combine several views are designed with the figure composer.
  Combining Makie outputs is DBPlots' concern. Combining views drawn with different libraries is not
  planned.

## Changes to existing code

### For users

- **Project developers**: nothing changes in the type API.
- **Plot authors**: `register_plot!` keeps its current form.
- **Everyone using the browser**: the Table Inspector, Table Plot, Plot Area, and detached plot
  windows become views, all opened and managed the same way. The saved browser layout in
  `databrowser.toml` changes format.

### For extension authors

- New: `AbstractVisualizer` and its contract (`prepare!`, `draw!`, `save_view`, `load_view!`).
- `GuiExtension` keeps all its hooks. Its saved-state hooks are renamed to `save_state` and
  `load_state!`.

### Internal

- **DataBrowserGUI** gains the view host described above. The Table Inspector is rebuilt as a
  visualizer. `ItemTable`, `merge_item_tables`, and `materialize_item_table` are removed.
- **DBPlots** keeps its user API and changes underneath:
  - `PlotKind` is DBPlots' own visualizer type today. It is replaced by `AbstractVisualizer`, and
    `RegisteredPlot`, `setup_plot`, `plot_data!`, and `plot_kinds()` go with it. DataBrowser
    exports some of these today, but only DBPlots uses them; they leave the exports.
  - Window management, detached windows, their persistence, and the "Open Plot in New Window" menu
    move to the view host. `PlotsExtension` keeps only Makie's startup and shutdown.
  - The Table Plot is rebuilt as a generic Makie visualizer for Tables.
