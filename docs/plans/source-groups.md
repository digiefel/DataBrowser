# Source groups and source metadata

Proposal by the external agent, 21 October 2026, for discussion with Davide and the reviewers.
Partly built, in another form: the [Architecture](../ARCHITECTURE.md) page describes groups as
built, and is right where the two differ. `members(source, item)` gives the members of a source
item, and the `read` of a source item with members can give a group of the project's own type,
whose members are ids. There is no group `read` with member values: a group `process` method
receives them, and the workspace makes one `SourceGroup` for the whole source. `metadata(source, x)`
and `metadata.txt` are not built. Points Davide decided in conversation are marked **Davide**; the
rest is proposed.
It answers two questions for any source, not only directories:

1. How does a source say which items belong in which group?
2. How does a source give metadata to items and groups, and how does metadata that belongs to a
   group reach the items that come later?

The project argument of `read` is left out everywhere, as agreed for now. Defined in a project,
some `read` methods below are type piracy (methods on types the project does not own); the project
argument is what solves that today. Places with a known cost are marked **COST**, open points
**OPEN**.

## The source API

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
```

**Davide:** a member `process` method returns an `AbstractDataItem`, which covers groups: a later version of
the member (same id) or a new value, for example a group that keeps both inputs. Core records both inputs either way.

- `items` returns every source item: files, directories, records, playlists, and so on.
- `members(source, group)` is defined only for source items that are groups; it returns the source
  items that `group` contains. Membership is stated between source items, so the source knows it
  before anything is read.
- `metadata(source, x)` is what the source itself knows about `x`. It is complete for `x`: if a
  source wants a file to have its directory's metadata, its `metadata` method includes it. Core
  does not combine metadata.
- `read` with two arguments makes an item. With three, it makes a group from its members' values.
- Membership is many-to-many: one source item can be in several groups. A group can contain
  groups. A source without groups of groups is flat. A source that lists a group inside itself,
  directly or through other groups, has a bug; Core reports it as an error on those groups.
- A source item is a group source item when `members(source, x)` has a method for it.
  **OPEN:** an explicit `AbstractDataSourceGroup <: AbstractDataSourceItem` instead, so that
  signatures say "group" by type.

## Member values: Core reads, the signature states the version

**Davide:** the group's `read` does not read its members. Core reads every source item once, as it
does anyway, and passes those values to the group's `read`. A file in two groups is read once and
passed to both.

The element type `T` of `members` states which values the group needs. Core passes, for each
member, its latest value whose type matches `T`. A source item whose `read` returns several items
contributes all of them that match:

```julia
read(::Source, g::SourceItem, ms::AbstractVector{Item})            # the values read from files
read(::Source, g::SourceItem, ms::AbstractVector{ProcessedItem})   # the values after processing
read(::Source, g::SourceItem, ms::AbstractVector{Union{Group, ProcessedItemB}})   # several kinds
```

- Core knows `T` from the signature before calling, so it knows what the group waits for.
- A member that never gets a value of type `T` is left out. Core knows that once the member's
  chain has finished.
- So two relations exist and both stay visible. Source browsing follows `members(source, g)`: a
  sample with a spectrum and an image shows both. A group value's `members(g)` lists the values it
  was read with, which may be only the spectrum.
- **Davide:** when a member gets a later value that also matches `T`, for example from a member
  `process` method, Core reads the group again. Each reading makes a new group value; an earlier group value's
  members never change. The convergence rule ends this as for any chain: Core stops
  when a value is `isequal` to its input, and halts with an error after the maximum number of
  rounds.
- Core records, for each group value, the member versions it was read with.
- `read(source, g, members)` is an ordinary call: it works with any vector, outside a workspace.

The same rule holds for `process` methods on groups. Davide, 21 October: a `process` method on a group can state the member values it needs as a
third argument, as group `read` does. Core passes, for each member, its latest value of type `T`,
and leaves out members that have none. A later member value of type `T` causes the method to be
called again, with the same convergence rule. `members(group)` is unchanged: it still returns
the values the group was made with.
The workspace implements this as `process(project, group, members::AbstractVector{T})`.

Core supplies a fallback for groups, so a source or project only writes `read` for a group type
it wants to own. Its element type accepts any value, so it holds each member's latest value:

```julia
# In Core
struct SourceGroup{V<:AbstractVector} <: AbstractGroup
    id::String
    metadata::Dict{Symbol,Any}
    members::V
