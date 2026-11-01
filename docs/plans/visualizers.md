# Visualizers

Target design, curated on 21 October 2026. This plan owns values presented by views, input binding
and linked interaction. [Tabs](tabs.md) owns analysis files and window ownership. The old canvas,
planes and single-workspace-file layout have been retired, not retained as parallel requirements.

The implemented extension contract is documented in
[visualizer_contract.jl](../../lib/DataBrowserAPI/src/visualizer_contract.jl). Method sketches in
the archived plan are not a replacement public API.

## Values and views

A view is a browser window with an input, an optional ordinary Julia transform and a visualizer.
The value remains useful outside that window. A table may be shown as a grid, plot, histogram or
summary; a matrix as a heatmap, image or row profiles. Nested structures and unfamiliar domain
values remain inspectable, at least as text.

Generic views cover common data without project-specific drawing code. Domain packages extend
the available visualizers through the public contract. Project helpers can transform a value into
another native value. The plot builder is one consumer of that shared work, not the owner of
processing and analysis.

Candidate view inputs include an explicitly followed selection, fixed items/groups or another
computed result. These must be accessible through the public API without a GUI. Fine details of
binding, discovery and switching inputs remain open.

## Window controls

UX direction agreed on 28 October 2026; not implemented.

Visualizer settings remain visible controls for the most part. Shared window controls move into
window menus: input selection, processing, following the item selection, export and arrangement.
The processing control is labeled **Process**, replacing **through**. The menus configure the
same window input and processing operations; they do not introduce another computation model.

## Code selection and step information

UX direction agreed on 28 October 2026; not implemented.

The Code visualizer presents its function steps as a selectable list. Below the list it shows
information about the selected step, rather than a preview of its returned value. The window's
output is the selected step's Computable, supplied through the ordinary visualizer output
contract. Another visualizer can take Code as its input and present that value, as it takes the
output of any other window. There is no separate open-output action.

Step information includes:

- **Cached:** yes or no, with the cache location and size when available, for example
  `Yes — memory, 2.4 MiB`.
- **Last execution:** duration and date together, for example
  `18 ms (28 Oct, 15:12:45)`. Reading a cached result does not change its execution date.

State, input count, output type/shape and failure information are additional candidate details.
The source link continues to open the step's code.

Selecting a Computable retains the existing lazy computation semantics. The backend work is
to expose the computation graph's inputs and selected computations cheaply through the shared
API. Exact APIs and selection behavior for rows representing several computations remain open.

## The value of a selection

