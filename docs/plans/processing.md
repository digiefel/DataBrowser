# Processing and Recipes

Target design, curated on 21 October 2026. This plan owns item/group computations, invocation,
input versions and reconstruction. [Groups](groupings.md) owns formation and hierarchy;
[storage](storage.md) owns retained payloads. The [architecture](../ARCHITECTURE.md) describes the
current implementation, not this complete target.

## Settled direction

Items continue through ordinary Julia dispatch. If processing returns a new type, that type's
applicable `process` methods run next. A processed group remains a group. Whether analysis remains a
separate callback is reopened by the newer proposal below.
A workspace is the analysis runtime, not the GUI; one process runs one workspace at a time.

## `process` signatures

Proposal, not decided except where marked. Groups come from the source, from the user or GUI on the fly, or from
`process` methods on groups; [groups](groupings.md) owns how they form.

```julia
process(project::AbstractProject, x::AbstractDataItem)
    -> Union{AbstractDataItem, AbstractVector{<:AbstractDataItem}}
process(project::AbstractProject, member::AbstractDataItem, group::AbstractGroup)
    -> Union{AbstractDataItem, AbstractVector{<:AbstractDataItem}}
process(project::AbstractProject, group::AbstractGroup, members::AbstractVector{T})
    -> Union{AbstractDataItem, AbstractVector{<:AbstractDataItem}}
```

- `process(project, x)` receives one item or one group (`AbstractGroup <: AbstractDataItem`).
- `process(project, member, group)` is a member `process` method, called for each member of a group.
  It returns a later version of the member (same id) or a new value, for
  example a group that keeps both inputs. Core records both inputs either way.
- `process(project, group, members)` is a `process` method on a group with its member values.
  The element type `T` of its third argument states the member values it needs: Core passes, for
  each member, its latest version of type `T`, and leaves out members that have none. A later
  member version of type `T` causes the method to be called again, unless a member `process` of
  the same group gave it: the group `process` keeps the version that it took. `members(group)` is
  unchanged: it gives the ids of the members.

Results of `process`: one `AbstractDataItem` or an `AbstractVector` of them. A vector is several outputs;
this replaces source `expand`. An empty vector is no output. Plain data (a signal, a table) is
never a result of `process`, only the data of an item.

A value made from several tracked inputs keeps them: Core records for every value what produced it
(the `process` method and its inputs) and its members, and the two can differ, as for a group filtered out of another.
Inputs that are groups are kept as they are, not flattened to their original items.

Discovery: method signatures tell Core which inputs a `process` method accepts. Return types cannot be known
before a `process` method runs; Core learns them from returned values and then finds the `process` methods that accept
them.

