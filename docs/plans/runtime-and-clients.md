# Runtime and clients

Target design, started on 30 October 2026. This plan owns the split between the Julia runtime and
its clients, and what crosses between them. [Visualizers](visualizers.md) owns what a visualizer
does inside a window; [graphics](graphics-grammar.md) owns plot declarations. Nothing here is
implemented.

## Terms

- **Runtime.** DataBrowserCore and what it needs to run: the workspace, processing, cache,
  Revise and code inspection. It always runs in a full Julia process.
- **Client.** Anything a person or an agent uses to work with a runtime: the desktop GUI, a web UI,
  a terminal UI, an agent, a Python or Julia script.
- **Provider.** Code that the runtime calls: sources, stores, recipes, `process` methods,
  visualizers. Today every provider is Julia code in the runtime's process.

## Requirements

1. **Core stays Julia.** The runtime requires the full Julia runtime, by construction.
2. **Every other component can be written in any language.** GUI, visualizers, sources, stores and
   the recipes API. The test: each could be built as a language-independent binding, and the GUI
   could be a client written in any language.
3. **All sorts of clients, several at once.** Desktop GUI, web UI, terminal UI, agents and language
   packages are all supported, at the same time on the same runtime. Supporting every kind of
   client is the intended uniqueness; no client type is dropped to simplify the model.
4. **A web UI with full capability.** Clients need not be web views, but the model must support a
   web UI in which an agent live-codes arbitrary visualizers: dashboards, layouts, themes.
5. **A visualizer can be any interactive UI.** A plot is one visualizer; a plotting script is a
   setting of that visualizer.
6. **A Python package as powerful as Julia.** It covers what DataBrowserRecipes covers and can create
   arbitrary plots, without requiring its users to learn Julia or Makie.
7. **Everything is inspectable.** From any visual a user reaches the computation, its code, its
   input items and the values in between. This is how scientists can trust code an agent wrote.
8. **Code-driven work stays first-class.** Pipelines and analyses are plain files under version
   control; GUI actions and code describe the same work.
9. **Batteries included, through public contracts only.** Built-in components use only the contracts
   a third party could use. Bundling decides which modules ship by default.
10. **Light to compile and load.** Heavy dependencies stay with the feature that needs them. A client
    that connects to a running runtime does not pay its loading time again.
11. **None of Jupyter's failures.** Each one below has the requirement that prevents it:

    | Jupyter failure | Requirement here |
    | --- | --- |
    | Each frontend (Notebook, Lab, VS Code, Colab) reimplements output and widget support, so the same output works in one and breaks in another, and users pick plot "backends" per frontend | One contract per kind of client, owned by this project and checked by tests. A client either draws a visualizer or shows its declared fallback; it never shows it partly broken. |
    | Widgets were added on top of the output model later; Python and JavaScript widget versions must match | Synchronized state (settings, output, selection) is the base of the protocol, versioned with it. |
    | Every output is styled on its own, so a notebook does not look like one application | The client gives every visualizer one theme. Visualizers use it and do not bring their own. |
    | Hidden state: cells run in any order, so the shown results may not follow from the shown code | Results follow from the dependency graph; what is shown always says which code and inputs produced it. |
    | Notebooks are JSON files with outputs inside, hard to diff and review | Work is plain source files; results are stored apart from code. |

## Decided

- The web client is a browser UI served by a local runtime first, then a remote one.
- Julia plots are Makie figures built in the runtime; a backend per client draws them: GLMakie in
  the process that holds the figure, WGLMakie in a browser, CairoMakie pictures for terminal
  clients, agents and export. Makie is the figure model, not a backend. Requirement 6 means
  Makie is the Julia plot visualizer, not the only way to plot.

## Proposals

These are not yet agreed.

- **One protocol for all clients:** commands, change events, opaque ids and transportable values
  (Arrow for tables and arrays). Julia clients use the same commands as direct calls.
- **The desktop ImGui GUI stays in the runtime's process** and uses only the public commands, ids
  and events. A Makie figure then passes from `prepare!` to `draw!` by reference, as it does now.
  It cannot serve a remote runtime; remote users use the web client.
- **A visualizer is split in two.** A part shared by all clients holds settings, output, selection
  and the prepared values. Drawing parts, one per kind of client, show it: Julia `draw!` for the
  ImGui GUI, an ES module for a web UI, text and pictures for a terminal. Jupyter widgets and
  anywidget use this split. A Python visualizer's shared part runs in Python, so the shared part
  is not always Julia code.
- **WebAssembly components as a plugin format** for sources, stores and transforms: written in any
  language, sandboxed, loadable by the runtime or a client. Julia access to a WebAssembly runtime
  has not been checked.
- **A boundary test:** a check that fails when the GUI uses a Core name that is not public.

## Open questions

- Can one visualizer instance appear in several clients at once, sharing settings and output?
- What does a client show for a visualizer it has no drawing part for: a picture drawn by the
  runtime, the value as a table or text, or nothing?
- How does a Python client provide sources, `process` methods and visualizers to the runtime: in
  its own process over the protocol, or embedded through JuliaCall?
- How must a provider written in another language perform? Calls per item cross a process or
  language boundary.

## Current state

The GUI and DataBrowserPlots use 61 Core names that Core does not export, at 267 places in 15
files, and read Core structures and locks directly. The
[boundary inventory](../../work/runtime-boundary/inventory.md) lists them by need. Identity (internal
keys in place of ids) is the largest group. DataBrowserPlots also computes fits itself and
depends on DataBrowserGUI.
