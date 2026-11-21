# Processing

[Architecture](../ARCHITECTURE.md) describes `read` and `process` calls, versions, conflicts, and
`Computation` as built today, and the [vision](../vision.md) sets out the settled direction. Group
member access, consistent value construction, post-processing analysis workflows, and computation
extensions remain open.

## Ordering of operations that use a group

When two calls return a version of the same id at the same depth, they conflict. How multiple member
operations on the same member compose or branch when they do not conflict remains open.

## Members that a group receives

A group could carry a view of its members bound to the versions it was built with, so a value
carries everything its public operations need; deferred loading may back that view. Neither a
lookup in the active workspace nor a wrapper type visible to project code is settled yet. The design
must resolve:

- how multiple member operations on one member compose or branch;
- nested groups, missing inputs, and a group held in the REPL after its inputs are reread or removed;
- whether member access requires an open workspace and what stays usable after the workspace closes.

## Consistent construction

Core constructs project values when reading source items, forming groups, and restoring values from
stores. The public contract for building a group with its members remains open: the fields that
identify a group must stay separate from its members and computed fields, with a default covering
ordinary structs and an override for domain-specific types, without requiring `Lazy` fields on
project types.

Restoring a value after store eviction is not always possible, so the contract must separate a
value's stored data, what is needed to reconstruct it, and inputs that can be reread, because some
source reads and instrument operations cannot repeat.

## Analysis after item processing

The next worked example must show ordinary helper code, how selected items reach it, what each call
returns, how values are inspected and reused, how multiple visualizers share one calculation, and
what code is saved and rerun. Fixed inputs and live selections stay explicit, and after a restart, a
missing function from a previous session must be distinguished from a stored result. Shared
functions for running, inputs, and views still need a concrete design.

## Computations

`Computation(f, args...; settings...)` already builds a type from the types of `f`, its inputs,
and its settings, much like `Base.Broadcast.Broadcasted` does for `a .+ f.(b)`. Several extensions
are proposed:

- Applying the same chain to another item of the same type produces the same `Computation` type, so a
  computation built on selected items applies across items of that type like a `process` method.
- A computation exists before running, has an id, and appears in the tree as uncomputed.
- Its result type is inferred before reading data (in a probe, a fit's
  `@NamedTuple{chip::String, Rc::Float64, Rsh_W::Float64}` type inferred across the whole chain).
- A project `process` method can dispatch on a computation type, such as
  `process(project, fit::Computation{typeof(tlm)})`.
- `members` on a computation returns the items it read, traced back through its inputs, while the
  workspace tracks the reverse map (which values read each item) beside its row.
- A computation over many parts receives them as a vector so its type never grows with part count.

When Revise edits a function, its type stays unchanged so existing computations keep theirs; only its
code revision changes, and types and ids identify which values read it. In a probe, editing one
function marked 10 of 18 computed values to rerun.

### Functions identified by their code

An anonymous function gets a generated name such as `#2#3`, which shifts when earlier functions are
added; today a computation's id starts with that name. Instead, Core could record a hash of the
function's lowered code and look up the matching function inside its module on reopen. In a probe,
this matched an anonymous function across a rename from `#2#3` to `#5#6`. Lowered code alone is not
enough:

- Global names inside lowered code include their module (such as `Main.A.helper`), so identical
  source text in two modules produces different hashes.
- Two anonymous functions with identical bodies inside different enclosing functions produce one
  hash and differ only in captured values; because captured values live as fields of the function
  type, the id must include them and lookup must key on both module and enclosing function.

`Serialization` stores an anonymous function along with its code, yet loading it in a new session
creates a fresh function type that existing methods do not match.

### Compilation cost

A chain of computations compiles in roughly the same time as direct function calls — about 17 ms
per new function in a probe up to 80 steps, with inference adding about 4.5 ms per step. Because
types created dynamically during a run are not cached across sessions, each session pays this cost
on first use.

### Code revisions from the methods a call can select

Core's code revisions (`DataBrowserCore.CodeRevisions`) hash all code reachable from a function by
walking every method of every function name found in its lowered code. Julia's compiler also tracks
which methods a compiled call actually invokes as *edges*, invalidating callers when any edge
method changes. The two differ in four ways:

- Edges track argument types, listing only methods selected for those types, whereas code revisions
  walk names and include every method of each called function.
- When an argument type is unknown (for instance a value pulled from a `Dict{Symbol,Any}`), dispatch
  happens at run time and the compiler records no edge; code revisions still catch the callee
  because its name appears in the code.
- Compiler edges reset every session, whereas code revisions are content hashes persisted in the
  cache so edits made while Julia was closed still register.
- Compiler edges rely on compiler internals that can change across Julia versions, as Revise handles
  separately.

Name-based code revisions already cover everything compiler edges cover across sessions, while
edges avoid needless recomputation when a new or edited method never matches the project's data. In
the RuO2 project, adding an unused method `analyze_pund(::Vector{Float64})` triggers reruns of
`process` on 62,381 of its 65,197 items under code revisions, compared to zero under compiler edges.

One proposed improvement computes code revisions from inferred code using observed argument types,
counting only methods a call can actually dispatch to:

- A call with inferred function and argument types hashes only the methods applicable to those types.
- A call with unknown argument types or a function passed as a value (such as to `map`) hashes all
  of its methods, as code revisions do today.
- Because the revision remains a content hash of the counted methods, it still persists across
  sessions and updates after every method definition.