Stable ids: the project gives each produced value its id through `id`; see
[groups](groupings.md#stable-ids).

## Metadata comes from returned values

Core has no `analyze`. Every `process` method returns a value, and
`metadata(value)` gives its metadata. A method that only computes a few numbers returns a later
version of its input with those numbers in its metadata. Recipes keeps an `analyze` callback for
its authors and implements it with `process`.

The earlier shape, kept for its behaviors (the `analyze` methods are removed):

```julia
process(project, group) -> processed_group
analyze(project, processed_group) -> metadata

analyze(project, member, processed_group) -> member_metadata
process(project, member, processed_group) -> next_member
```

A group's own computation produces its own result. Member-aware methods belong to the member:
they may read a processed group's data and metadata and produce a later member value. A
member `process` method may return a later version of the member or a new
value that keeps both inputs; Core records both inputs either way. Later member `process` methods must be
able to use metadata computed in that work. A group does not overwrite member data
or directly produce data for each member.

The storage direction requires native values to expose complete metadata through
`metadata(value)`, with a rebuildable internal query copy. Group-aware member work uses the
member's `process` method.
The accessor of an item's data is `data`.

Two calls that give versions of one id at the same depth conflict, for example the member
`process` methods of two groups on the same member, or `process(project, v)` and
`process(project, v, group)` on the same `v`. Neither version counts, each call keeps its result,
and the status panel of the browser shows the conflict next to both calls. This does not settle
every ordering or branching question about contextual data operations.

`process(project, group)` can be called without a workspace when its arguments provide what it
needs. Processing need not access members at all. Direct calls must remain ordinary Julia calls.
How member access is supplied is still part of the reconstruction/lifetime design below.

GUI-generated graph and plot operations are ordinary workspace computations. Tracked computed
results are cached through the shared runtime; this does not promise that every arbitrary Julia
resource can be serialized. Numerical work must be reusable outside its original plotting window.

## Member inputs and versions

Settled: `members(group)` gives the ids of the members that the code which made the group gave
it, and a group `process` keeps the member versions that it took. Groups are constructed with
those members already chosen; the earlier query/prototype-binding proposal is withdrawn. Exact
version binding and lifetime remain part of the implementation contract.

The working direction is that values carry what their public operations need. Core would construct
native items and groups consistently, with a group carrying a bound member view. Deferred loading
may implement that view. Neither an implicit lookup in the current workspace nor a required
project-visible wrapper is an approved universal mechanism.

The design must resolve:

- The member snapshot used to form and process a group, and how it differs from a later member
  value produced using that group's result. Do not introduce a dependency on the group's own
  downstream output by silently asking for the latest member.
- Metadata availability to the next member `process` method, through the value that a call
  returns. Same-type changes can be real work, not evidence that processing ended.
- How several applicable member data operations compose or branch. This is separate from the
  unsupported same-name metadata collision.
- Nested groups, missing inputs and a retained REPL value after inputs are refreshed or removed.
- Whether member access requires an open workspace, and what remains usable after close. This
  must be consistent with the chosen native-value model, not inferred from a GUI lifetime.

## Invocation, readiness and completion

Dispatch continuing through new types is a direction, not a stopping algorithm. Visiting each type
once is insufficient: work can depend on new metadata, a group result or a changed input revision
without changing the member's type.

The execution proposal must define applicable invocations and their bound inputs, when relevant
producers have completed, and when an output set is final for that invocation. An input not yet
produced is not the same as a completed producer with no matching output. Previously observed
metadata keys do not prove readiness after a code change.

Group selection must not be reevaluated indiscriminately on every intermediate item version.
A group `process` method is called with the member values of the type that its signature states,
and again only when a member gets a later value of that type.

The existing catalog remains the common dependency/status model. The new design must extend that
model rather than introduce a private graph for plots or Recipes. The fixed stages are gone: every
version of a value gets the calls of `process` that a method takes. These contracts remain open:

- Invocation identity, input and code revisions, completion and replacement output sets.
- Discovery of relevant project methods, including member/group-aware and set methods, from
  input signatures; output types are known only after a `process` method runs.
- Invalidation when code, metadata, inputs or applicable operations change, including removal of
  metadata contributions that no longer exist.
- Publication of results only for the revision that actually completed, with earlier completed
  results available while affected active results recompute.
- Computational cycles and repeated work. Core repeats `process` calls until
  a chain converges, meaning a `process` call returns a value equal in content to its input (equal ids are
  not enough, since a same-id value with new content is a replacement). Core halts with an error
  after a maximum number of rounds. So a `process` method that returns its input type means "repeat until unchanged".
  Equality is `isequal`. The API supplies `isequal` and `hash` for
  `AbstractDataItem` that compare `data` and `metadata`, so project types converge
  without extra code; a project defines its own `isequal` for anything else, for example a tolerance. Julia's default `==` would not work: it
  compares mutable fields such as vectors by object identity, and `missing == missing` is `missing`. Type API
  projects may use this; Recipes does not offer it. Linked UI selections are a separate
  interaction problem.

## Live code and side effects

The workspace refreshes processing,
analysis and visualizers automatically, so it may call `read` and `process` again at any time: a
project's methods have to give the same result when called again. The workspace follows the code
revisions and the inputs of each call; what the function does inside stays the project's own.

Instrument commands, acquisition procedures, exports and other external effects run only through
public functions, called by the user or by a configured trigger. An analysis edit, a new visualizer
or an undo of the layout never calls them again. An effect inside `read` or `process` breaks their
contract; the workspace cannot prove Julia code free of effects, so this is a documented rule, not
a sandbox.

An edit makes the affected calls and the calls that depend on them stale. The calls that a window
or a script requests run again; the others wait until something asks for them. An edit that only
changes a display never makes a read or an unrelated `process` call stale.

## Consistent construction

This plan owns initial construction, group formation and binding members to a native group.

The public contract needs to cover initial construction and group member binding, with restored
values following the same native-value contract. Do not make metadata injection through
reconstruction an assumed mechanism or replace native project types with internal records.
Fields used to identify a group must be distinct from its members and computed fields. A default
should cover ordinary values; an explicit override may be needed for domain-specific construction.
Do not require `Lazy` fields in project types.

Restoration cannot be assumed possible after arbitrary eviction. A value's retained payload,
reconstruction information and replayable inputs must be distinguished. Some source reads and
instrument actions are non-repeatable. Recomputing analysis must not repeat acquisition.

## Recipes authoring

DBRecipes provides a way to read common sources and produce processed items without implementing
the type API. Its purpose ends once those items are processed. A recipe means
something defined by DBRecipes; it is not the name for a general calculation or analysis file.

Its source-reading and processing callbacks use ordinary project data. DBRecipes supplies the
native item types, identity, metadata adaptation and storage choice for this work. Its retained
analyze callback can compute metadata while adapting those processed items to the Core contract.
Authors should not implement carriers, storage or background work. The planned macro concerns
this source-to-processed-item job, not later canvas or plot analyses.

## Analysis after item processing

All users work with the processed items through the same public analysis and visualization tools,
regardless of whether the items came from DBRecipes, a type-API project or a domain package.
Combining data, trying calculations, comparing results, composing figures and saving reproducible
analysis belong here. Saving such work does not require a DBRecipes recipe or registration.

The next example must show ordinary helper code, how selected inputs reach it, what each call
returns, how values are inspected and reused, how several views use the same calculation, and
what code is saved/reexecuted. Fixed inputs and followed selections remain explicit. A missing
session-only function after restart must be distinguished from an available retained value.
The shared execution/input/view operations still need a concrete proposal.

## Computations and their outputs

The first Core implementation provides `Computation(f, args...; settings...)`, `inputs`,
`computation(workspace, item)` and `evaluate(workspace, computation)`. Project calls and interactive
operations use the same definition type and invocation. Definitions retain preceding computations;
project functions receive native values. Looking up definitions does not evaluate them. The
results that the workspace keeps for the project's calls serve evaluation, and are copied when
reused.

The project's calls now form chains of any length, without fixed stages. The store of each result
type (`storage(project, T)`), the record of each execution (`last_execution`) and the Code
visualizer are built. The examples below describe the broader target, not the
completed interface. The implemented type is `Computation <: AbstractDataItem`, rather than the
earlier illustrative `Computed <: AbstractGroup`: `inputs(computation)` gives the computations
among its inputs, and it has no `members`.

A computation is a function that Core applies to values: a `fit` or `aggregate` line of `@plot`, an
operation built in the GUI, or the same written in code. Today `fit` and `aggregate` return a
`Result` in DataBrowserPlots. This section replaces it with lazy computed values that the workspace
keeps, so that a computation defined in a plot is reusable everywhere else.

### Where project types stop

Project types are used where project code runs: `read` and the `process` methods. Values that Core
computes are never of a project type, because no project code made them. They follow the same
interface as project values (`id`, `metadata`, `data`, `members`), so Core code and project
code read them in the same way. Their data and metadata are what the computation produced from the
project's data and metadata, unchanged.

### A computation is a lazy value

Core defines one type for computations; the name `Computed` is an example. A `Computed` value holds
a function, its inputs and its settings, not its result. It works as `Base.Broadcast.Broadcasted`
does for `a .+ f.(b)`: its type is the computation, built from the types of the function and of
the inputs, so no `struct` is written or evaluated per computation.

```julia
struct Computed{F,Args<:Tuple,S<:NamedTuple} <: AbstractGroup
    f::F
    args::Args            # the inputs: items or other Computed values, never their results
    settings::S           # the arguments that are not inputs
end

x::Sweep
r   = Computed(resistance, x)
c   = Computed(corrected, r; offset = 0.5)
fit = Computed(tlm, [c₁, c₂, c₃, c₄])     # one fit over a part: its inputs as a vector

typeof(c) == Computed{typeof(corrected), Tuple{Computed{typeof(resistance), Tuple{Sweep}, …}}, …}
```

What the type gives:

- The same chain on another `Sweep` has the same type. A computation built on the selected items
  applies to every item of that type, as a `process` method does.
- The value exists before anything runs. It has an id and can appear in the tree as not computed;
  `materialize` computes it, through the cache.
- The result type is inferred from the type before any data is read. In the probe, the fit's
  `@NamedTuple{chip::String, Rc::Float64, Rsh_W::Float64}` is inferred through the whole chain.
- A project `process` method can take one computation by type, as
  `process(project, fit::Computed{typeof(tlm)})`, and reading it tells what it receives.
- The dependency graph is the nesting of the types and the inputs, read without running anything.

A `Computed` value follows the item interface. `id` is built from the function names and the
inputs' ids, such as `tlm([corrected(resistance(s1)), …])`. `data` is the result, computed
when it is used. `metadata` gives the named parts of the result, if it has any. `members` gives the
items the computation read: it is derived from `args`, by following the inputs back to items, and
not stored, so the two cannot disagree. `args` are the direct inputs and make the graph; `members`
skip the steps between. The reverse, which values read an item, is an index the workspace keeps
next to its record per id.

A function is identified across sessions by its code, not by its name. An anonymous function gets
a generated name, such as `#2#3`, which changes when other functions are added before it. Core
records the hash of its lowered code instead, and in a later session finds the function with the
same hash among the module's functions. In the probe, an anonymous function is found again after
its generated name changed from `#2#3` to `#5#6`. The code alone does not identify a function:

- Global names in lowered code carry their module, such as `Main.A.helper`, so the same text in two
  modules gives two hashes.
- Two anonymous functions with the same code in different enclosing functions give one hash, and
  differ only in the values they capture. Captured values are fields of the function's type, so the
  id must include them, and the lookup must use the enclosing function as well as the module.

A computation over many parts takes them as a vector, so its type does not grow with the number of
parts.

Edits to a function reach the open workspace through Revise, as edits to project code do today.
The function keeps its type, so the values keep theirs; its code revision changes, and the types
and ids say which values read it. In the probe, editing `corrected` marked 10 of 18 computed values
to compute again, and the two fits changed accordingly. When the function now returns something
else, inference gives the new result type.

Compilation: a chain of `Computed` values compiles in the same time as calling its functions
directly, about 17 ms per new function in the probe, up to 80 steps. Inference adds about 4.5 ms per
step. Types created while the program runs are not stored between sessions, so each session pays
this when a computation is first used.

### What Julia already records

Some of this graph exists in Julia, for compiled code. The probe `compiler-structures.jl` shows:

- Type inference gives the result type of a chain. Core uses it as is.
- The compiled code of `evaluate` for a chain records which methods it calls, transitively, as
  edges. Redefining a method two calls away ends that compiled code's validity in world ages. Core
  already computes this dependency in its own way, as code revisions (see below).
- `Serialization` stores an anonymous function together with its code. A later session gets a
  working function of a new type, not the live function, so methods written for the live function
  do not apply to it.

Julia records nothing about data: which values were computed, from which input revisions, and
where the results are. The `Computed` value, the record per id and the cache are Core's own.

The split of [runtime and clients](runtime-and-clients.md) follows the same line. Its *Julia
host*, the process that loads and runs project code, answers the questions about code: which
methods take a value of a type, and the code revision of a function. *DBCore*, the piece that
keeps the workspace, keeps the calls and their revisions.

Core's code revisions (`DataBrowserCore.CodeRevisions`, described in
[ARCHITECTURE](../ARCHITECTURE.md)) hash the code reachable from a function by following the names in
lowered code, and every method of each function reached. The two records differ:

