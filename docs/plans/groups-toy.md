# Groups: toy example

A complete toy project, used to reason about how a workspace starts, creates values and calls
project functions when groups exist. Written before groups were built: the
[Architecture](../ARCHITECTURE.md) page describes groups as built, and is right where the two differ.
The source API it uses is proposed in [source-groups.md](source-groups.md). Places where the
design is not settled are marked **OPEN**; places with a known cost are marked **COST**.

## The model in one paragraph

A group is an item that contains other items or groups; it defines `members`. Groups have three
creators. The source creates groups from what it knows, for example directories. The user or the
GUI creates groups on the fly, for example a selection or the bins of a plot. `process` methods on groups
create results, and a result made from tracked inputs is a group of those inputs. A `process` method returns
one item or a vector of items. The same id with new content is a later version of the same value.

## The data

A directory of samples. Each sample's temperature is in `metadata.txt`. Files `a_*.csv` hold a
signal, one number per line; `b_1.csv` holds something unrelated.

```
data/
├─ metadata.txt          path,temperature
│                        S1,280
│                        S2,410
├─ S1/
│  ├─ a_1.csv
│  └─ a_2.csv
├─ S2/
│  └─ a_3.csv
└─ b_1.csv
```

## The project

`AnnotatedDirectorySource` is DirectorySource plus `metadata.txt`; it gives every source item the
`metadata.txt` entries of the directories that contain it. See
[source-groups.md](source-groups.md#metadatatxt-outside-directorysource). The project argument of
`read` is left out, as agreed for now.

```julia
using DataBrowser, Statistics

struct ToyProject <: AbstractProject end
source = AnnotatedDirectorySource("data")

# --- Items, read from files -------------------------------------------------------------

struct ItemA <: AbstractDataItem
    id::String
    temperature::Float64
    signal::Vector{Float64}
end
struct ItemB <: AbstractDataItem
    id::String
    values::Vector{Float64}
end

# metadata(s, f) holds the temperature of the file's sample, from metadata.txt
read(s::AnnotatedDirectorySource, f::SourceFile) =
    startswith(basename(id(f)), "a_") ?
        ItemA(id(f), metadata(s, f)[:temperature], parse.(Float64, readlines(f.filepath))) :
        ItemB(id(f), parse.(Float64, readlines(f.filepath)))

id(a::ItemA) = a.id
data(a::ItemA) = a.signal
metadata(a::ItemA) = Dict(:temperature => a.temperature)
id(b::ItemB) = b.id
data(b::ItemB) = b.values

# --- Processed items: same id, so each is a later version of its item --------------------

struct ProcessedItemA <: AbstractDataItem
    id::String
    temperature::Float64
    signal::Vector{Float64}
    peak::Float64
end
struct ProcessedItemB <: AbstractDataItem
    id::String
    total::Float64
end

function process(::ToyProject, a::ItemA)
    smoothed = smooth(a.signal)                    # an ordinary project helper
    return ProcessedItemA(a.id, a.temperature, smoothed, maximum(smoothed))
end
process(::ToyProject, b::ItemB) = ProcessedItemB(b.id, sum(b.values))

id(p::ProcessedItemA) = p.id
data(p::ProcessedItemA) = p.signal
metadata(p::ProcessedItemA) = Dict(:temperature => p.temperature, :peak => p.peak)
id(p::ProcessedItemB) = p.id
metadata(p::ProcessedItemB) = Dict(:total => p.total)

# --- Groups, read from directories -------------------------------------------------------

struct SampleGroup{V<:AbstractVector} <: AbstractGroup
    id::String
    temperature::Float64
    members::V
end
id(g::SampleGroup) = g.id
members(g::SampleGroup) = g.members
metadata(g::SampleGroup) = Dict(:temperature => g.temperature)

# Core reads the members and passes them; the element type states which values the group holds.
# Samples hold processed measurements; the root holds samples and b_1. All directories are one
# source item type, so one method states one type for both, and the root is told apart by its id.
read(s::AnnotatedDirectorySource, d::SourceDirectory,
     members::AbstractVector{Union{SampleGroup, ProcessedItemA, ProcessedItemB}}) =
    id(d) == "." ? SourceGroup(id(d), metadata(s, d), members) :
                   SampleGroup(id(d), metadata(s, d)[:temperature], members)

# --- Results of groups -------------------------------------------------------------------

# Each sample's own result: its mean signal. It is made from the sample, so it is a group of it.
struct MeanSignal{G<:AbstractGroup} <: AbstractGroup
    sample::G
    signal::Vector{Float64}
end
id(m::MeanSignal) = "mean " * id(m.sample)
members(m::MeanSignal) = [m.sample]
data(m::MeanSignal) = m.signal

# The third argument states the member values needed: Core passes the processed measurements
process(::ToyProject, g::SampleGroup, ps::AbstractVector{ProcessedItemA}) =
    MeanSignal(g, mean(p.signal for p in ps))

# Two groups across samples, made by one `process` method on the root
struct HotGroup{V<:AbstractVector} <: AbstractGroup
    members::V
end
struct HighPeakGroup{V<:AbstractVector} <: AbstractGroup
    members::V
end
id(::HotGroup) = "hot"
id(::HighPeakGroup) = "high peak"
members(g::HotGroup) = g.members
members(g::HighPeakGroup) = g.members

# Everything below a group that is not itself a group
measurements(g) = [m for x in members(g) for m in (x isa AbstractGroup ? measurements(x) : [x])]

process(::ToyProject, root::SourceGroup) = [
    HotGroup(filter(m -> m isa SampleGroup && m.temperature > 300, members(root))),
    HighPeakGroup(filter(m -> m isa ProcessedItemA && m.peak > 5, measurements(root))),
]
```

## The type API this uses

From [source-groups.md](source-groups.md#the-source-api):

```julia
# Source: Core calls these
items(source::AbstractDataSource) -> Vector{<:AbstractDataSourceItem}
members(source::AbstractDataSource, group::AbstractDataSourceItem) -> Vector{<:AbstractDataSourceItem}
metadata(source::AbstractDataSource, x::AbstractDataSourceItem) -> Dict{Symbol,Any}
read(source::AbstractDataSource, x::AbstractDataSourceItem) -> AbstractDataItem
read(source::AbstractDataSource, group::AbstractDataSourceItem,
     members::AbstractVector{T}) -> AbstractGroup        # T: the member values the group needs

# Values: AbstractGroup <: AbstractDataItem
id(x::AbstractDataItem) -> String
metadata(x::AbstractDataItem) -> Dict{Symbol,Any}
data(x::AbstractDataItem) -> Any
members(group::AbstractGroup) -> AbstractVector{<:AbstractDataItem}

# `process` methods
process(project::AbstractProject, x::AbstractDataItem)
    -> Union{AbstractDataItem, AbstractVector{<:AbstractDataItem}}
process(project::AbstractProject, member::AbstractDataItem, group::AbstractGroup)
    -> Union{AbstractDataItem, AbstractVector{<:AbstractDataItem}}
process(project::AbstractProject, group::AbstractGroup, members::AbstractVector{T})
    -> Union{AbstractDataItem, AbstractVector{<:AbstractDataItem}}
```

Arguments of `process`:

- `process(project, x)` receives one item or one group.
- `process(project, m, g)` is a member `process` method: Core calls it for each member `m` of a group `g`.
  This toy has none; see [source-groups.md](source-groups.md#case-2-temperature-as-data-metadata-a-file-in-the-sample).
  Davide, 21 October: a member `process` method returns an `AbstractDataItem`, which covers groups: a later
  version of `m` (same id) or a new value, for example a group that keeps both `m` and `g`. Core records that the output came
  from `m` and `g` either way. Whether the group is read again depends only on whether the output
  is a later value of the member type the group states.

- `process(project, g, members)` is a `process` method on a group `g` with its member values.
  Davide, 21 October: a `process` method on a group can state the member values it needs as a
  third argument, as group `read` does. Core passes, for each member, its latest value of type `T`,
  and leaves out members that have none. A later member value of type `T` causes the method to be
  called again, with the same convergence rule. `members(group)` is unchanged: it still returns
  the values the group was made with.
  `MeanSignal` uses it.

Results of `process`: an `AbstractDataItem`, or an `AbstractVector` of them, which is several outputs. An
empty vector is no output. Plain data, such as a signal or a table, is never a result of `process`: it is
the data of an item. Julia allows one method per signature, so a `process` method that makes several results
from one input returns them as a vector.

Versions: a value with the id of an earlier value is a later version of it. `ProcessedItemA` keeps
the id of its `ItemA`, so it is a later version. `MeanSignal` has its own id, so it is a new value.

## Startup

### 1. Discovery from method signatures

Method signatures tell Core which inputs a `process` method accepts. They do not tell Core what a `process` method
returns; Core learns that from returned values, and then looks for `process` methods that accept them.

```
known from signatures:   read accepts SourceFile;  read with members accepts SourceDirectory
                         process accepts ItemA, ItemB, SampleGroup, SourceGroup
learned when `process` methods run:  read(SourceFile) returned ItemA or ItemB
                         read(SourceDirectory, …) returned SourceGroup or SampleGroup
                         process(SampleGroup) returned MeanSignal; process(SourceGroup) a vector
```

### 2. What Core calls, in order

With peaks 3, 6 and 7 for a_1, a_2 and a_3:

```
items(source)                .  S1  S1/a_1.csv  S1/a_2.csv  S2  S2/a_3.csv  b_1.csv
members(source, …)           . ⊃ S1, S2, b_1     S1 ⊃ a_1, a_2     S2 ⊃ a_3
read, process per file       ItemA(a_1, T 280) ─▶ ProcessedItemA(a_1, peak 3)
                             ItemA(a_2, T 280) ─▶ ProcessedItemA(a_2, peak 6)
                             ItemA(a_3, T 410) ─▶ ProcessedItemA(a_3, peak 7)
                             ItemB(b_1)        ─▶ ProcessedItemB(b_1)
read(source, S1, [a_1, a_2])     SampleGroup S1 (280) ─process─▶ MeanSignal(S1)
read(source, S2, [a_3])          SampleGroup S2 (410) ─process─▶ MeanSignal(S2)
read(source, ., [S1, S2, b_1])   SourceGroup . ─process─▶ HotGroup [S2], HighPeakGroup [a_2, a_3]
```

- Core reads each file once and passes the values to the group `read`. The element type in its
  signature says which: for a_1 the `ProcessedItemA`, for S1 the `SampleGroup`, for b_1 the
  `ProcessedItemB`. So S1 waits for a_1 and a_2 to be processed, and the root waits for S1 and S2.
- `MeanSignal(S1)` has another id, so it is not a later value of S1 and is not passed to the root.
- If a member later gets another value of the stated type, Core reads the group again, until it
  converges (see [source-groups.md](source-groups.md#member-values-core-reads-the-signature-states-the-version)).
- After each `read` and `process`, Core writes the value to its type's store and copies
  `metadata(value)` into its index. The browser can show each value as soon as it exists.

## Changes after startup

| Change | What Core calls again |
|---|---|
| `a_2.csv` edited | `read`, `process` for a_2; S1 is read again, then `MeanSignal(S1)`; the root is read again, then its `process` method |
| `metadata.txt`: S1 now 320 | `metadata(source, x)` changed for S1, a_1, a_2: all three are read again, with everything after them; `HotGroup` now contains S1 and S2 |
| `a_3.csv` deleted | a_3's values are deleted; `members(source, S2)` changed: S2 is read again, then `MeanSignal(S2)`, the root and its `process` method |
| `S3/` with `a_4.csv` added | `items` and `members` changed: a_4 and S3 are read, then the root and its `process` method; S3 has no `metadata.txt` row, so reading it fails until one is added |
| `b_1.csv` edited | `read`, `process` for b_1; b_1 is a member of the root, so the root is read again and its `process` method runs; its outputs are equal, so nothing after them runs |
| `smooth` code changed | `process` for every ItemA, then everything that contains them |

**COST:** the root contains everything, so its `process` method runs again after any change anywhere.

## Groups of groups

What the workspace contains after startup, shown by members:

```
.  (SourceGroup)
├─ S1  (SampleGroup, 280)   ─ a_1, a_2
├─ S2  (SampleGroup, 410)   ─ a_3
└─ b_1
HotGroup        ─ S2                  S2 is shown under ., HotGroup and MeanSignal(S2)
HighPeakGroup   ─ a_2, a_3            a_3 is shown under S2 and HighPeakGroup
MeanSignal(S1)  ─ S1
MeanSignal(S2)  ─ S2
```

Core keeps two relations for every value, and they differ:

| Value | Produced by | Members (`members(value)`) |
|---|---|---|
| `.` | `read(source, .)` | S1, S2, b_1 |
| `S1` | `read(source, S1)` | a_1, a_2 |
| `MeanSignal(S1)` | `process(S1)` | S1 |
| `HotGroup` | `process(.)` | S2 |
| `HighPeakGroup` | the same `process(.)` call | a_2, a_3 |

- **Members** are what a value contains. A display occurrence is a path to a value, not a copy:
  a_3 under S2 and a_3 under `HighPeakGroup` are the same value with the same id. Opening it from
  either path shows the same thing and changes nothing.
- **Produced by** is which call made the value from which input. It drives recomputation and can
  be shown as a second view ("where did this come from"). `HotGroup` is produced from the root,
  but contains only S2.
- Nothing is flattened: `HotGroup` contains S2, not a_3. Its measurements are reached through S2.

A group of results is made on the fly. The user selects `MeanSignal(S1)` and `MeanSignal(S2)` and
compares them, in the REPL or from a GUI action:

```julia
struct Comparison{V<:AbstractVector} <: AbstractGroup
    members::V
    difference::Vector{Float64}
end
members(c::Comparison) = c.members
data(c::Comparison) = c.difference

compare(selection) = Comparison(members(selection), members(selection)[1].signal .- members(selection)[2].signal)
```

`Comparison` is produced from the selection, and its members are the two mean signals, which
contain S1 and S2.

## On the fly: the plot builder

The same model covers groups created by a GUI action. Selected items whose data is a large table
(`T`, `x`, `y`), plotted as `y` against `x` with one fit per temperature bin:

```julia
bins = bin_by(selection, :T, 250:10:350)     # → vector of TempBin, each a group
fits = fit.(bins, Ref(model))                # → vector of FitResult, each a group of its bin
plot(bins; x = :x, y = :y)
plot!(fits)
```

```
selected items ──▶ Selection ──bin_by──▶ TempBin 250 ──fit──▶ FitResult 250 ─┐
                                       ├▶ TempBin 260 ──fit──▶ FitResult 260 ─┼─▶ plot
                                       └▶ …                                   ┘
```

- `Selection` is a group whose members are the selected items.
- `bin_by` is a `process` method on a group that returns a vector. Each `TempBin` has the selected items as
  members and the rows in its bin as its own data. It is produced from `Selection`; its members are
  the items, so here too the two relations differ.
- Each `fit` call is tracked. Its `FitResult` is made from a tracked input, so it is a group whose
  member is its `TempBin`, with the fitted curve as data and the parameters as metadata. The plot
  draws it and owns nothing.

Reusing the analysis: run the same code on another selection, or return it from a `process` method on one of
the project's group types so it runs for every such group:

```julia
temperature_fits(g) = fit.(bin_by(g, :T, 250:10:350), Ref(model))

# One method per signature: the sample's `process` method returns its mean signal and its fits together
process(::ToyProject, g::SampleGroup) =
    [MeanSignal(g, mean(p.signal for p in members(g) if p isa ProcessedItemA)); temperature_fits(g)]
```

`FitResult`s are values in the workspace, so other `process` methods, plots and queries use them like any
other item, and each one still leads back to its bin and the bin's items.

## Stable ids

Values produced by `process` methods need ids that stay the same across runs and restarts: `HotGroup`,
`MeanSignal`, each `TempBin`, each `FitResult`. Saved selections, later results and the browser
depend on them. Source groups already have them: `id(x)` of their source item.

Davide, 21 October: the project gives the id, by defining `id` for its type, as in
`id(::HotGroup) = "hot"` and `id(m::MeanSignal) = "mean " * id(m.sample)`. Core does not compose
ids. Recipes is a project too, so it gives ids to the values it makes.

The reviewers' earlier recommendation, superseded where it differs:

- Keep `id(value)` as the contract.
- An id is a **producer scope** plus a **logical key**. The scope identifies the `process` call,
  for example "`temperature_fits` on S1". The key identifies the output within it, for example the
  bin `250–260`, or `"hot"` above.
- A later version of the same logical value keeps its id; changed inputs or code give a new
  version, not a new id.
- Never use the position in the returned vector, the current members, computed values or the
  display parent as identity.
- Core or Recipes supplies a helper that composes the two parts; the project or a ready-made
  splitter calls it when constructing the value. Its API, and how the producer scope reaches the
  constructor, are open. In this toy, `id(::HotGroup) = "hot"` is only the logical key.
