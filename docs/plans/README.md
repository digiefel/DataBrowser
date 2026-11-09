# Active design plans

Curated on 21 October 2026. These plans describe the target design. A decision here does not mean
it is implemented. [Architecture](../ARCHITECTURE.md) describes the running system;
[the roadmap](../roadmap.md) tracks implementation.

Each topic has one owner document. Discussion belongs in a coordination note until it changes a
decision, proposal or open question in that document. Do not append review transcripts to plans.
The [discussion archive](archive/2026-10-21-discussion/README.md) preserves the earlier documents.

## Settled direction

- Groups generalize hierarchical collections, with several parents allowed. A group is an item
  with its own reusable result; its inputs remain accessible separately. Selecting a group does
  not select its members.
- A processed group remains a group and can publish additional standalone items. A member's own
  steps may use a processed group. Group processing does not overwrite members or directly return
  data for each member. The standalone-output API remains open.
- Processing continues through dispatch on returned types. The workspace works this way: the fixed
  stages are gone, and each version of a value gets the calls of `process` that a method takes.
  The execution and completion rules still need design.
- DBRecipes reads common sources and produces processed items without requiring the type API.
  Its purpose ends there. Combining, exploring and plotting those items, and writing reproducible
  analysis, use the same tools for everyone. A recipe means something defined by DBRecipes.
- GUI, REPL/CLI, Recipes and domain packages use the same workspace model. A workspace is not the
  GUI. One process runs one workspace at a time.
- Persistent plot, analysis and canvas definitions use clear macros. One-off calls remain ordinary
  Julia. These shared analysis macros are independent of DBRecipes; exact names/grammar are open.
- Tab selections are independent. A view can explicitly follow the shared REPL selection.
- Common plots must be possible through the GUI. The code panel contains real editable source.
  Explicit GUI actions may insert code; inline controls change literal values.
- Recipes chooses suitable storage automatically; its users do not think about stores. Advanced
  type API projects can declare storage per item type. Core requests storage operations in response
  to source/code changes; stores implement them under project policy.
- Stores retain native values and their metadata. Core's metadata copy serves queries/browsing
  and is rebuildable. The declaration/provider protocol remains open.

## Where each topic belongs

| Plan | Owns | Main unresolved work |
| --- | --- | --- |
| [Groups](groupings.md) | Group behavior, formation, identity and hierarchy | Source-group input binding, hierarchy, source metadata and produced IDs |
| [Source groups and metadata](source-groups.md) | Source membership and source-provided metadata | Source-provided metadata; explicit source-group subtype parked |
| [Processing and Recipes](processing.md) | Item/group steps, invocation, reconstruction and authoring | Invocation/completion, bound members and runtime analysis integration |
| [Analysis walkthrough (being rewritten)](recipes-walkthrough.md) | Combining processed items, exploration and reproducible analysis | Replace the incorrect Recipes framing with the shared analysis API |
| [Storage](storage.md) | Payload retention, internal index and domain extensions | Native restoration and result lifetime |
| [Catalog](catalog.md) | What the cache file and memory keep of the catalog, and how a workspace opens | Delayed; source items by id, methods changed while closed |
| [Data model](data-model.md) | How code and the GUI reach the values of selected items | The members of a selected group; paths into data of a project's own type |
| [Graphics grammar](graphics-grammar.md) | Plot declarations and reusable graphical operations | Grammar coverage, shared computation integration, complete GUI authoring |
| [Fitting](fitting.md) | Fitting behavior and numerical contracts | Noise models, uncertainty, failure states and solver validation |
| [Plot editor](../plot-editor.md) | Panels, Inspector and source editing | Supported source edits, external edits, defaults and code selection |
| [Tabs](tabs.md) | Analysis files, live work and independent selections | File/window ownership, debug capture and repeat scope |
| [Runtime and clients](runtime-and-clients.md) | The pieces (DBCore, hosts and clients), the two contracts between them, their messages, and the path from a save to the redraw | Building that path; what crosses for a visualizer; which process the browser runs in |
| [Code editor](code-editor.md) | The code editor of the web client: structure while typing, types and values in the code, dragging code | The parser for Julia; the Julia language server, and whether LSP carries everything |
| [Client API](client-api.md) | The functions that scripts, the browser and other clients call on a workspace | The form of a `select` condition across the protocol; the result that a store lacks, read without the catalog lock |
| [Visualizers](visualizers.md) | Native values, view inputs and linked interaction | Input targeting, provenance and linked interaction behavior |
| [Scientific workspace](scientific-workspace.md) | Shared source, analysis and acquisition requirements | Source/acquisition integration with the newer processing model |