- The compiler's edges follow types, so they list only the methods that the argument types select.
  The code revisions follow names, so they list every method of a function that is called.
- When a value's type is not known, as for a value read from a `Dict{Symbol,Any}` inside project
  code, the call is decided while running and the compiler records no edge. In the probe
  `compiler-edges-limits.jl`, redefining `helper` then did not mark the code stale. The code
  revisions still see `helper`, because its name is in the code. Core passes metadata rebuilt as a
  `NamedTuple` with the types of its values, and in the probe the edges are then recorded.
- Adding a method that does not apply to the data changes the code revision of every function that
  calls it, and the results are computed again. The edges ignore it when the types are known; when
  only an abstract type such as `Real` is known, they are marked stale too, as in the probe.
- World ages are counters of the running process and start again in each session. The code
  revisions are content hashes stored in the cache, so they also cover edits made while Julia was
  closed.
- The edges and world ranges are internal to the compiler; the code that reads them may need
  changes for a new Julia version, as Revise does.

So the code revisions already cover what the edges cover, across sessions, and the edges would only
avoid some needless recomputations. They differ only when a method is added or changed that the
data's types never select. In the RuO2 project every function has one method, so editing one
recomputes the same items under both. A new method such as `analyze_pund(::Vector{Float64})`,
which no item calls, would recompute the `process` calls of 62,381 of its 65,197 items (PUND
fatigue, PUND and wakeup) under the code revisions, and none under the edges. Proposal, not decided: code revisions that count only the methods a call can select. The walk
reads the code inferred for the observed argument types, instead of the lowered code:

- A call whose function and argument types inference knows counts the methods applicable to those
  types.
- A function called with types that are not known, or passed as a value, as to `map`, counts all
  its methods, as the code revisions do today.
- The revision is a content hash of the counted methods, so it is stored and compared across
  sessions as today, and computed again after each method definition, as today.

This is safe because inferred types contain the types that occur while running: the method chosen
while running is always one of the methods counted. A new method that the data selects changes the
set, so it changes the revision. In the probe `fused-revisions.jl`, adding `helper(::Vector{Int})`
or editing `helper(::AbstractString)` leaves unchanged the revision of code that calls `helper` with
a `Float64`; adding `helper(::Float64)` changes it, and then editing `helper(::Real)`, which
`helper(::Float64)` now hides from that data, does not. Code that calls `helper` with a value from a
`Dict{Symbol,Any}`, or passes it to `map`, changes in every case.

Limits: a walk is needed for each distinct observed argument type of a function; inference costs more
than reading lowered code, not measured; the walk reads inferred code, which is internal to the
compiler in the same way as lowered code is for today's walk. Not tested on the RuO2 project.

### Project methods in the same graph

A call of a project's `process` method is a `Computed` value too:
`Computed(process, (project, x))`. Every such call has the same function type, `typeof(process)`,
but the argument types select the method, so the type still identifies which method runs. Core
computes the inputs first, so the project's methods receive values of their own types, never a
`Computed` value.