end
id(g::SourceGroup) = g.id
metadata(g::SourceGroup) = g.metadata
members(g::SourceGroup) = g.members

read(source::AbstractDataSource, x::AbstractDataSourceItem, members::AbstractVector{AbstractDataItem}) =
    SourceGroup(id(x), metadata(source, x), members)
```

## How Core uses it

At startup and after every rescan:

```
items(source)                      every source item
members(source, g)                 for each group source item: the membership relation
read(source, x)                    for each source item that is not a group: an item, once
  └─ process, until converged
read(source, g, members::T)        for each group, as soon as its members have values of type T;
  └─ process, until converged        again whenever a member gets a later value of type T
```

A group that contains a group waits for that group's value, if `T` asks for it.

After a rescan, Core compares the new results with the last ones:

| Change | What Core does |
|---|---|
| a source item is added or removed | reads it or deletes its values; reads its groups again |
| `members(source, g)` changed | reads `g` again |
| `metadata(source, x)` changed | reads `x` again, because its value copied that metadata |
| a source file changed (fingerprint) | reads it again |

**COST:** Core calls `members` and `metadata` for every source item on every rescan, to find
changes. A source that can report what changed could skip that. TODO: an API for it, later; a
full rescan is enough for now (Davide, 21 October).

## DirectorySource

Directories become group source items. `metadata.txt` is removed from DirectorySource; see the
next section for where it goes.

```julia
struct SourceDirectory <: AbstractDataSourceItem
    relative_path::String                         # "." for the root
end
id(d::SourceDirectory) = d.relative_path

# DirectorySource gains one field, filled by each scan:
#     contents::Dict{String,Vector{AbstractDataSourceItem}}   relative path → what it contains

function items(s::DirectorySource)
    empty!(s.contents)
    found = AbstractDataSourceItem[]
    for (dir, subdirs, files) in walkdir(s.root_path)
        here = relpath(dir, s.root_path)
        directories = s.recursive ? SourceDirectory.(normpath.(joinpath.(here, subdirs))) : SourceDirectory[]
        sourcefiles = [index_source_file(joinpath(dir, f), s.root_path) for f in files]   # a SourceFile each
        s.contents[here] = [directories; sourcefiles]
        push!(found, SourceDirectory(here))
        append!(found, sourcefiles)
        s.recursive || break                       # without recursion: the root only
    end
    return found
end

members(s::DirectorySource, d::SourceDirectory) = s.contents[id(d)]

metadata(s::DirectorySource, f::SourceFile) = metadata(f)          # the filename
metadata(s::DirectorySource, d::SourceDirectory) = Dict(:directory => basename(id(d)))
```

Compared with the DirectorySource of 21 October:

- `collection(file)` and `DirectoryCollection` are removed; the code no longer has them. `DirectoryCollection` used the
  directory name as its id, so two `data/` directories at different depths shared an id;
  `SourceDirectory` uses the relative path.
- `metadata(source, collections)`, `own_collection_metadata` and the `metadata.txt` parsing leave
  DirectorySource.
- Directories need no `read` method: Core's fallback makes a `SourceGroup` for each.
- The watcher is unchanged: it triggers a rescan, and Core finds changes as in the table above.

## `metadata.txt` outside DirectorySource

`metadata.txt` becomes one implementation of `metadata(source, x)`, in a source that wraps
DirectorySource. It could live in Recipes or in the RuO2 project. The matching rules stay those of
the `own_collection_metadata` that DirectorySource had on 21 October, which moves here unchanged.
DirectorySource no longer reads `metadata.txt`, and nothing else reads it yet.

```julia
mutable struct AnnotatedDirectorySource <: AbstractDataSource
    directory::DirectorySource
    entries::Dict{Tuple{Vararg{String}},Dict{Symbol,Any}}    # the parsed metadata.txt
end
AnnotatedDirectorySource(root) = AnnotatedDirectorySource(DirectorySource(root), Dict())

# Each scan reads metadata.txt again, so an edit reaches metadata(source, x) on the next rescan.
# metadata.txt is not a measurement: leave it out of the source items.
function items(s::AnnotatedDirectorySource)
    path = joinpath(s.directory.root_path, "metadata.txt")
    s.entries = isfile(path) ? load_collection_metadata_entries(path) : Dict()
    return filter(x -> id(x) != "metadata.txt", items(s.directory))
