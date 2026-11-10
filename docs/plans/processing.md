# Processing

What is still open about `process` methods, the members that a group receives, and computations.
[Architecture](../ARCHITECTURE.md) describes the calls of `read` and `process`, versions, conflicts
and `Computation`, which are built; the [vision](../vision.md) gives the settled direction.

## Ordering of operations that use a group

When two calls give a version of one id at the same depth, they conflict. How several member
operations on one member are ordered or branch otherwise, such as one after the other, is open.

## Members that a group receives

A group could carry a view of its members, bound to the versions it was made with, so that a value
carries what its public operations need. Deferred loading may implement that view. Neither a lookup
in the current workspace nor a wrapper type visible to the project is decided. The design must
resolve:

- how several member operations that apply to one member compose or branch;
- nested groups, missing inputs, and a value kept in the REPL after its inputs are read again or
  removed;
- whether member access needs an open workspace, and what stays usable after the workspace closes.

## Consistent construction

Core makes the values of a project when it reads them, when it forms a group, and when it restores
them from a store. The public contract for making a group with its members is open. The fields
that identify a group must be distinct from its members and from computed fields. A default should
cover ordinary values; an explicit override may be needed for construction specific to a domain.
Project types never need `Lazy` fields.

Restoring a value after it was removed from a store is not always possible. The contract must tell
apart a value's stored data, what is needed to make it again, and the inputs that can be read
again. Some source reads and instrument actions cannot be repeated.

## Analysis after item processing

The next example must show ordinary helper code, how the selected items reach it, what each call
returns, how values are inspected and reused, how several visualizers use the same calculation, and
what code is saved and run again. Fixed inputs and followed selections stay explicit. After a
restart, a function that existed only in the last session must be told apart from a result that is
still stored. The shared functions for running, inputs and views still need a concrete proposal.

## Computations

`Computation(f, args...; settings...)` is built: its type is made from the types of the function,
the inputs and the settings, as `Base.Broadcast.Broadcasted` is for `a .+ f.(b)`. Proposal, not
built:

- The same chain on another item of the same type has the same type, so a computation made on the
  selected items applies to every item of that type, as a `process` method does.
- A computation exists before anything runs. It has an id and appears in the tree as not computed.
- Its result type is inferred before any data is read. In a probe, the result type of a fit,
  `@NamedTuple{chip::String, Rc::Float64, Rsh_W::Float64}`, is inferred through the whole chain.
- A project `process` method takes one computation by type, as
  `process(project, fit::Computation{typeof(tlm)})`.
- `members` of a computation gives the items it read, derived from its inputs by following them
  back to items. The workspace keeps the reverse, which values read an item, next to its row.
- A computation over many parts takes them as a vector, so its type does not grow with the number
  of parts.

When a function is edited through Revise, its type stays the same, so the computations keep theirs;
its code revision changes, and the types and ids say which values read it. In a probe, editing one
function marked 10 of 18 computed values to compute again.

### Functions identified by their code

An anonymous function gets a generated name, such as `#2#3`, which changes when other functions are
added before it. Today the id of a computation starts with that name. Instead, Core could record the
hash of the function's lowered code, and in a later session find the function with the same hash
among the module's functions. In a probe, an anonymous function was found again after its generated
name changed from `#2#3` to `#5#6`. The code alone does not identify a function:

- Global names in lowered code carry their module, such as `Main.A.helper`, so the same text in two
  modules gives two hashes.
- Two anonymous functions with the same code in different enclosing functions give one hash, and
  differ only in the values they capture. Captured values are fields of the function's type, so the
  id must include them, and the lookup must use the enclosing function as well as the module.

`Serialization` stores an anonymous function with its code, but a later session gets a working
function of a new type: methods written for the live function do not apply to it.

### Compilation cost

A chain of computations compiles in the same time as calling its functions directly, about 17 ms
for each new function in a probe, up to 80 steps; inference adds about 4.5 ms for each step. Types
created while the program runs are not stored between sessions, so each session pays this when a
computation is first used.