From the types of the source items, inference unrolls the chain before anything is read: each
input type selects a method, and the method's inferred result type selects the next one. In the
probe, `Raw → Clean → Fitted` is known in advance. The unrolling stops where:

- no project method takes the type: the chain ends;
- the result type equals the input type: "repeat until unchanged" is decided while running;
- the result is not one concrete type, as `Union{Fitted, Notes}` for a method whose result depends
  on the data: the next step is known only after running, as today.

So GUI computations and the project's `process` methods form one graph. The catalog already
works this way for the calls of the project: each version of a value gets the calls that a method
takes, and the code revisions are computed per function and argument types.

### What the workspace records

The function and the inputs are in the value. The workspace keeps, under each value's id:

- the status: not computed, computing, computed or failed;
- the code revisions of the functions in its type, and the revisions of its inputs;
- the result, in the cache.

This gives memoization (the same id and revisions reuse the result), recomputation (a new revision
makes every value whose type or inputs contain it out of date), provenance (the inputs, back to the
files) and laziness (a value is computed when something asks for its result). It extends the
catalog's pipeline rows and code revisions, which already do this for `read` and `process`.

### Types of values: inferred, then observed

Proposal from the plot builder session, 25 October 2026; not decided. The plot builder decides
whether a scale holds categories or numbers from the inferred type of each mapped value. Paths into
item data, such as `:data.I`, infer as `Any` today, because Core records no type for an item's data.