end

# Changes are DirectorySource's: its watcher triggers the rescan, which includes metadata.txt
watch_source(s::AnnotatedDirectorySource, args...; kwargs...) = watch_source(s.directory, args...; kwargs...)
members(s::AnnotatedDirectorySource, d::SourceDirectory) =
    filter(x -> id(x) != "metadata.txt", members(s.directory, d))

# A source item gets the entries of every directory that contains it, outermost first
function metadata(s::AnnotatedDirectorySource, x)
    path = x isa SourceDirectory ? id(x) : dirname(id(x))
    levels = path in (".", "") ? String[] : splitpath(path)          # "S1/x" → ["S1", "x"]
    inherited = Dict{Symbol,Any}()
    for depth in eachindex(levels)
        merge!(inherited, own_collection_metadata(s.entries, levels[1:depth]))
    end
    return merge(inherited, metadata(s.directory, x))
end
```

**COST:** a change to `metadata.txt` changes `metadata(source, x)` for every source item below the
changed rows, so Core reads all of them again. On 21 October, only the metadata index was
rewritten.

## How group metadata reaches later items

There are two kinds of metadata that belong to a group. They reach items in different ways.

| Kind | Known | How it reaches an item |
|---|---|---|
| source metadata | when the source is scanned, without project code | `read` copies it from `metadata(source, x)` into the value |
| data metadata | only after project code reads some data | a member `process` method: `process(project, member, group)` |

Both are shown on the same data. A sample is a directory; its temperature belongs to the sample.

### Case 1: temperature as source metadata (`metadata.txt`)

```
data/
├─ metadata.txt          path,temperature
│                        S1,350
│                        S2,410
├─ S1/
│  ├─ a_1.csv            one signal value per line
│  └─ a_2.csv
└─ S2/
   └─ a_3.csv
```

```julia
using DataBrowser

struct ToyProject <: AbstractProject end
source = AnnotatedDirectorySource("data")

struct ItemA <: AbstractDataItem
    id::String
    temperature::Float64
    signal::Vector{Float64}
end
id(a::ItemA) = a.id
data(a::ItemA) = a.signal
metadata(a::ItemA) = Dict(:temperature => a.temperature)

# metadata(s, f) already holds the temperature of the file's directory
read(s::AnnotatedDirectorySource, f::SourceFile) =
    ItemA(id(f), metadata(s, f)[:temperature], parse.(Float64, readlines(f.filepath)))

struct ProcessedItemA <: AbstractDataItem
    id::String
    temperature::Float64
    signal::Vector{Float64}
    peak::Float64
end
id(p::ProcessedItemA) = p.id
data(p::ProcessedItemA) = p.signal
metadata(p::ProcessedItemA) = Dict(:temperature => p.temperature, :peak => p.peak)

function process(::ToyProject, a::ItemA)
    smoothed = smooth(a.signal)                    # an ordinary project helper
    return ProcessedItemA(a.id, a.temperature, smoothed, maximum(smoothed))
end

# Samples above 300: a `process` method on the root directory, whose members are the sample directories
struct HotGroup{V<:AbstractVector} <: AbstractGroup
    members::V
end
members(g::HotGroup) = g.members
id(g::HotGroup) = "hot"

process(::ToyProject, g::SourceGroup) =
    id(g) == "." ? HotGroup(filter(m -> m isa SourceGroup && metadata(m)[:temperature] > 300, members(g))) :
                   AbstractDataItem[]              # other directories: no output
```

What Core calls:

```
items(source)              .  S1  S1/a_1.csv  S1/a_2.csv  S2  S2/a_3.csv
members(source, …)         . ⊃ S1, S2      S1 ⊃ a_1, a_2      S2 ⊃ a_3
metadata(source, a_1)      (filename, temperature = 350)
read(source, a_1)          ItemA(T = 350) ──process──▶ ProcessedItemA(T = 350)    a_2, a_3 alike
read(source, S1, [ItemA a_1, ItemA a_2])      SourceGroup S1 (temperature = 350)   S2 alike
read(source, S1, [P a_1, P a_2])              again: the ProcessedItemA values are later
                                              values that the fallback's type accepts