The current public selection API provides item values and metadata through a tabular selection.
The target adds groups as selectable items with their own native results. Selecting a group does
not expand it into members; that is a separate action. A mean image appears directly, with its
input images accessible on expansion. See [groups](groupings.md#selection-and-browsing).

The target must make identity, labels, metadata and native data available consistently. Native data
can itself be a table, image, array or another value; it need not be flattened into the selection's
metadata. The exact group reconstruction and public selection representation still depend on
[processing](processing.md).

Independent tab selections and explicitly followed shared REPL selection are settled behavior.
The targeting API remains open. A read-only request for values and a request that changes a
selection must remain distinguishable.

Metadata browsing should avoid unnecessary payload reads. This is a performance requirement,
not a claim that selecting many items has zero cost. Reconstruction, metadata access, payload
loading and rendering have separate costs to measure.

## Group inputs and produced items

The [group plan](groupings.md#working-proposal-groups-from-sources-users-and-process-methods) allows a
processed group to publish standalone items. A browser must distinguish those outputs from the group's input members and
from its navigation hierarchy. Opening a row's input list is not the processing operation that
publishes new items.

A proposed interaction check: a group averages images, then a later step splits the mean image
into tiles. The selected group shows its own mean result; the original images remain accessible
as inputs. The produced tiles must also be discoverable, inspectable and reusable, with a link to
the producing work. They are not relabeled original inputs. This is an illustrative workflow,
not a new mandatory image-specific widget.

Hierarchy may have several parents. Its browsing paths must not silently change the group's
calculation inputs. GUI actions and public REPL operations need separate access to membership,
navigation and published outputs. The exact controls and public output-access operation remain
open; they must not depend on a particular plot being open.

## Transform and presentation

A transform is ordinary Julia code over the supplied value. It can map over selected inputs,
return a table, a scalar, an image or a domain result. Tracked work uses the common revision and
retained-result model; changing selection, input or relevant code refreshes affected active work.
Do not hide numerical work in per-frame drawing.

The browser implements Stack (one item at a time, with navigation arrows), Grid (one instance per
item) and Overlay for visualizers whose `prepare!` accepts a whole selection. Stack and Grid are
browser responsibilities: the visualizer receives one native value or, when it requires item
metadata, a one-item selection. The window shares its declared settings across instances; each
instance retains its own prepared data and drawing state. The arrangement and active item are
saved with the window. Vector implements overlays without concatenating the selected vectors.

Choosing a property or analysis result and the public arrangement-control API remain open.
Composed figures and registered domain plots should use the same values and input contracts.

The browser retains each visualizer instance and hands it exclusively to background `prepare!`.
While preparation runs, that window retains its last rendered contents and shows a loading
indicator in its title. Its controls, visualizer drawing, exports and output reads pause. Other
windows remain usable. When preparation finishes, the UI regains access
to the same instance or shows its error. Graphics attachment and cleanup stay on the UI thread.
UI callbacks request another preparation with `ctx.prepare()` instead of doing expensive work
during drawing.

## Source independence and extensions

Ordinary data visualizers depend on requested values and revisions, not source type. Instrument
controls, recording status and source setup expose source capabilities separately. Displaying a
value, refreshing analysis or attaching a GUI must not repeat acquisition or exports.

A visualizer belongs to its window; broader browser extensions may manage session-level UI.
Both use public workspace access rather than copies of internal catalogs or private caches.
Advanced domain packages can add specialized views without requiring simpler Recipes users to
implement presentation or storage machinery.

## Linked interaction and provenance

A view may expose selections, brushes or computed values for another view to follow. The same
connections need inspectable public definitions/results for REPL users and agents. Moving or
closing the originating window must not silently redefine a scientific computation's inputs.

Identity/provenance must connect displayed values to their actual inputs. A one-to-one transform
can retain element identity; an aggregate has a set of contributing inputs. Arbitrary custom
code cannot be assumed to provide a point-to-input mapping unless it supplies that information.
Do not invent one from row position, drawing color or a displayed tree path.

Hover, clicks and brushes should expose the relevant source/result and input provenance. Tags
are durable user annotations; live queries and filters are computed selections. Filtering a view
must not silently rewrite a group definition or imply a universal exclusion policy for all data.

## Open work

1. Public input binding and selection targeting, including fixed inputs, followed tab/shared
   selections and results referenced by another view.
2. Dispatch/discovery and settings for generic and domain visualizers, including properties,
   multiple values and arrangement capabilities.
3. Element provenance and aggregate input access, including what custom transforms must supply.
4. Linked selection behavior and feedback. Distinguish UI interaction loops from computational
   cycles. The old equality/fixed-round stopping proposal is not an approved algorithm.
5. Error/status presentation, cancellation and preservation of a completed display during work.
6. Integration with tab declarations, layout persistence and source editing. Browser geometry is
   presentation state; the analysis definitions/results must remain usable headlessly.
7. Performance on real tables, arrays and images: bounded preparation, loading and rendering
   reduction rather than unmeasured claims about a metadata-only fast path.

## Current implementation and evidence

Common visualizer windows, tables, registered plots and selection/linked-input headers exist.
The [roadmap](../roadmap.md#0110--core-visualizers) tracks their individual implementation items.
The full group, tab, provenance and linked-interaction target is not complete. The
[archive](archive/2026-10-21-discussion/visualizers.md) preserves the obsolete canvas and earlier
implementation sketches for reference only.