1. The workspace keeps one type per value, under its id, next to its status, revisions and result,
   and the cache saves it. Before the value is computed, it is the type inferred from its
   `Computed` type. Once computed, `typeof(result)` replaces it. Plots, the tree and the discovery
   of `process` methods read this one record.
2. A path of a plot's mapping, such as `:data.I`, is a `Computed` value of its own. Its type is
   observed when it is computed: a data frame's column `I` gives a concrete vector type. No rule
   per table interface is needed.
3. An observed type is invalidated as a result is: a new code revision or input revision drops it,
   and the type falls back to inference.
4. A stored type that contains a function needs that function in a later session. It is found by
   its code, as described above.
5. Over a selection, the same chain on items of one type has one inferred type. Observed types can
   differ per item; they combine by union, and a plot role whose kinds disagree is unknown.

### Computations over parts of the rows

`fit` and `aggregate` divide the rows of several items into parts by a key, such as the values of
`Chip`, and make one `Computed` value per part. The data is moved as little as possible:

1. Each item is read once, and only the columns the computation names are taken.
2. The rows are divided by one pass over the key values, giving the row numbers of each part. No
   row is copied.
3. The function receives views of its part's columns. It copies only if it needs contiguous memory.
4. Each part is its own value, so a change to one item recomputes only the parts that read it.

An output always records whole items as its members. When an item's data is a table, it can also
record the rows it read; other data is understood only as far as its type allows.

### What this replaces

- `Result` is deleted. `fit` and `aggregate` return their `Computed` values, one per part, as a
  `Selection`.
- The `@plot` line keeps what is only about drawing: the mapping of its points and its plot type.
  Nothing about plotting goes into Core.

### Open

1. Ids grow with the length of the chain and the number of inputs. The cache may need a short
   form, such as a hash, with the readable form kept for display. To be tested by trying to make
   two values collide and by renaming functions.
2. Where the key of a part goes: in the settings, in the id, or both.
3. Members and inputs of a computation whose result is part of its inputs, such as a filter.
4. Values that cannot be memoized: a mutable value changed in place, code the revision does not
   follow.
5. A selection kept from the GUI becomes a computed value, and so
   does a window's output. Example: the Table window keeps the points of
   an IV sweep where |V| > threshold, and passes them to the Plot Builder. The Table's output is a
   computed value whose computation is the filter, with the rows and columns selected in it, if
   any. The Table built this in part: its output is one computation `view(item, selection)` for
   each item, with the rows and columns selected in it, as the docstring of `output` describes.
   Direction, in place of storing row numbers:
   - Every visualizer has a transform and a selection. Its output is the selection applied to what
     the transform gave.
   - The transform may change values. It is a computed value, and can be cached.
   - The selection only restricts data, as the visualizer defines it: rows and shown columns for a
     Table, a crop for a matrix, a region for an image. It is lazy and never cached: a view into what
     the transform gave, or a copy (see "View or copy" below).
   - The items keep their id and metadata; only their data is restricted, so the Plot Builder
     reads them by paths such as `:data.V`.
   - Each unchanged step is reused whenever the graph changes.
   - The transform becomes the window's `process`, which gives one or more
     `Computed` values, as the Plot Builder's fits do. The selection is a `Computed` value too,
     kept in memory and never cached; its definition is part of the ids of what reads it. Which
     values are cached is decided with the type API, so caching waits for this.
   - Keeping or dropping a selection made by hand when the data changes is the visualizer's job.
   - View or copy. For each type of data it shows, the visualizer gives two
     forms of its restriction: a view, such as `view(V, mask)`, `view(A, rows, cols)` or
     `view(df, rows, cols)`, and a copy, such as `V[mask]`. A project item is restricted through its
     data and rebuilt with `reconstruct(T, id, restricted data, metadata)`. A reader gets the view
     when inference proves both that it returns the same type with the view as with the copy, and
     that it writes nothing visible (`effect_free`). Otherwise it gets the copy, made once for each
     request; so does a view that would be kept inside a result that is kept or cached, since the
     view keeps its whole parent and serializing it writes the parent. Users never choose; a
     function that accepts `AbstractVector` and does not change its input gets views. Checked
     with `Base.infer_return_type` and `Base.infer_effects` on Julia 1.13.
     - A struct field of a concrete type, such as `V::Vector{Float64}`, cannot hold a view, so its
       item always gets the copy.
     - Inference is conservative: a function that changes only its own copy, or logs with `@info`,
       gets a copy.
     - Inference does not see speed: a view through a mask is slower to read element by element, so
       a function that reads the data many times may be faster with a copy.
