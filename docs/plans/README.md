# Design plans

These plans describe the target design of DataBrowser: what is decided, what is proposed and what is
open. [Architecture](../ARCHITECTURE.md) describes the running system, and is right where a plan
differs from it about what is built. [The roadmap](../roadmap.md) lists what is planned, and
[the changelog](../changelog.md) what was built.

Each topic has one plan that owns it. Discussion belongs in a coordination note until it changes a
decision, a proposal or an open question of that plan; review transcripts are not appended to
plans.

## The model today

- The workspace calls `read(project, source, item)` for each source item, then `process` for every
  version of a value that a method of the project takes: on an item, on a group with the values of
  its members, and on each member with its group. A chain of calls has any length; there are no
  fixed stages.
- A result with the id of the value that its call took is a later version of that value, and a
  result `isequal` to that value ends the chain. Two calls that give one id, when neither takes a
  version of it, or that give versions of one id at the same depth, conflict, and neither counts.
- A group is an item of a subtype of `AbstractGroup`, and `members(group)` gives the ids of its
  members. Members are links between items, so an item can be in several groups. The `read` of a
  source item with members can give a group, and the workspace makes one `SourceGroup` of the whole
  source.
- `storage(project, T)` chooses the store of each result type. The cache file keeps the metadata of
  each item in its table `output_metadata`, and the workspace holds it in memory in its table
  `items`.
- A `Computation` is a function call before its value is needed; `evaluate` gives its value. The
  fits of a plot, the output of a window and the selected step of the Code visualizer are
  computations.
- A visualizer is an object of the workspace, made by `visualize!`. Its input is the shared
  selection, fixed items, the items that a function keeps, or another visualizer.

## Settled direction

- A processed group stays a group and can give items of its own. A member's `process` method may
  use a processed group. A group `process` never overwrites its members.
- Selecting a group selects the group itself; selecting its members is a separate action.
- DBRecipes reads common sources and makes processed items without the type API, and its purpose
  ends there. Combining, exploring and plotting those items, and writing reproducible analysis, use
  the same tools for everyone. A recipe means something defined by DBRecipes.
- The GUI, the REPL, scripts, DBRecipes and domain packages use the same workspace. A workspace is
  not the GUI, and one process runs one workspace at a time.
- Plot and analysis definitions that are kept use clear macros, as `@plot` does; one-off calls stay
  ordinary Julia.
- Tab selections are independent. A view can follow the shared selection when asked to.
- Common plots are possible through the GUI. The code panel holds real editable source; explicit
  GUI actions may insert code, and inline controls change literal values.
- DBRecipes chooses storage for its users. A type API project can choose a store for each type.
  Core asks the stores to write, read and remove results when sources or code change.

## The plans

| Plan | Owns | Open questions |
| --- | --- | --- |
| [Groups](groupings.md) | How groups form, their ids and their hierarchy; source metadata | How hierarchy is declared; groups made by the user or the GUI; `metadata(source, item)`; a helper for the ids of produced values |
| [Processing and Recipes](processing.md) | The calls of `process`, versions, computations, construction and DBRecipes authoring | The member values that a group holds over its lifetime; deleting `reconstruct`; the shared analysis API after processing; code revisions that count only the methods a call can select |
| [Storage](storage.md) | Stores, retention, the metadata copy and sources that cannot be read again | The automatic choice of stores in DBRecipes; missing values and the lifetime of held values; the requirements of streaming sources |
| [Catalog](catalog.md) | What the cache file and memory keep of the catalog, and how a workspace opens | Delayed; source items by id, methods changed while the workspace was closed |
| [Data model](data-model.md) | How code and the GUI reach the values of selected items | The members of a selected group; the levels of groups as metadata names |
| [Graphics grammar](graphics-grammar.md) | Plot declarations and reusable graphical operations | Grammar coverage; where `Result` goes; complete GUI authoring |
| [Fitting](fitting.md) | Fitting behavior and its numerical contract | Noise models, uncertainty, failure states and the shared result contract |
| [Plot editor](../plot-editor.md) | The panels of the plot builder, its Inspector and source editing | Supported source edits, edits from other editors, selection from the code |
| [Tabs](tabs.md) | Analysis files, window ownership and independent selections | Tab files with `@layout`; debug capture; trials against the default analysis |
| [Runtime and clients](runtime-and-clients.md) | The pieces (DBCore, hosts and clients), the two contracts between them, their messages, and the path from a save to the redraw | Building that path; what crosses for a visualizer; which process the browser runs in |
| [Code editor](code-editor.md) | The code editor of the web client: structure while typing, types and values in the code, dragging code | The parser for Julia; the Julia language server, and whether LSP carries everything |
| [Client API](client-api.md) | The functions that scripts, the browser and other clients call on a workspace | The form of a `select` condition across the protocol; the result that a store lacks, read without the catalog lock |
| [Visualizers](visualizers.md) | The values that visualizers show, their inputs and linked interaction | Selection targeting, provenance and linked interaction |

## Historical records

These documents record earlier designs and reviews. The code and the plans above have moved on, and
are right where they differ.

- [Workspace graph](archive/workspace-graph/workspace-graph.md) and its
  [node states](archive/workspace-graph/01-node-states.md): the move to a catalog with one row for
  each function call, with fixed stages and collections that are now gone.
- [Source groups and source metadata](archive/source-groups.md) and its
  [toy example](archive/groups-toy.md): the proposal of 21 October, with a group `read` that took
  the values of its members. The workspace built groups in another form; [groups](groupings.md)
  keeps the parts that still hold.
- [Analysis walkthrough](archive/recipes-walkthrough.md): an example that framed shared analysis as
  DBRecipes work.
- [Scientific workspace](archive/scientific-workspace.md): the engineering review of 13 October.
  Its requirements for sources and side effects are now in [storage](storage.md) and
  [processing](processing.md).
- [The discussion archive of 21 October](archive/2026-10-21-discussion/README.md): exact copies of
  the documents before that curation, with the product review checklist.