### Code revisions from the methods a call can select

Core's code revisions (`DataBrowserCore.CodeRevisions`) hash the code reachable from a function by
following the names in its lowered code, and every method of each function reached. The compiler
also records which methods a compiled function calls, as *edges*, and a redefined method ends the
validity of the code that calls it. The two records differ:

- The edges follow types, so they list only the methods that the argument types select. The code
  revisions follow names, so they list every method of a function that is called.
- When a value's type is not known, as for a value read from a `Dict{Symbol,Any}`, the method is
  chosen while running and the compiler records no edge. The code revisions still see the function,
  because its name is in the code.
- The edges are counters of the running process and start again in each session. The code
  revisions are content hashes stored in the cache, so they also cover edits made while Julia was
  closed.
- The edges are internal to the compiler, so the code that reads them may need changes for a new
  Julia version, as Revise does.

The code revisions cover what the edges cover, across sessions; the edges would only avoid some
needless recomputations, when a method is added or changed that the data's types never select. In
the RuO2 project, a new method `analyze_pund(::Vector{Float64})` that no item calls would compute
again the `process` calls of 62,381 of its 65,197 items under the code revisions, and none under the
edges.

Proposal, not decided: a code revision that counts only the methods a call can select. The walk
reads the code inferred for the observed argument types, instead of the lowered code:

- A call whose function and argument types inference knows counts the methods applicable to those
  types.
- A function called with types that are not known, or passed as a value, as to `map`, counts all
  its methods, as the code revisions do today.
- The revision is a content hash of the counted methods, so it is stored and compared across
  sessions, and computed again after each method definition, as today.

This is safe because inferred types contain the types that occur while running: the method chosen
while running is always one of the methods counted. A new method that the data selects changes the
set, so it changes the revision. In a probe, adding `helper(::Vector{Int})` or editing
`helper(::AbstractString)` leaves unchanged the revision of code that calls `helper` with a
`Float64`; adding `helper(::Float64)` changes it, and then editing `helper(::Real)`, which
`helper(::Float64)` now hides from that data, does not. Code that calls `helper` with a value from a
`Dict{Symbol,Any}`, or passes it to `map`, changes in every case.

Limits: a walk is needed for each distinct observed argument type of a function; inference costs more
than reading lowered code, not measured; the walk reads inferred code, which is internal to the
compiler as lowered code is. Not tested on the RuO2 project.

### Project chains known before running

From the types of the source items, inference could unroll the chain of `process` calls before
anything is read: each input type selects a method, and the method's inferred result type selects
the next one. In a probe, `Raw → Clean → Fitted` is known in advance. The unrolling stops where:

- no project method takes the type: the chain ends;
- the result type equals the input type: "repeat until unchanged" is decided while running;
- the result is not one concrete type, as `Union{Fitted, Notes}` for a method whose result depends
  on the data: the next step is known only after running, as today.

### Types of values: inferred, then observed

Proposal, not decided. The plot builder decides whether a scale holds categories or numbers from
the inferred type of each mapped value. Paths into item data, such as `:data.I`, infer as `Any`
today, because Core records no type for an item's data.

1. The workspace keeps one type for each value, under its id, next to its status, revisions and
   result, and the cache saves it. Before the value is computed, it is the type inferred from its
   `Computation` type. Once computed, `typeof(result)` replaces it. Plots, the tree and the
   discovery of `process` methods read this one record.
2. A path of a plot's mapping, such as `:data.I`, is a computation of its own. Its type is observed
   when it is computed: a data frame's column `I` gives a concrete vector type.
3. An observed type is dropped as a result is: a new code revision or input revision drops it, and
   the type falls back to inference.
4. A stored type that contains a function needs that function in a later session. It is found by
   its code, as described above.
5. Over a selection, the same chain on items of one type has one inferred type. Observed types can
   differ for each item; they combine by union, and a plot role whose kinds disagree is unknown.

### Computations over parts of the rows

