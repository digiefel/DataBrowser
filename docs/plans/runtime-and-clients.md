# Runtime and clients

Target design, started on 30 October 2026. This plan owns the split between the Julia runtime and
its clients, and what crosses between them. [Visualizers](visualizers.md) owns what a visualizer
does inside a window; [graphics](graphics-grammar.md) owns plot declarations. Of the decisions
below, the visualizers of the workspace, the browser driven by code and the client calls without
the catalog lock are built, as [Architecture](../ARCHITECTURE.md) describes; only a read of a result
that its store lacks still takes that lock. Of the proposals, only `show` and `showable` of a
visualizer are built, for the Export button of the browser.

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
12. **A notebook is one possible client, not the model.** Exploratory analysis is not always a
    linear sequence of cells. A linear document is still useful for sharing, so the contract must
    make it possible to build a notebook-like client.

## Decided

- The web client is a browser UI served by a local runtime first, then a remote one.
- Julia plots are Makie figures built in the runtime; a backend per client draws them: GLMakie in
  the process that holds the figure, WGLMakie in a browser, CairoMakie pictures for terminal
  clients, agents and export. Makie is the figure model, not a backend. Requirement 6 means
  Makie is the Julia plot visualizer, not the only way to plot.
- Visualizers are building blocks, simple or sophisticated, of two origins. Runtime visualizers,
  such as Makie plots, appear in every client that can show their output. Client visualizers use
  the client's own technology and appear in that client only. Both receive data and metadata:
  DataBrowser is the layer that connects any source, any type and any visualizer. Their settings,
  output and links are held by the runtime, so blocks of both origins combine in one client and
  agents can set them up for humans to use.
- Values reach client visualizers through representations, not one format. A value offers the
  representations it can become (an image with scale, PNG, a table, its generic fields, text); a
  client visualizer declares the ones it accepts; the runtime sends a match in that
  representation's own encoding. Anyone can define a representation for a type, as with
  `show(io, MIME, x)` or Makie's `convert_arguments`. No type is excluded: generic fields, text
  and pictures from runtime visualizers always exist. Large values stay in the runtime and the
  client asks for slices or a size.
- No client call takes the catalog lock. A client call that changes the workspace, such as `tag!`
  or `evaluate` of a new computation, returns for now once the published version shows the change,
  so a script sees its own change right after the call. A call that returns at once may come
  later. [The client API](client-api.md) that does this is designed whole first, as a target of
  its own.
- A visualizer is an object of the workspace, with an id, its settings, its input and its value,
  and every client shows the same visualizers. Each client shows a visualizer in its own way: the
  browser in a window, which can close while the visualizer stays; the REPL as a picture or text
  of it as it is now; an MCP server by its id, with a picture for the agent.
  `visualize!(workspace, visualizer)` adds one to the workspace, and
  `visualize!(browser, visualizer)` also shows it in a window.
- Code drives the browser while it shows through the functions that the browser's controls call:
  `select!(workspace, ids)`, `visualize!(browser, v)`, `close(w)`, or a setting such as
  `v.inspect = true`. Automatic checks of the browser's behavior and of its performance call these
  functions, unattended, for example overnight.

## Proposals

These are not yet agreed.

- **One protocol for all clients:** commands, change events, opaque ids and values as
  representations. Julia clients use the same commands as direct calls.
- **The desktop ImGui GUI stays in the runtime's process** and uses only the public commands, ids
  and events. A Makie figure then passes from `prepare!` to `draw!` by reference, as it does now.
  It cannot serve a remote runtime; remote users use the web client.
- **WebAssembly components as a plugin format** for sources, stores and transforms: written in any
  language, sandboxed, loadable by the runtime or a client. Julia access to a WebAssembly runtime
  has not been checked.
- **The runtime ships as one app that contains Julia:** a compiled Julia program with the packages
  built in, so it starts fast and needs no Julia installation. The desktop GUI is this app; the
  Python package downloads it on first use and starts it in the background when none is running.
  It must keep the full Julia compiler, because it loads and compiles the project's Julia code.
  A stand-in app built with PackageCompiler compiles new code and installs packages
  ([check](../../work/runtime-app-check/README.md)).
- **A boundary test:** a check that fails when the GUI uses a Core name that is not public.
- **A runtime visualizer has representations, as a value does:** `show(io, mime, visualizer)` and
  `showable(mime, visualizer)` in Julia, a MIME type and bytes across the protocol. The same
  representations then serve "Export" in any client, the picture a client shows when it cannot
  draw the visualizer, and the PNG an agent asks for. A client visualizer exports with the
  technology of its client.

## Open questions

- What does a client show for a visualizer it has no drawing part for: a picture drawn by the
  runtime, the value as a table or text, or nothing?
- How does a Python client provide sources, `process` methods and visualizers to the runtime: in
  its own process over the protocol, or embedded through JuliaCall?
- Does the project ship a notebook-like client, the tools to build one, or both?
- How must a provider written in another language perform? Calls per item cross a process or
  language boundary.

## Current state

Measured on 30 October 2026, the GUI and DataBrowserPlots used 61 Core names that Core does not
export, at 267 places in 15 files, and read Core structures and locks directly. The
[boundary inventory](../../work/runtime-boundary/inventory.md) lists them by need. Identity (internal
keys in place of ids) is the largest group. DataBrowserPlots also computes fits itself and
depends on DataBrowserGUI.
