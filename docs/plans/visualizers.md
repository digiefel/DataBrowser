# Visualizers

[Architecture](../ARCHITECTURE.md#visualizers) describes the visualizers built today, and the
[vision](../vision.md) sets out the settled direction. Window input selection, code-view details,
items produced by a group, linked provenance, and host-to-client transport remain open.

## Choosing what a window shows

Generic views cover common data without project-specific drawing code, while domain packages add
custom visualizers through the public contract. Project helpers can transform any value into another
native value, and the plot builder is one consumer of that shared work rather than the owner of
processing and analysis.

How a user picks a property or analysis result from an input, and how code updates a window's
arrangement (`Stack`, `Grid`, or `Overlay`), remain open. So does how a visualizer type declares
which value types, settings, and arrangements it supports so both the browser and scripts can
discover them. Composed figures and registered domain plots should share the same value and input
contracts.

Supporting inputs that follow a tab's own selection remains open as well; see
[tabs](tabs.md#selection).

## The code view

Beyond showing whether a result is stored and when it last ran, the code view could also show the
selected call's state, input count, result type and shape, and error details; which of these appear
remains open.

## Items that a group produced

A `process` method on a group can return new items, such as a fit across its members. The browser
must keep those produced items distinct from the group's members and from the tree, which only
organizes items; expanding a group's members is separate from inspecting the items created by a
`process` call. [Groups](groupings.md#members-and-the-call-that-produced-a-value) holds the open
question of how the browser displays where a value came from.

As a test case, suppose a group averages images and a later `process` method splits the mean image
into tiles. Selecting the group shows its mean image while the original images remain accessible as
its members; the tiles must also be easy to locate, inspect, and reuse via the call that created
them, without mixing them into the original member images.

Because an item can belong to several groups, its tree path never alters calculation inputs. Both
the GUI and Julia code need separate access to members, to the tree, and to call outputs without
depending on an open plot; the exact controls and functions remain open.

## Linked interaction and provenance

A window can expose a selection, brush, or computed value for another window to follow, and scripts
and agents need to inspect those links and results too. Moving or closing a source window must never
silently change a computation's inputs.

*Provenance*, the link from a displayed value back to its inputs, must name actual inputs. While a
one-to-one transform preserves element identity and an aggregate tracks a set of inputs, arbitrary
project code provides no point-to-input map unless it returns one; row index, color, or tree path
must never stand in for provenance.

Hovering, clicking, and brushing should show the value under the pointer along with its inputs.
Tags are durable user annotations, whereas live queries and filters compute selections; filtering a
window never changes a group's definition or excludes data from other windows.

## What crosses to a client

[Runtime and clients](runtime-and-clients.md) splits visualizer work across processes: transforms
and `prepare!` run in the *Julia host*, the process that loads and executes project code, while
drawing runs in the client. What crosses from host to client —
[data, a figure description, or a picture](runtime-and-clients.md#what-crosses-for-a-visualizer) —
remains open, and that choice also determines what a client displays when it cannot draw a
visualizer natively.

## Open work

1. Discovery and settings for generic and domain visualizers, including properties, multiple values,
   and arrangements.
2. Element provenance and access to aggregate inputs, including what transforms must return.
3. Linked selections and interaction feedback, including how linked views stop updating each other
   without forming UI loops.
4. How windows present errors, status, and cancellation controls.
5. Performance on real tables, arrays, and images: metadata browsing must skip data loads, and
   selection building, metadata reads, data loading, and drawing must each be measured separately.