`fit` and `aggregate` divide the rows of several items into parts by a key, such as the values of
`Chip`, and make one computation for each part. The data is moved as little as possible:

1. Each item is read once, and only the columns the computation names are taken.
2. The rows are divided by one pass over the key values, giving the row numbers of each part. No
   row is copied.
3. The function receives views of its part's columns. It copies only if it needs contiguous memory.
4. Each part is its own value, so a change to one item computes again only the parts that read it.

An output always records whole items as its members. When an item's data is a table, it can also
record the rows it read; other data is understood only as far as its type allows.

- `Result` is deleted. `fit` and `aggregate` return their computations, one for each part, as a
  `Selection`.
- The `@plot` line keeps what is only about drawing: the mapping of its points and its plot type.
  Nothing about plotting goes into Core.

## Open

1. Ids grow with the length of the chain and the number of inputs. The cache may need a short
   form, such as a hash, with the readable form kept for display. To be tested by trying to make
   two values collide and by renaming functions.
2. Where the key of a part goes: in the settings, in the id, or both.
3. Members and inputs of a computation whose result is part of its inputs, such as a filter.
4. Values that cannot be memoized: a mutable value changed in place, code the revision does not
   follow.
5. A visualizer's selection as a computation. The output of a Table window is already one
   computation `view(item, selection)` for each item. Direction for the rest:
   - The selection only restricts data, as the visualizer defines it: rows and shown columns for a
     Table, a crop for a matrix, a region for an image. It is kept in memory and never cached; its
     definition is part of the ids of what reads it. Which values are cached is decided with the
     type API.
   - Keeping or dropping a selection made by hand when the data changes is the visualizer's job.
   - View or copy. For each type of data it shows, the visualizer gives two forms of its
     restriction: a view, such as `view(V, mask)` or `view(df, rows, cols)`, and a copy, such as
     `V[mask]`. A reader gets the view when inference proves both that it returns the same type
     with the view as with the copy, and that it writes nothing visible (`effect_free`). Otherwise
     it gets the copy, made once for each request; so does a view that would be kept inside a
     result that is kept or cached, since the view keeps its whole parent. Users never choose.
     Checked with `Base.infer_return_type` and `Base.infer_effects` on Julia 1.13.
     - A struct field of a concrete type, such as `V::Vector{Float64}`, cannot hold a view, so its
       item always gets the copy.
     - Inference is conservative: a function that changes only its own copy, or logs with `@info`,
       gets a copy.
     - Inference does not see speed: a view through a mask is slower to read element by element, so
       a function that reads the data many times may be faster with a copy.
6. Whether Core needs a concrete `Group`. Core has none today: a computation's result keeps its own
   type, and `storage(project, T)` chooses its store by that type.
7. How the cache stores a value, and finding functions by their code: the lookup by module and
   enclosing function, captured values in the id, and functions from packages.
8. The first-use cost in the real workspace, cache and GUI, and whether a generated package of
   `precompile` calls can store that compiled code between sessions. In a probe, a package written
   while the program runs precompiles in under a second and loads in about 6 ms in the next
   session, and Revise follows it when it is written again.
9. Project methods that return several items: how many is known only after running, so their
   outputs cannot appear in the tree before.
10. `read` as the first value of each chain: a read that cannot be repeated must keep its result in
    the cache, and is never computed again.
11. How a group `process` method reaches values produced from its members. A mean of each sample
    has an id of its own, so it is not a later version of the sample, and a `process` method on the
    group of all samples does not receive the means. A comparison of every sample mean, including
    samples added later, needs a way to name those produced values.
12. How a user sees the exact versions of the inputs that a call used, when a group `process`
    method received later versions of its members than `members(group)` lists.
13. When a result whose data is a vector, such as one difference trace for each repeat, becomes
    several items, each with an id of its own.

The probes cited above ran outside the workspace, on Julia 1.13.2 and Revise 3.17.3. They are in
the git history: `git show 00f1e65:work/computation-graph/lazy-computed.jl` prints one, and the
folder holds the others. They do not cover the real workspace, cache or GUI.