read(source, ., [S1, S2])          SourceGroup .
process(.)                         HotGroup [S1, S2]
process(S1), process(S2)           no output
```

**COST:** Core's fallback accepts any value, so it is read again at each version of each member. A
project that cares states a narrower type in its own group `read`, as in case 2.

**COST:** Core's `SourceGroup` is one type for every directory, so a `process` method cannot dispatch on
"root" or "sample". The `process` method above tests `id(g) == "."` and returns an empty vector for the
others. A project that wants dispatch reads its directories into its own group type, as in case 2.

**COST:** every item type copies `temperature` explicitly: `read` into `ItemA`, `process` into
`ProcessedItemA`. This is the price of self-contained values. Recipes can do the copying for its
own item types.

### Case 2: temperature as data metadata (a file in the sample)

```
data/
├─ S1/
│  ├─ sample.toml        temperature = 350
│  ├─ a_1.csv
│  └─ a_2.csv
└─ S2/
   ├─ sample.toml        temperature = 410
   └─ a_3.csv
```

The source is plain `DirectorySource("data")`. `ItemA`, `ProcessedItemA` and `process(::ItemA)`
are as in case 1, except that the temperature of `ItemA` is `Union{Missing,Float64}`: the
measurement file does not contain it.

```julia
using TOML

struct SampleInfo <: AbstractDataItem
    id::String
    temperature::Float64
end
id(i::SampleInfo) = i.id

read(s::DirectorySource, f::SourceFile) =
    basename(id(f)) == "sample.toml" ?
        SampleInfo(id(f), TOML.parsefile(f.filepath)["temperature"]) :
        ItemA(id(f), missing, parse.(Float64, readlines(f.filepath)))

# A directory with a sample.toml is a sample. It needs the values read from files, not later ones.
struct SampleGroup{V<:AbstractVector} <: AbstractGroup
    id::String
    temperature::Float64
    members::V
end
id(g::SampleGroup) = g.id
members(g::SampleGroup) = g.members
metadata(g::SampleGroup) = Dict(:temperature => g.temperature)

function read(s::DirectorySource, d::SourceDirectory, members::AbstractVector{Union{SampleInfo,ItemA}})
    infos = filter(m -> m isa SampleInfo, members)
    isempty(infos) && return SourceGroup(id(d), metadata(s, d), members)   # not a sample
    return SampleGroup(id(d), only(infos).temperature, members)
end

# Member `process` method: a sample gives its temperature to each of its measurements, before processing
process(::ToyProject, a::ItemA, g::SampleGroup) = ItemA(a.id, g.temperature, a.signal)

# Samples above 300: dispatch now tells samples apart
process(::ToyProject, g::SourceGroup) =
    HotGroup(filter(m -> m isa SampleGroup && m.temperature > 300, members(g)))
```

What Core calls, for S1:

```
read a_1, a_2           ItemA(T missing)                    sample.toml: SampleInfo(350)
read S1 with [SampleInfo, ItemA a_1, ItemA a_2]  →  SampleGroup(350)
member `process` method             ItemA(T = 350) for a_1, a_2         same id, same type: a later value
read S1 again           with the later ItemA values  →  SampleGroup(350)
member `process` method             ItemA(T = 350), equal to its input  →  converged
process                 ItemA(T = 350) ─▶ ProcessedItemA(T = 350)
```

Because `SampleGroup` states `ItemA`, the temperature reaches each measurement before
`process(::ItemA)` uses it.

**COST:** `process(::ItemA)` also runs on the first `ItemA`, whose temperature is `missing`, and
again on the later one. The result is correct; the first run is wasted work.

**COST:** each member `process` method that returns a later value of the type the group states causes one
more round: the group is read again with the later member values. A member `process` method that returns a
new type causes none.

## Open points

- **OPEN, parked by Davide on 21 October: an explicit source group type.** `AbstractDataSourceGroup`
  would make signatures say "group" by type; the current proposal recognizes a group by its
  `members` method. A source that uses one type for both records and groups is misimplemented and
  should use two types, so `members` returning `nothing` (PM's suggestion) is not needed.
- Groups not from the source. A selection is a group made from the items the user clicked, for
  example in the tree view; it is the input of visualizers. It has no place of its own in the tree.
- **Later: a source that reports changes.** Davide, 21 October: scanning everything again is
  enough for now. An instrument stream or a database knows what changed, so an API for it may come
  later.
- Stable ids for produced groups such as `HotGroup`: the project defines `id` for its type (Davide,
  21 October); see [groups-toy.md](groups-toy.md#stable-ids).
