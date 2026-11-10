# Visualizers

What is still open about visualizers: how a window chooses what to show, what the code view shows,
how the browser shows the items that a group produced, linked interaction and provenance, and what
crosses from the Julia host to a client. [Architecture](../ARCHITECTURE.md#visualizers) describes
the visualizers that are built, and the [vision](../vision.md) the settled direction.

## Choosing what a window shows

Generic views cover common data without project-specific drawing code. Domain packages extend
the available visualizers through the public contract. Project helpers can transform a value into
another native value. The plot builder is one consumer of that shared work, not the owner of
processing and analysis.

How a user chooses a property or an analysis result of the input, and how code changes the
arrangement of a window (Stack, Grid or Overlay), are open. So is how a visualizer type declares
which values, settings and arrangements it takes, so that the browser and code can discover it.
Composed figures and registered domain plots should use the same values and input contracts.

An input that follows the own selection of a tab is open too; [tabs](tabs.md#selection) holds that
question.

## The code view

Besides whether its store keeps the result and its last run, the code view could show more about
the selected call: its state, the number of its inputs, the type and shape of its result, and its
failure. Which of these it shows is open.

## Items that a group produced

A `process` method on a group can give new items, such as a fit through its members. The browser
has to keep these results apart from the members of the group and from the tree, which only
organizes items. Opening the members of an item is a separate action from the `process` call that
made new items. [Groups](groupings.md#members-and-the-call-that-produced-a-value) holds the
question of how the browser shows where a value came from.

A check for this: a group averages images, and a later `process` method splits the mean image into
tiles. Selecting the group shows its mean image, and the original images stay reachable as its
members. The tiles must also be easy to find, inspect and reuse, with a link to the call that made
them, and they stay apart from the original images.

An item can be in several groups, and the path to it in the tree never changes the inputs of a
calculation. The GUI and code need separate access to members, to the tree and to the items that a
call produced, and none of them can depend on an open plot. The exact controls and functions are
open.

## Linked interaction and provenance

A window may offer a selection, a brush or a computed value for another window to follow. Code and
agents need to inspect these links and their results as well. Moving or closing the window that a
link starts from must never change the inputs of a computation without the user noticing.

*Provenance*, the link from a shown value to the inputs that it came from, must name the actual
inputs. A transform that maps one value to one value can keep the identity of each element; an
aggregate has a set of inputs. Arbitrary project code gives no mapping from a point to its inputs
unless it returns one, and row position, drawing color or a path in the tree never stand in for it.

Hover, clicks and brushes should show the value under the pointer and its inputs. Tags are lasting
annotations by the user, while live queries and filters compute a selection. Filtering a window
never changes the definition of a group, and it never excludes data from other windows.

## What crosses to a client

[Runtime and clients](runtime-and-clients.md) splits this work between two processes. The transform
and `prepare!` run in the *Julia host*, the process that loads and runs project code, and drawing
belongs to the client. What then crosses from the host to the client is open:
[data, a description of the figure, or a picture](runtime-and-clients.md#what-crosses-for-a-visualizer).
That answer also decides what a client shows for a visualizer that it cannot draw.

## Open work

1. Discovery and settings of generic and domain visualizers, including properties, several values
   and arrangements.
2. Provenance of elements and access to the inputs of an aggregate, including what a transform
   must return for it.
3. Linked selection and its feedback. A loop of interactions in the GUI differs from a cycle of
   computations, and how linked selections stop updating each other is open.
4. How a window presents errors and status, and how the user cancels work.
5. Performance on real tables, arrays and images. Browsing metadata should avoid reading data;
   building the selection, reading metadata, loading data and drawing each have a cost to measure.