6. Whether Core's concrete `Group` remains. Core has none today: a computation's result keeps
   its own type, and `storage(project, T)` chooses its store by that type.
7. How the cache stores a value, and finding functions by their code: the lookup by module and
   enclosing function, captured values in the id, and functions from packages.
8. The first-use cost in the real catalog, cache and GUI, and whether a generated package of
   `precompile` calls can store that compiled code between sessions.
9. Project methods that return several items: how many is known only after running, so their
   outputs cannot appear in the tree before.
10. `read` as the first value of each chain: a non-repeatable read must keep its result in the
    cache, never be computed again.
11. How a group `process` method reaches values produced from its members. A mean of each sample
    has an id of its own, so it is not a later version of the sample, and a `process` method on the
    group of all samples does not receive the means. A comparison of every sample mean, including
    samples added later, needs a way to name those produced values.
12. How a user sees the exact versions of the inputs that a call used, when a group `process`
    method received later versions of its members than `members(group)` lists.
13. When a result whose data is a vector, such as one difference trace for each repeat, becomes
    several items, each with an id of its own.

## Evidence and limits

The current implementation has chains of `process` calls and live code invalidation. That work is not proof of the
new invocation, group reconstruction or Recipes contracts.

The probes in `work/computation-graph` were run outside the workspace, on Julia 1.13.2 and
Revise 3.17.3. The folder left the repository in commit `99e6737`; `git show 00f1e65:work/computation-graph/lazy-computed.jl`
prints a probe.

- `lazy-computed.jl`: the lazy `Computed` value on a chain of two steps and a fit per chip. Equal
  types for different items, ids before running, the inferred result type, a `process` method on
  the fit, computing through a memo, and a Revise edit marking the values that read it.
- `type-api-graph.jl`: a type-API project's `process` chain unrolled by inference before running,
  stopping at a result that depends on the data, and the same chain computed as lazy values.
- `anonymous-by-content.jl`: an anonymous function found again in a later session by the hash of
  its lowered code, after its generated name changed.
- `compiler-structures.jl`: the compiler's edges for a chain, their invalidation by a redefined
  method two calls away, and an anonymous function stored by `Serialization`.
- `fused-revisions.jl`: a code revision from the methods that inferred argument types select, with
  every method counted where the types are not known; added and edited methods that the data does
  not select leave it unchanged.
- `compiler-edges-limits.jl`: edges missed through a `Dict{Symbol,Any}` value and a stored
  function, recorded again when the same metadata is rebuilt with its values' types, and code
  marked stale by a method that does not apply to the data.
- `lazy-depth.jl`: compile time and inference against chain depth, up to 80 steps, compared with
  calling the same functions directly.
- `compile-cost.jl`: the first use of a new type costs about 10–30 ms when values are held in an
  abstract vector, and about 120 ms for a sort of a concrete vector of it.
- `parametric-kinds.jl`: an earlier shape, with the computation's name as a type parameter.
- `generated-package.jl` and `generated-package-revise.jl`: a struct written per computation. A
  package written at runtime precompiles in under a second and loads in about 6 ms in the next
  session; Revise follows it when it is rewritten during a session.

They do not cover the real catalog, cache or GUI.
