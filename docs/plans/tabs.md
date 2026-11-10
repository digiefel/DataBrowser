# Tabs and analysis files

What is still open about tabs: how a tab file declares analysis and reuses other files, which tab
owns a window, how a tab targets its own selection, how a debug window captures local values, and
what a tab saves. [Architecture](../ARCHITECTURE.md#visualizers) describes the windows that are
built, and the [vision](../vision.md) the settled direction, with tabs as live Julia files whose
`@layout` declares their windows.

## A workflow to support

The user writes an ordinary Julia helper and an adapter for selected data in a tab file, for
example:

```julia
function fitter(time, current)
    # Ordinary analysis code; return the values to inspect.
end

try_fitter(selection) = [fitter(x.data.time, x.data.current) for x in selection]
```

A window runs the helper on the selection, without a trial call in the file, and the same helper
stays usable directly from Julia. A second analysis file then calls the helper in its own analysis
functions, and a third queries or tags the results, aggregates them and builds a figure. The values
in between stay named and inspectable, and the user can compare another calculation and make it
repeatable work without copying code. How a tab file declares such a helper for a window, and how
another file reuses it, is open.

Queries and aggregations are ordinary Julia code. GUI actions can write recognized declarations
or explicitly insert new ones. Inline controls change literal values only; see
[plot editor](../plot-editor.md#editing).

## Inspecting a local value

A click on a local variable offers "Show in a window". The debug window belongs to this tab and
shows the value from the relevant run, without debug code in the user's function. Opening the
source of the helper in another tab does not bring the debug windows of the first tab with it.

The capture mechanism is open. A local cannot be recovered from a completed run unless it was
retained. A debug request may run repeatable analysis again on retained input, but it never
repeats acquisition or instrument commands, and it never blocks the GUI thread. Capture during
execution that cannot be repeated needs a separate experiment. Several selected items and edits of
the source also need a defined behavior.

From a value the user reaches the code, and the code shows the values that this computation had
inside when it produced the value. The value that the user came from therefore identifies the
relevant run. [The code editor plan](code-editor.md#values-in-the-code) holds how the code shows
these values, with a measurement of the capture.

## Selection

A tab can have a selection of its own, which changes of the selection of the workspace leave alone.
How code targets the selection of a tab is open.

## Declarations and windows

Stable plot and analysis definitions should use clear
macros, following the role of `@plot`. Names such as `@process` or `@analyze` are illustrative;
the grammar is not chosen. Ordinary one-off REPL calls and queries do not require a declaration.
A query can instead be part of a saved definition when it describes that analysis's input.
The GUI writes and edits the same macro declaration that a person or agent can write.

These details of windows are proposed:

- A window belongs to the tab whose file or GUI action opened it.
- Actions that open or change a window write recognized code into the file of that tab.
- Debug markers live in the state of the browser, apart from analysis definitions.
- A window may show a named value or run a helper on a chosen input; the declaration and the
  functions that give the result are not designed.

Ordinary `include` evaluates the top-level expressions of a file each time, so it cannot load a
file only once. The design must give reuse of files and ownership of windows on top of it. A module
for each file was explored and not chosen.

## Live code and saved work

Edits to analysis code refresh the affected results, which does not mean evaluating every top-level
expression of a file again. Loading definitions, following what they depend on, and recognizing
declarations need one contract.

Source definitions, the layout, lasting annotations by the user and retained results stay apart.
Tags are shared state of the project, and a query whose result changes never behaves as tags that
the user assigned. Whether every result and annotation shares one store is open;
[storage](storage.md) holds who owns data, the index and lasting state.

## Open work

1. Declarations and discovery: create a tab or a window, bind a named result or helper, choose
   inputs and target the selection of a tab or of the workspace, from Julia and from the GUI.
2. Loading and reuse of files: recognize definitions and their changes without running unrelated
   effects again, and keep the ownership of windows under ordinary code loading.
3. Debug capture: the relevant run, retained locals, the scope of the selected items, renamed
   variables and execution that cannot be repeated, and what a local that is not available looks
   like. The [code editor plan](code-editor.md#values-in-the-code) has the latest statement and
   its open points.
4. Trials on selected items versus the default analysis: compare alternatives, keep their results
   and make the chosen definition the default without changing the whole project by accident.
5. Saving and undo: what edits of the source, the state of the browser and debug markers keep when
   the tab opens again.
6. Tags versus computed queries: who owns them, and what is removed when an automated definition
   changes.
