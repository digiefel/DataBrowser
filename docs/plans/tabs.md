# Tabs

## Goal

A user, the browser and an agent work on the same analysis. Each must see what the others did, in
the code and in the results, at the moment it happens. No step of an analysis stays hidden in a
Julia session, in a scratch file or in the state of the browser.

A **tab** provides this. A tab is a Julia file together with the windows that belong to it. The
file is an ordinary script. The user edits it in any editor, the browser edits it when the user
works with the windows, and it runs without the browser.

This plan builds on [visualizers.md](visualizers.md), which describes windows (called views there),
transforms and visualizers. [Changes to visualizers.md](#changes-to-visualizersmd) lists what this
plan replaces in it. Nothing here is built, except what [What exists today](#what-exists-today)
lists.

The broader requirements and current contract gaps are recorded in
[Scientific workspace: analysis and acquisition](scientific-workspace.md). Tabs use the existing
workspace and public operations. They must support automatic live analysis over static and arriving
data without replaying acquisition or other unrelated external effects. The loading and persistence
mechanisms below remain proposed where marked; this is not an implemented execution model.

## A tab

```
        the file of the tab                       the windows of the tab
    ┌───────────────────────────┐            ┌──────────────────────────────┐
    │ functions of the user     │            │ item tree                    │
    │ registrations             │  ───────▶  │ plots, tables, figures       │
    │ queries, tables, figures  │            │ the source of the file       │
    │ lines that open windows   │  ◀───────  │ debug windows                │
    └───────────────────────────┘            └──────────────────────────────┘
          ▲              ▲                                 ▲
     the user,        an agent                   the user, with clicks:
     in an editor                                the browser writes the line
```

1. A tab is one file, found by its path in the project, and the windows that belong to it.
2. Edits to processing, analysis, and visualization code automatically refresh affected active
   results. Loading changed definitions and requesting those results must not rerun arbitrary
   top-level expressions in the file. The loading/dependency mechanism still needs design.
3. A window belongs to one tab: the tab whose file opens it, or the tab in which the user opened it.
4. Files use ordinary Julia code loading. `include` evaluates top-level expressions in its caller's
   module; it is not an import-once mechanism. Windows remain owned by their tab. How declarations
   establish that ownership while a file is included is still open.
5. An item tree is a window. Its selection is what it passes on, and the other windows of the tab
   take their input from it. Each tab can have its own item tree and its own selection.
6. A table or a figure that the file computes has a name. A window shows the value of a name.
7. A click that opens or changes a window writes or rewrites one line of the file.

## Example: three tabs

The names in this example, such as `fitter` and `PUND.jl`, are examples. A line in «…» stands for a
function that does not exist yet, and its form is not designed. The other lines use functions that
exist. `project` and `workspace` come from the entry code that opens the browser.

```
 fitter.jl ───include──▶ PUND.jl ───include──▶ statistics.jl
 the fitter              analysis function,    queries, tags,
                         registration, plots   tables, the figure
```

### 1. Develop a function on the selected item

1. The user creates a tab. The browser creates the empty file `fitter.jl` and shows it.
2. The user adds an item tree to the tab.
3. The user writes the function, and one line that says what an item gives to it:

   ```julia
   function fitter(time, current)
       segments = …
       guesses  = …
       …
   end

   try_fitter(data, metadata) = fitter(data.time, data.current)
   ```

4. The user adds a result window and chooses `try_fitter` in its menu. Each time the user selects
   an item, the browser calls `try_fitter` with the data and the metadata of that item, and the
   window shows what it returns. `analyze` receives the same two arguments today, so a function
   tried this way can be registered unchanged.
5. The user changes the function and saves. The function runs again on the selected item.

```
┌ item tree ─────┐ ┌ fitter.jl ────────────────────────┐ ┌ result ───────────┐
│ ▾ chip A       │ │ function fitter(time, current)    │ │ what try_fitter   │
│   ▾ device 1   │ │     segments = …        ●         │ │ returned          │
│     ● item 3   │ │     guesses  = …                  │ ├ segments ─────────┤
│       item 4   │ │     …                             │ │ its value in the  │
│                │ │ end                               │ │ last run          │
└────────────────┘ └───────────────────────────────────┘ └───────────────────┘
```

The file then contains the two functions and two lines that the browser wrote:

```julia
«an item tree»
«a result window that runs try_fitter on the selected item»
```

### 2. Debug points

A **debug point** shows a value that exists only inside a function, such as `segments` above.

- The user sets it with a click on the source: right-click the variable, "Show in a window".
- The window shows the value that the variable had in the last run of the function in this tab.
- A debug point is not a line of the file. The browser saves it with the tab, as an editor saves
  a breakpoint: the file, the function and the name of the variable.
- When the function is ready, the user closes the debug windows. The file has no debug code to
  remove.

### 3. Use the function in an analysis

```
 PUND.jl                                                windows of the tab
 ───────────────────────────────────────────────        ───────────────────────────
 include("fitter.jl")
 pund_analysis(data, metadata) = … fitter(…) …
 register_csv!(project; analyze = pund_analysis)
 register_plot!(project, :csv; label = "PUND", …)
 «an item tree»                                         item tree ──selection──┐
 «a plot window, input from the item tree»              "PUND" plot ◀──────────┘
```

- `include("fitter.jl")` evaluates the file, defining `fitter` and `try_fitter` and executing any
  other top-level expressions. The required UI behavior is that no fitter-tab window appears in
  this tab. The window-declaration/loading mechanism must provide this without changing ordinary
  Julia `include` semantics; the example does not yet specify that mechanism.
- To see a debug value while selecting items in this tab, the user opens the source of `fitter.jl`
  here and adds the debug point as a window of this tab. It shows the value for the selected item.
- To get that value, the browser runs the analysis of the selected item again, in the foreground,
  with the debug point on. The normal runs happen in the background and their results come from
  the cache, so they have no such values.
  This replay applies to repeatable analysis over retained input. It must not reacquire data or
  replay instrument commands. Prioritizing a debug request must not block the GUI thread. Capturing
  locals during non-repeatable execution needs a separate implementation experiment.

### 4. Tag, query, aggregate and plot

```
 statistics.jl                                                  windows of the tab
 ───────────────────────────────────────────────────────        ─────────────────────────
 include("PUND.jl")
 «an item tree»                                                 item tree ──selection──┐
 «a plot window, input from the item tree»                      "PUND" plot ◀──────────┘
                                                                the user tags here
 cold = query_items(workspace, "temperature_K < 100")
 measurements = DataFrame(workspace, items(workspace, Tag("good")))    table
 devices = combine(groupby(measurements, …), :Pr => maximum => …)      table
 samples = combine(groupby(devices, …), :Pr_max => mean => …)          table
 «a figure of samples: x, y, color, marker size»                       figure
```

- The user looks at items one by one or in groups, and tags items and devices. The workspace saves
  the tags in `tags.txt`. The file does not record each click. It names the tag.
- Each level of aggregation is a table with a name, and a table window can show it. The step from
  one level to the next is plain DataFrames code. The table window offers it as an action that
  writes that line.
- The figure is built in the plot builder, which writes its line.

## What is saved where

| What | Where |
| --- | --- |
| Functions, registrations, queries, tables, figures, lines that open windows | The file of the tab |
| Position and size of the windows, debug points | A file of the browser, one entry for each tab |
| Tags | `tags.txt` of the workspace, shared by all tabs |
| Results of the pipeline | The cache |

Recorded non-repeatable input has its own retention policy, even if it shares the cache's storage
machinery. Clearing derived results must not delete the only recorded copy. Shared definitions and
result references belong to the workspace/public API; browser-only storage of geometry and editor
markers must not prevent headless inspection or later GUI attachment.

## Without the browser, and for an agent

- A tab file is usable from Julia after the entry code. Scientific definitions and requested
  results exist without the browser, including figure descriptions that a script can render/save.
  Only window presentation is absent. Opening the GUI attaches to that work; it does not recreate
  the analysis or repeat external effects. The exact declaration form remains open.
- An agent edits the same files and calls the same functions. When a browser is open, the user sees
  the source and the windows change as the agent works. The agent does not need a browser.
- Every action of the browser is also a function that a script can call (roadmap 0.6.0).

## What the design solves

| Problem | Answer |
| --- | --- |
| Debug views must not follow a function into the tabs that use it. | Windows stay in their own tab; the loading/declaration mechanism must preserve this ownership. |
| A debug value is needed while looking at analysed items. | The debug point is added as a window of that tab and shows the value for the selected item. |
| A finished function must be free of debug code. | Debug points were never in the file. |
| Trying a function must not need a call written in its file. | The result window runs the function on the selected item. |
| Two tabs each need their own item tree. | Each item tree has its own selection. |
| Tags set by eye are not code. | The workspace saves them. The file names the tag. |
| The analysis must run without the browser. | The file is an ordinary script. |

## Open problems

| Problem | Detail |
| --- | --- |
| An edit of an analysis function leaves old results in the cache. | Nothing notices the change today, and only a full rebuild exists. A debug window can then show a value that differs from the cached result. |
| A tag set by a line of the file stays when the line changes. | `tag!(workspace, cold, "cold")`: after a change of the query, the old items keep the tag. Tags may have to be kept for what the user decides by eye, and queries kept as names. |
| The browser can change only the lines it wrote or recognizes. | A figure rewritten as the user's own loop still shows in its window, but the menus cannot change it. |
| Loading changed definitions without repeating unrelated effects. | Whole-file reevaluation is not the automatic refresh model. Dependency tracking, recognized declarations, and behavior for unsupported edits still need design. |
| Several selected items. | [visualizers.md](visualizers.md) defines a transform over all the items of a window. The result window above calls a function for one item. Which form holds, and what a debug window shows for several items, is not decided. |
| A debug point can lose its place. | It is saved by the name of a variable in a function. A renamed variable has no debug point. |
| The form of the lines that open windows. | Not designed. [visualizers.md](visualizers.md) shows one example form. |

## Agreed and proposed

Agreed with the user on 2026-10-13:

- The workflow of the three tabs is the target.
- A function is developed by selecting an item, not by a call written in the file.
- A debug point is set with a click and needs no line of code.
- Edits to visualization, processing, and analysis code must be reflected live and automatically;
  supporting acquisition does not change that requirement.

Proposed, not yet agreed:

- Rules 3, 4, 6 and 7 of [A tab](#a-tab).
- Debug points are saved by the browser with the tab.
- Each file is loaded once, in a module of its own, however many tabs include it. A name defined
  in one tab is not visible in another tab unless that tab includes the file.
  This earlier proposal conflicts with ordinary `include` semantics. Keep it as an unresolved
  alternative requiring an explicit loading mechanism, not behavior already supplied by Julia.
- The order of work: first a click that writes a line into the file, then windows on names that
  the user wrote.

## What exists today

- Windows with one header, an input from the selection or from another window, and visualizers
  offered by the type of the value (`prepare!`).
- The table window, the registered plots (`register_plot!`) and the plot builder with the roles x,
  y and color.
- Registrations, `query_items`, tags with `tags.txt`, and the table of items
  `DataFrame(workspace, items)`.
- One item tree with one selection for the whole browser, as a fixed panel.

## Changes to visualizers.md

- The canvas and the planes are replaced by tabs. A plane was one graph of a shared file. A tab is
  a file of its own.
- The workspace file held only windows and transform bodies. A tab file also holds the user's
  functions and registrations, and tab files include each other.
- Debug points are new.
- Views, transforms, visualizers, outputs, identity, hover and tags stay as described there.
