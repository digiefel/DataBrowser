# Tabs and analysis files

[Architecture](../ARCHITECTURE.md#visualizers) describes the windows built today, and the
[vision](../vision.md) defines tabs as live Julia files whose `@layout` block declares their
windows. How tab files declare analysis, reuse other files, own windows, target per-tab selections,
capture local values for debugging, and persist state remains open.

## A workflow to support

Suppose a user writes an ordinary Julia helper and an adapter for selected data in a tab file:

```julia
function fitter(time, current)
    # Ordinary analysis code; return the values to inspect.
end

try_fitter(selection) = [fitter(x.data.time, x.data.current) for x in selection]
```

A window runs that helper on the selection without requiring a trial call in the file, while the
helper stays directly callable from Julia. A second analysis file then calls the helper in its own
functions, and a third file queries or tags those results, aggregates them, and builds a figure.
Intermediate values stay named and inspectable, so the user can compare an alternative calculation
and promote repeatable work without copying code. How a tab file declares such a helper for a window
and how other files reuse it remain open.

Queries and aggregations are ordinary Julia code. GUI actions can write recognized declarations or
insert new ones, while inline controls edit literal values only; see
[plot editor](../plot-editor.md#editing).

## Inspecting a local value

Clicking a local variable offers "Show in a window". That debug window belongs to the current tab
and shows the value from the relevant run, without inserting debug code into the user's function;
opening the helper's source in another tab does not bring the first tab's debug windows along.

The capture mechanism remains open. A local variable cannot be recovered from a completed run unless
it was retained; a debug request may rerun repeatable analysis on retained input, yet it must never
repeat acquisition or instrument commands and never block the GUI thread. Capturing locals during
non-repeatable execution needs a separate experiment, and multi-item selections or source edits also
need defined behavior.

From any displayed value, the user can open the code that produced it and see the local values held
during that computation, so the starting value identifies the relevant run.
[The code editor plan](code-editor.md#values-in-the-code) describes how the editor displays those
values and gives a capture measurement.

## Selection

A tab can keep its own selection, independent of changes to the workspace selection. How code targets
a tab's selection remains open.

## Declarations and windows

Stable plot and analysis definitions should use clear macros matching the role of `@plot` (names
such as `@process` are illustrative; the grammar is not chosen). One-off REPL calls and queries need
no declaration, while a query can form part of a saved definition when it specifies that analysis's
input; the GUI writes and edits the same macro declaration that a person or agent writes.

Four window rules are proposed:

- A window belongs to the tab whose file or GUI action opened it.
- GUI actions that open or update a window write recognized code into that tab's file.
- Debug markers live in browser state, separate from analysis definitions.
- A window can show either a named value or a helper run on a chosen input; the exact declaration
  and lookup functions are not designed yet.

Because ordinary `include` evaluates every top-level expression in a file each time it runs, it
cannot load a shared file once. The design must support file reuse and window ownership on top of
it; putting each file in its own module was explored and rejected.

## Live code and saved work

Edits to analysis code refresh affected results without rerunning every top-level expression in a
file. Loading definitions, tracking their dependencies, and recognizing declarations all need one
coherent contract.

Source definitions, layouts, user annotations, and retained results stay separate. Tags belong to
shared project state, so a query whose results change dynamically never overwrites user-assigned
tags. Whether every result and annotation shares one store remains open; [storage](storage.md) owns
data persistence, indexing, and durable state.

## Open work

1. Declarations and discovery: create a tab or window, bind a named result or helper, select inputs,
   and target either a tab selection or the workspace selection from Julia and from the GUI.
2. File loading and reuse: detect definitions and edits without re-running unrelated side effects,
   and keep window ownership intact under ordinary code loading.
3. Debug capture: identify the relevant run, retain locals, handle multi-item scopes, renamed
   variables, and non-repeatable runs, and show unavailable locals clearly (see
   [code editor](code-editor.md#values-in-the-code)).
4. Trials on selected items vs. default analysis: compare alternatives, keep their results, and
   promote a chosen definition to the default without accidentally altering the whole project.
5. Saving and undo: decide what source edits, browser state, and debug markers preserve when a tab
   reopens.
6. Tags vs. computed queries: clarify ownership and what happens when an automated definition changes.