The [workspace-graph plan](workspace-graph/workspace-graph.md) records the catalog cutover. Its
fixed stages, collection tree and storage layout are not requirements for the newer target, and
the workspace has since replaced them: its catalog has one row for each function call.
The [product review checklist](archive/2026-10-21-discussion/product-review.md) covers all five audiences;
it does not own another copy of the decisions.

## Open design work

The current external proposal is in [the group walkthrough](groups-toy.md), summarized in
[groups](groupings.md). Latest direction relayed by the external agent on 21 October: groups come
from sources, explicit user/GUI actions, or steps on groups. Set steps over an implicit group of
all values of a type are withdrawn; select everything explicitly when that is the intended input.
The rewritten walkthrough uses the new [source-group proposal](source-groups.md): sources declare
membership between source items and metadata per source item; typed group reads receive chosen
member values. The workspace built part of this contract in another form. A source states
membership with `members(source, item)`, and the `read` of a source item with members can give a
group whose members are the ids of those source items. A group `process` method receives the
member values of the type that it states, and the group `read` of the proposal was not built. The
workspace also makes one `SourceGroup` of the whole source. The group and
processing summaries now use this model; the query/prototype-binding and implicit set-step drafts
remain withdrawn.

Results with multiple tracked inputs retain provenance even when their own data is one image,
scalar or fitted model. A member method may return a later version of the member, with Core
recording both inputs. Projects supply each native value's `id`; Core does not compose IDs.
DBRecipes supplies identity for its own processed values. The current review is ordinary analysis
after items have been processed: combining data, inspecting it in several ways, building figures
and saving reproducible code. The [worked draft](recipes-walkthrough.md) is being rewritten because
it incorrectly assigned this work to DBRecipes. The shared analysis API is independent of its macro.

Several parents and publishing standalone items from processed groups were approved on 21 October.
What remains open is how hierarchy is declared and how output expansion is called/published,
not whether those capabilities belong in the model.

The domain-storage authority question was answered on 21 October: both storage and retention/
recomputation, with per-item-type declarations and a supplied default. The workspace has both:
`storage(project, T)` chooses the store of each type, the default is a `MemoryStore`, and the
docstring of `AbstractStore` lists the methods of a store.

Davide's decisions, relayed 21 October: Core drops `analyze` and `reconstruct`; returned native
values expose complete metadata and typed stores restore them. Core has no `analyze`, but
DataBrowserAPI still has `reconstruct`: `DuckDBStore` and `view` of an item call it. Recipes retains `analyze` for
authors and implements it through `process`. Full rescans suffice for now. Typed group-member
arguments are included. Recipes uses a file/load-time macro to generate types and methods; exact
source-reading/processing macro form remains open. The earlier result/register_result! proposal
and the later DBRecipes macro framing of general analysis are withdrawn. Shared analysis needs
its own worked code example using the same tools for every user.

Bounded content convergence uses `isequal`, with a supplied default for data items that compares
`data` and `metadata`; project types may specialize it. Recipes does not expose that iteration model. The
workspace implements both: DataBrowserAPI defines that `isequal`, and a chain of calls ends at a
result `isequal` to the version that the call took. The source-group abstract type
is parked; ordinary records and group records should have distinct source-item types.
