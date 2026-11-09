# Tabs and analysis files

Target design, curated on 21 October 2026. This plan owns analysis files, window ownership,
independent selections and interactive development. [Visualizers](visualizers.md) owns view inputs
and presentation; [processing](processing.md) owns execution.

## Agreed workflow

Davide agreed the following development workflow on 13 October, then independent tab selections
on 20 October. These are target interactions, not a complete implemented loading API.

### Develop a helper on selected data

The user writes an ordinary Julia helper and an adapter for selected data, for example:

```julia
function fitter(time, current)
    # Ordinary analysis code; return the values to inspect.
end

try_fitter(selection) = [fitter(x.data.time, x.data.current) for x in selection]
```

A result window runs the chosen helper on the selection. The user need not add a trial call to the
file. Changing the selection or saving an edit updates the affected result. The same helper and
native output remain usable directly from Julia.

### Inspect a local value

A click on a local variable offers “Show in a window”. The debug window belongs to this tab and
shows the value from the relevant run. It does not add debug code to the user's function.
Opening the helper's source in another tab must not bring the first tab's debug windows with it.

The capture mechanism is open. A local cannot be recovered from a completed run unless it was
retained. A debug request may rerun repeatable analysis against retained input, but must not
repeat acquisition or instrument commands, or block the GUI thread. Capture during non-repeatable
execution needs a separate experiment. Multiple selected items and source edits need explicit
behavior rather than a promise that an unrecorded local is always available.

Davide, 9 November 2026: from a value the user reaches the code, and the code shows the values
that this computation had inside when it produced the value. The value that the user came from
therefore identifies the relevant run. [The code editor plan](code-editor.md#values-in-the-code)
owns how the code shows these values. It also has a measurement for the capture: running only the
one function in an interpreter, with everything that it calls compiled, takes about as long as a
normal run.

### Reuse the helper

A second analysis file calls the successful helper in its normal processing/analysis functions.
A third can query/tag results, aggregate them and build a figure. Intermediate values stay named
and inspectable. The user can compare another calculation and promote it into repeatable work
without duplicating code or moving the work into a plot-specific engine.

Queries and aggregations are ordinary Julia code. GUI actions can write recognized declarations
or explicitly insert new ones. Inline controls change literal values only; see
[plot editor](../plot-editor.md#editing).

A comparison created interactively from groups in different samples appears in the current
analysis's results by default, with expandable inputs (Davide, 21 October). Its native result is
still available from code; this placement does not make a display window own the computation.

## Selection

Tab selections stay independent. A view can explicitly follow the shared REPL/workspace selection.
Changing that shared selection does not reset independent tabs. A group is selected as one item;
selecting its members is a separate request. The public API must distinguish these targets.
Its exact form, and how a view switches between fixed input and a followed selection, remain open.

## File and window model

DBRecipes reads common sources and produces processed items without requiring the type API.
After that, combining data, exploring it, making figures and saving reproducible analysis use the
same tools for everyone (Davide, 21 October). A tab's analysis code is not a recipe and does not
require DBRecipes declarations. A recipe means something specifically defined by DBRecipes.

Davide's direction, 21 October: stable plot and analysis definitions should use clear
macros, following the role of `@plot`. Names such as `@process` or `@analyze` are illustrative;
the grammar is not chosen. Ordinary one-off REPL calls and queries do not require a declaration.
A query can instead be part of a saved definition when it describes that analysis's input.
The GUI writes and edits the same macro declaration that a person or agent can write.

The working model is a tab backed by an ordinary Julia file plus its windows. The file contains
functions, declarations, queries and named results. Windows present those values. An agent and a
person edit the same source; attaching a GUI must not recreate analysis or repeat external effects.
Scientific definitions and results are available headlessly.

Today the browser saves its windows, their visualizers, inputs and settings, and its other
controls in `databrowser.toml`, in the folder of the workspace, which is the folder of the active
Julia environment. The browser writes that file while it is open, so it overwrites an edit made by
another program.

Direction agreed with Davide on 7 November, not built: a tab is a live Julia file, and a `@layout`
macro in it declares its windows. The macro defines a method, so Revise runs only the layout again
when it changes, and deleting it closes the tab. The layout holds the geometry too, with
`Split(direction, ratio, first, second)` and `Window(name, visualizer; input)`, which replaces the
earlier rule that geometry stays out of analysis files:

```julia
@layout begin
    Split(:horizontal, 0.4,
        Window(:peaks, TableView; input=LiveSelection()),
        Window(:fit, BuilderView; input=VisualizerOutput(:peaks)))
end
```

- Core knows visualizers, never windows: one visualizer for each name, with its input and
  settings. The name, such as `:peaks`, identifies the visualizer across runs and keeps its state.
  The named visualizers exist when the tab file loads, with or without a browser; `Window` and
  `Split` belong to the GUI.
- An input is `LiveSelection()`, `FixedItems(ids)`, a function that `select` keeps current, or
  `VisualizerOutput(:name)`, the output of another named visualizer.
- A window that `@layout` places cannot be moved or resized in the browser; a drag may later write
  the change into the file.

These details remain proposed:

- A window belongs to the tab whose file or explicit GUI action opened it.
- Window-opening/changing actions write recognized code into that tab's file.
- Debug markers live in browser state, separate from analysis definitions.
- A window may show a named value or run a helper on a chosen input; the exact declaration and
  result-access APIs are not designed.

Ordinary `include` evaluates top-level expressions. It is not an import-once mechanism. The design
must provide file reuse and window ownership without pretending Julia already supplies those
semantics. A module-per-file alternative was explored, not chosen.

## Live code and saved work

Edits to processing, analysis and visualization code automatically refresh affected active results.
This does not mean reevaluating every top-level expression in a file. Definition loading,
dependency tracking and recognized declarations need a coherent contract. The current engine
already invalidates the project's calls when their code changes; the earlier claim that nothing notices analysis edits is
obsolete. It does not establish the complete tab execution model.

Keep source definitions, browser geometry, durable user annotations and retained computation
results distinct. Tags are shared project state, not a transcript of clicks. A query that changes
its result must not silently acquire the semantics of manually assigned tags. The existing
`tags.txt` convention is not a decision that every future result or annotation shares one store.
Payload/index ownership and durable state are tracked in [storage](storage.md).

## Open work

1. Public declarations and discovery: create a tab/window, bind a named result or helper, choose
   inputs and target independent/shared selections from Julia and the GUI.
2. File loading and reuse: recognize definitions and changes without replaying unrelated effects;
   preserve window ownership under ordinary code loading.
3. Debug capture: relevant run, retained locals, selected-item scope, renamed variables and
   non-repeatable execution. Decide what unavailable locals look like. The
   [code editor plan](code-editor.md#values-in-the-code) has the latest statement and its open
   points.
4. Selected trials versus default analysis: compare alternatives, retain results and promote the
   chosen definition without unintentionally changing the whole project.
5. Saved layout and undo: what source edits, presentation state and debug markers retain across
   reopen; headless access must not depend on `databrowser.toml`.
6. Tags versus computed queries: ownership and removal when an automated definition changes.

## Existing implementation

The browser has visualizer windows with headers, selection/linked inputs, registered plots,
tables and a plot builder. The public workspace has queries, tags and item selection. Independent
tab selections, the file/window loading contract and debug capture described here are not thereby
implemented. Use the [roadmap](../roadmap.md) for implementation status and the
[archive](archive/2026-10-21-discussion/tabs.md) for the full earlier examples.