This stays sound because inferred types cover every type observed at run time, so any dispatched
method belongs to the hashed set. In a probe, adding `helper(::Vector{Int})` or editing
`helper(::AbstractString)` leaves the revision unchanged for code calling `helper` on a `Float64`,
adding `helper(::Float64)` updates it, and later editing `helper(::Real)` (now shadowed by
`helper(::Float64)`) leaves it unchanged; calls taking values from a `Dict{Symbol,Any}` or passing
functions to `map` still invalidate in every case.

Three limits remain untested on the RuO2 project: each distinct observed argument tuple needs its own
walk, inference costs more than reading lowered code (not measured), and walking inferred code still
depends on compiler internals.

### Project chains known before running

Starting from source item types, inference could unroll a `process` chain before any data loads:
each input type picks a method, and its inferred return type selects the next step (in a probe,
`Raw → Clean → Fitted` unrolled statically). Unrolling stops whenever:

- no project method accepts the type (the chain ends);
- the return type equals the input type ("repeat until `isequal`" must run to decide); or
- the inferred return type is non-concrete, such as `Union{Fitted, Notes}` (the next step depends on
  the runtime value, as today).

### Types of values: inferred, then observed

The plot builder chooses categorical or numeric scales from each mapped expression's type, yet paths
into item data such as `:data.I` infer as `Any` today because Core records no type for item data.
Under one proposed design:

1. The workspace keeps a single type per value alongside its status, revisions, and result, saved in
   the cache. Before execution, that type is inferred from the `Computation` type; once executed,
   `typeof(result)` replaces it, and plots, the tree, and `process` discovery all read this field.
2. Each mapping path such as `:data.I` becomes its own computation whose concrete type (e.g., a
   `DataFrame` column's vector type) is observed when computed.
3. Invalidating a result's code or input revision drops the observed type back to the inferred one.
4. Any stored type containing a function locates that function on reopen by its code hash as
   described above.
5. Across a selection, items running the same chain share an inferred type; differing observed types
   combine by `Union`, leaving a plot role's kind unknown when their kinds disagree.

### Computations over parts of the rows

`fit` and `aggregate` partition rows across multiple items by a grouping key (such as `Chip`) and
create one computation per part while minimizing data movement:

1. Each item is read once, taking only the columns named by the computation.
2. One pass over the key column assigns row indices to each part without copying rows.
3. The computation function receives column views for its part and copies only if it needs
   contiguous memory.
4. Because each part is an independent value, editing one item reruns only the parts that read it.

Outputs always record whole items as their members and, for table-backed items, can also record the
specific rows read; other data types expose whatever detail their type supports. `Result` is removed,
with `fit` and `aggregate` returning their per-part computations as a `Selection`, and `@plot`
keeps only drawing specifications (mapping and plot type) while plotting code stays out of Core.

## Open

1. Ids grow with chain length and input count; the cache may need a short hash key alongside a
   readable display name (test by attempting collisions and renaming functions).
2. Where a part's key lives: in settings, in the id, or in both.
3. How members and inputs work for computations whose output is a subset of their inputs, such as
   filters.
4. Values unsuitable for memoization: values mutated in place and code that code revisions cannot
   follow.
5. Visualizer selections as computations (a Table window's output is already `view(item, selection)`
   per item):
   - A selection restricts data in visualizer-specific ways (rows and visible columns for a Table, a
     crop for a matrix, a region for an image). It stays in memory uncached, and its definition enters
     downstream ids, while the type API governs which downstream results are cached.
   - Keeping or dropping a manual selection when underlying data changes belongs to the visualizer.
   - **View vs. copy.** For each data type, a visualizer provides both a view (`view(V, mask)`,
     `view(df, rows, cols)`) and a copy (`V[mask]`). A reader receives the view when Julia inference
     proves both identical return types and no visible side effects (`effect_free`), and receives a
     per-request copy otherwise — or whenever the value would live inside a retained or cached
     result, since a view pins its parent array. Checked via `Base.infer_return_type` and
     `Base.infer_effects` on Julia 1.13, users never choose manually: concrete struct fields like
     `V::Vector{Float64}` always receive a copy; conservative inference gives a copy to functions
     that mutate local buffers or call `@info`; and inference ignores access speed, even where a
     masked view iterates more slowly than a copy.
6. Whether Core needs a concrete `Group` type; today a computation's result keeps its own type and
   `storage(project, T)` picks a store by that type.
7. Storage encoding and code-based function lookup across restarts (lookup by module and enclosing
   function, captured values in ids, and package-defined functions).
8. First-use compilation cost in the full workspace, cache, and GUI, and whether generating a tiny
   `precompile` package helps across sessions (in a probe, a generated package precompiled in under
   a second, loaded in ~6 ms on restart, and reloaded cleanly under Revise).
9. Project methods returning multiple items: item counts are known only after execution, so their
   outputs cannot appear in the tree beforehand.
10. `read` as the root of a non-repeatable chain: its result must stay in the cache and never rerun.
11. How a group `process` accesses derived values produced from its members: because a sample mean
    gets its own id rather than becoming a new version of the sample, a `process` on the top group of
    all samples does not receive those means; comparing means across existing and future samples
    requires naming produced values.
12. How users inspect the exact input versions used when a group `process` ran on newer member
    versions than `members(group)` lists.
13. When a vector-valued result (such as one difference trace per repeat) expands into separate items
    with their own ids.

The probes above ran outside the workspace on Julia 1.13.2 and Revise 3.17.3; they are preserved in
git history (`git show 00f1e65:work/computation-graph/lazy-computed.jl` and sibling files) and do
not cover the full workspace, cache, or GUI.
