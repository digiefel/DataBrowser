# DataBrowser Architecture

This page describes how DataBrowser works today. The direction of the project is in
`docs/vision.md`, and the proposals for its next steps are in `docs/plans/README.md`.

## What DataBrowser does

DataBrowser is a Julia environment for scientific data. It does what a person otherwise does by
hand in a REPL: find the files or records of the data, load them, extract tables, compute values,
and write the code of figures. In the browser you open a project, select measurements, and change
the plots and tables that show them, without reading the same data again.

Project code describes the project as a script would: which measurements the data holds, how to
load them, and how to show them. The packages of DataBrowser scan the source, keep the cache,
run the background jobs, and keep the state of the browser. A workspace stays open while source
items are added or changed, and its windows update without a reload.

## Package map

A solid arrow from A to B means that A depends on B: A needs B to build. An arrow to a box around
several packages points to each package in the box. A dotted arrow from A to B means that A calls
functions whose methods B defines, although A does not depend on B. An arrow labeled with an
extension of A, such as DataBrowserPlotsGUIExt, means that the extension depends on B: Julia loads
it when B is loaded too. The other labels name functions and types that A uses from B; `@timed_dbg`
marks the code that DataBrowserProfiling times. 🦆 marks DuckDB, 📈 GLMakie, 🖼 CImGui / GLFW.

```mermaid
flowchart TB
    db["<b>DataBrowser</b><br/>install target<br/>re-exports the public API"]
    prof["<b>DataBrowserProfiling</b><br/>internal tooling"]
    fitting["<b>DataBrowserFitting</b><br/>least-squares solver of fit<br/>loads on the first fit"]

    subgraph projects["Project code"]
        recipes["<b>DataBrowserRecipes</b><br/>user-friendly register_*! API"]
        userpkg["⋯<br/>any user-authored<br/>project package"]
    end

    subgraph frontend["Frontend"]
        gui["<b>DataBrowserGUI</b> 🖼<br/>main GUI functionality"]
        plots["<b>DataBrowserPlots</b> 📈<br/>plot registration; plot windows<br/>load with GLMakie"]
    end

    subgraph engine["Engine"]
        core["<b>DataBrowserCore</b><br/>workspace, job scheduling, coordination"]
        src["<b>DataBrowserSources</b><br/>DirectorySource, ..."]
        cache["<b>DataBrowserCache</b> 🦆<br/>Caching and persistence"]
        ann["<b>DataBrowserAnnotations</b><br/>tags, notes, layout"]
    end

    subgraph contracts["Contracts"]
        api["<b>DataBrowserAPI</b><br/>project, source, item, group,<br/>store and visualizer interfaces"]
    end

    db --> recipes
    db --> frontend
    db --> engine
    db --> fitting
    db --> contracts
    gui -->|"open_workspace<br/>modify_workspace!<br/>select!<br/>select<br/>materialize_items<br/>workspace_status"| core
    gui --> cache
    gui --> api
    plots -->|"DataBrowserPlotsGUIExt:<br/>ItemTable<br/>merge_item_tables"| gui
    plots -->|"materialize_items"| core
    plots --> fitting
    plots --> api
    core --> src
    core --> cache
    core --> ann
    core --> api
    src --> api
    cache --> api
    recipes --> src
    recipes --> cache
    recipes --> api
    userpkg --> api
    prof --> api

    core -.->|"read<br/>process"| projects
    gui -.->|"draw!<br/>menu!<br/>init!"| plots
    cache -.->|"@timed_dbg"| prof
    core -.->|"@timed_dbg"| prof
    gui -.->|"@timed_dbg"| prof
    plots -.->|"@timed_dbg"| prof
    recipes -.->|"@timed_dbg"| prof

    classDef umbrellaC fill:#f7c9b8,stroke:#b5623f,color:#2b2b2b
    classDef plotsC fill:#f2c6d4,stroke:#b0466a,color:#2b2b2b
    classDef guiC fill:#d9c6ec,stroke:#7d54b0,color:#2b2b2b
    classDef coreC fill:#bcd4f0,stroke:#3f6fb0,color:#2b2b2b
    classDef recipesC fill:#f5ecc0,stroke:#b09a3f,color:#2b2b2b
    classDef srcC fill:#c9e4c5,stroke:#5a9a52,color:#2b2b2b
    classDef cacheC fill:#f5d6a8,stroke:#c08a3f,color:#2b2b2b
    classDef annC fill:#b8e0d2,stroke:#4f9a86,color:#2b2b2b
    classDef profC fill:#ded7ef,stroke:#8a7fb0,color:#2b2b2b
    classDef apiC fill:#cfd8e3,stroke:#5a6b80,color:#1e1e1e
    classDef ghostC fill:#f2f2f2,stroke:#9aa0a6,stroke-dasharray:5 4,color:#5f6368

    class userpkg ghostC
    class db umbrellaC
    class plots plotsC
    class fitting plotsC
    class gui guiC
    class core coreC
    class recipes recipesC
    class src srcC
    class cache cacheC
    class ann annC
    class prof profC
    class api apiC
```

## The workspace

A *workspace* is one opening of a project. It reads one source, such as a folder of files, a
database or an instrument, which lists *source items*, such as files or the tables of a database.
The project, a value of a subtype of `AbstractProject`, says in Julia how to read each source item
and how to process the items that reading gives. The workspace calls these functions, keeps their
results, and calls them again when the source or the code changes. The browser shows a workspace in
windows, and a script opens a workspace from the REPL:

```text
                                     windows of the browser and scripts
                                         │ ask for items and their results
                                         ▼
    the source ── source items ──▶ the workspace, with its catalog ─ reads, writes ─▶ the cache
                                         │       ▲                                    and the stores
                          function calls │       │ results                            of the project
                                         ▼       │
                                   the project: read and process
```

### Items and groups

An *item* is one value of the project, such as one measurement: a value of a type that the project
defines as a subtype of `AbstractDataItem`, with an *id*, a label, data and metadata. The id is a
string that the project chooses and that stays the same from one session to the next. A *group* is
an item with *members*, of a subtype of `AbstractGroup`: `members(g)` gives the ids of the members
of the group `g`. When a member id names a source item, the member stands for the items that the
source item gives. The `read` of a source item that holds other source items, such as a sample that
holds its measurements, can give a group of a type of the project, whose members are those source
items. Besides, the workspace makes one `SourceGroup` for the whole source, whose members are all
its source items.

The project defines these methods, which the [API](api.md) page describes:

| Function call | Gives |
| --- | --- |
| `read(project, source, s)` | the item of the source item `s`, or a group of the source items in `s` |
| `process(project, x)` | an item or a vector of items made from the item `x` |
| `process(project, g, members)` | items made from the group `g` and the vector `members` of the items of its members, such as a fit through all of them |
| `process(project, x, g)` | items made from the member `x` with its group `g` |

None of them has a default: the workspace makes a function call only when a method of the project
takes its arguments. It makes these calls for every item that a call gives, so a chain of calls
ends at an item that no method takes. A method that returns the type that it takes runs again on
its result, as a loop, and the chain ends when the result is `isequal` to the item that the call
took.

The workspace keeps each function call in a row of its *catalog*, a table with one row for each
*computation*, a function call before it runs. The rows whose results a row takes are its *inputs*.
As an example, a source has the source items `a` and `b`, and a source item `g` with the members `a`
and `b`. Its project has the methods `read`, which gives an `Item` for `a` and `b` and a `Group`
for `g`; `process(project, x::Item)`, which gives a `ProcessedItem`; `process(project, g::Group,
members::Vector{ProcessedItem})`; and `process(project, x::ProcessedItem, g::Group)`, which gives
an item of a fourth type. When the workspace was opened with `background_processing=true`, which
runs every row, the catalog has these rows:

```text
    row  function call                      kind             inputs   gives
    1    read(project, source, a)           read                      a, an Item
    2    process(project, a)                process          1        a later version of a
    3    read(project, source, b)           read                      b, an Item
    4    process(project, b)                process          3        a later version of b
    5    read(project, source, g)           read                      g, a Group with members a and b
    6    process(project, g, [a, b])        group process    5, 2, 4  fit, a new item
    7    process(project, a, g)             member process   2, 5     a later version of a
    8    process(project, b, g)             member process   4, 5     a later version of b
    9    SourceGroup(source, [a, b, g])     read                      the source group

    Each item has the id of its source item. [a, b] is the items of the members a and b.
```

The workspace adds a read row when the source lists a source item, and a `process` row when the item
that it takes exists. A row runs after its inputs: row 2 calls `process` with the item that row 1
gives. A row that takes an item and gives an item with the same id gives a later *version* of it:
rows 1, 2 and 7 give three versions of `a`. Windows show the *latest version* of each item, the one
at the end of the longest chain of calls: here `a` from row 7, `b` from row 8, `g` from row 5, and
`fit` from row 6, a new item. A call takes the other items that it needs at their latest version
that does not come from its own result. So the group process takes, for each member, its latest
version of the type that its method takes: here from rows 2 and 4, since rows 7 and 8 give another
type. `background_processing` is off by default: the workspace adds every row, runs the
reads, and runs a `process` row only when a window shows its item or a script asks for it. A group
process then takes, for each member, the latest version of that type among those that have a
result or will run.

### Keys and revisions

The *cache* is a DuckDB file that DataBrowser keeps for each project in the Julia depot. It gives
each row a *key*, a number, and keeps it under the *id of the computation* of the row: the name of
its function and the ids of its arguments, such as `process(myproject, a)` for a project named
`myproject`. So the same computation gets the same key in the next session, and the catalog puts
the row at the position of its key. A `process` can give several items, so the cache also gives
each item that a row of the project gives a key of its own, from the same counter. Under these
keys the cache keeps what the next session needs to know.

A *store* keeps the results. It keeps each result under its *revision*, a hash that identifies the
result (see "When a row runs"), and each item that a row of the project gives under a revision of
its own: a hash of its id and the revision of the result of the row. The same revision means the
same result, in any workspace and in any session, so several workspaces can share a store, and a
store can keep its results from one session to the next:

```text
    part                    under                  what it holds, for row 2: process(project, a)
    catalog, in memory      key 2                  the computation, its state, its inputs and the
                                                   rows that have it as an input, and its priority
    cache, a DuckDB file    key 2                  the record of the row: the id of the
                                                   computation, the revision of its result or its
                                                   error, and the items it gives
                            key 12                 the item a that row 2 gives: its id, label, type
                                                   and metadata
    store of its type       the revision of a      the item a
```

The row of a computation that a script or a window evaluates gives one result, which its store
keeps under the revision of the result. When a row gets a result with another revision, its last
result leaves the store. `storage(project, T)` chooses the store for results of type `T`:

| Part | Where it is | After Julia exits |
| --- | --- | --- |
| the cache | a DuckDB file for each project in the Julia depot; in memory with `open_workspace(...; cache=false)` | kept, unless `cache=false` |
| a `MemoryStore`, the default store | the memory of Julia | lost: the rows run again when something needs their results |
| a `DuckDBStore`, the store of a project made with DataBrowserRecipes | the file `values.duckdb` in the folder of the Julia environment, which all such projects of the environment share | kept |

### When a row runs

A row is *missing* until it first runs. It is then *current*, with a result, or *failed*, with the
error that its function threw. A failure is a result of the code and the inputs, as a value is: a
failed row runs again only when it becomes *stale*. A row becomes stale when the code of its
function changes, when one of its inputs becomes stale, or when a source item that it reads
changes:

```text
    missing ──┐                    ┌──▶ current ──┐
              ├── a worker runs it ┤              │
    stale ────┘                    └──▶ failed ───┤
      ▲                                           │
      └── its code, an input or its source item changes

    A worker that runs a row calls its function only when the cache did not save its revision.
```

The workspace *wants* every read row, and with `background_processing=true` every other row, so
that it runs in the background. A window or a script *requests* the rows that it needs, which run
before the wanted rows. Worker tasks, one for each Julia thread and at least two, run the rows that
are missing or stale, and wanted or requested. The *revision of a result* is a hash that
identifies the result: the same revision means the same result, even in another session. Before a
row runs, the workspace computes the *revision of the row*, which its result gets:

```text
    the revision of the row, a hash of:
        the code revision of its function   a hash of the code that the function can reach
        the revisions of the results of its inputs
        its other arguments                 such as a source item, with its fingerprint
        its settings                        the keyword arguments of its computation
        │
        ▼
    did the cache save this revision? ── yes ─▶ current, or failed with the saved error,
        │ no                                     without calling the function
        ▼
    call the function ── throws ─▶ failed: the cache saves the error with the revision
        │ returns
        ▼
    current: the result gets the revision of the row, or the revision of the last result when the
    two results are isequal, and the cache saves it
```

When the source item `a` is saved again with the same content, row 1 becomes stale, because the
*fingerprint* of `a`, a value that changes when a source item may have changed, such as the size
and modification time of a file, changed. Rows 2, 6 and 7 have row 1 among their inputs, directly
or through other rows, and become stale too. Row 1 runs again and gives an item `isequal` to the
last one, so its result keeps the revision of the last result. Rows 2, 6 and 7 then compute the
revisions that they last ran with, which the cache saved: they become current without calling their
functions, and only `read` ran. An edit of a function that still returns `isequal` results ends the
same way.

When a workspace opens again, each row computes its revision in the same way. A row whose revision
the cache saved is current or failed without running. It takes its result from its store when
something needs it, and runs again when the store lost the result, as a `MemoryStore` does when
Julia exits. A read row whose source item has the same fingerprint is current without calling
`read`. To run failed rows again without a change, open the workspace with `rebuild=true`, which
empties its cache, so that every row calls its function again.

The cache also saves the *item revision* of each row: the code revision of the `label`, `id`,
`members` and `metadata` methods of the types of the items that the row gives. When only the item
revision changed, as after an edit of a `label` method, the row takes its items from their stores,
without calling its function, and computes their labels, ids, members and metadata again. A row
whose store lost one of these items calls its function.

These pages of DataBrowserCore give the details:

| Page | What it explains |
| --- | --- |
| [`Catalogs.jl`](code/lib/DataBrowserCore/src/Catalogs.md) | rows, their states, and the rules that decide what runs and what stays |
| [`Pipeline.jl`](code/lib/DataBrowserCore/src/Workspace/Pipeline.md) | the rows of the project's function calls, the versions of each item, groups and their members, and when rows are added |
| [`Evaluate.jl`](code/lib/DataBrowserCore/src/Workspace/Evaluate.md) | how rows run, the ids of computations and the revisions of results, where results are kept, code changes |
| [`CodeRevisions.jl`](code/lib/DataBrowserCore/src/CodeRevisions.md) | the code revision of a function: what it follows and what it cannot see |

### How windows and scripts read the workspace

The workers run project code without a lock. To change the catalog, before and after a row runs,
they take the *lock of the catalog*, which lets one task at a time change it. Windows and scripts
read the workspace without that lock, so a frame of the browser never waits for a worker. Instead,
they read two snapshots that the workspace *publishes*: it replaces each of them whole and never
changes a published one, so a reader needs no lock.

- The *table `items`*, with one row for each item, groups included: its id, label, type, readiness,
  groups and metadata, and where its latest version is kept. A background task of the workspace,
  the *publishing task*, makes a new version of the table from the catalog when items change: at
  once while a window or a script waits for an item, or when no work is left, and otherwise at most
  every 0.05 s. It also adds to the catalog the rows of the new computations that `evaluate` gets.
- The *shared state*: the selection of the workspace, its tags and the order of its items.
  `select!`, `tag!`, `untag!` and `sort!` replace it whole, one at a time, and `tag!` saves the tags
  in `tags.txt` before the new state replaces the old one. Every window and script sees the same
  shared state: a script that selects items selects them in the browser too.

```mermaid
flowchart LR
    workers["the workers:<br/>read and process"]
    catalog["the catalog"]
    task["the publishing task"]
    subgraph published["published, read without a lock"]
        table["the latest version<br/>of the table items"]
        shared["the shared state:<br/>selection, tags, order"]
    end
    clients["windows and scripts"]
    workers -- "results, under<br/>the lock of the catalog" --> catalog
    catalog -- "the rows that changed" --> task
    task -- "publishes" --> table
    clients -- "evaluate" --> task
    task -- "adds their rows" --> catalog
    clients -- "select!, tag!, sort!:<br/>replace it" --> shared
    published -- "read" --> clients
```

Each publish of the table or of the shared state takes the next number of a counter of the
workspace, its *generation*. `select(workspace, f)` gives the items whose row passes the function
`f`, such as the items with a tag. Another background task keeps its answers: it runs `f` on the
rows of the items that changed since its last pass, outside the lock of the catalog, and marks each
answer with the generation that it shows. `select(workspace, f)` returns an answer only when it
shows the latest generation at the time of the call, so a script reads its own change right after
it makes it:

```mermaid
sequenceDiagram
    participant C as a script
    participant S as the shared state
    participant A as the answers of select
    C->>S: tag!(workspace, ids, "check")
    Note over S: replaced whole,<br/>generation 413
    S-->>C: tag! returns
    C->>A: select(workspace, row -> "check" in row.tags)
    Note over A: the answer for generation 413,<br/>from the rows whose tags changed
    A-->>C: the items with the tag
```

`select(workspace, ids)`, `evaluate` and `wait_workspace_idle!` wait for work. The first two wait
until the items or the result that they ask for are computed, which run ahead of background work;
`wait_workspace_idle!` waits until no scan and no job is left. Each call waits in its own task for
a version of the table that shows what it waits for, so many calls can wait at once.

The browser draws each frame from the latest version of the table and from the shared state. It
builds its tree in a background task from answers of `select(workspace, f)`, such as the items
that no group holds, and builds it again when one of those answers changes. Also, when
`modify_workspace!` rebuilds the workspace, it replaces its catalog and its table together, so a
frame never sees one without the other.

One read takes the lock of the catalog: the result of a row that its store lacks, which the caller
computes again in its own task. The caller takes the lock for a moment, to read the row and its
inputs, and runs the code of the row without the lock. A `MemoryStore` lacks every result
after Julia restarts. Besides, two kinds of rows never keep their result in a store: the rows that
take a part of an item, such as the rows of a table that a person selects in a window, and the rows
that take one item out of the items that a `process` call gives.

| Page | What it explains |
| --- | --- |
| [`Items.jl`](code/lib/DataBrowserCore/src/Workspace/Items.md) | the publishing task, the task that answers `select(workspace, f)`, and the reads by id |
| [`Selection.jl`](code/lib/DataBrowserCore/src/Workspace/Selection.md) | `select`, the `Selection` that it gives, and the data of its items |
| [`Operations.jl`](code/lib/DataBrowserCore/src/Workspace/Operations.md) | opening, rebuilding and closing a workspace, `select!` and the shared state |

<!-- TODO: move the sections below into the code that they describe (Items.jl, Calls.jl). -->

### Other computations

Scripts and windows also compute what no `process` of the project describes, because a person
chooses their inputs, such as the items that a plot fits. `evaluate(workspace, c)` gives the result
of a computation `c = Computation(f, args...; settings...)`: the workspace adds its row to the
catalog, runs it ahead of background work, waits for its result, and keeps the row until the
workspace closes. In the next session, the same computation gets the same key, and its result comes
from its store when the store kept it. An item of the workspace among its arguments stands for the
row of its latest version, so the next `evaluate` of the computation runs it again after the item
changed. Windows evaluate computations this way when they prepare their data in a background task.
`computation(workspace, id)` gives the computation of the latest version of an item, and
`inputs(c)` the computations among the arguments of `c`. Neither loads a result nor runs project
code.

### The code view

The *code view*, a window of the browser, shows the computations of the selected items as function
calls, in the order they ran: the `read` of their source items first, then each `process`. Items
that went through the same code share a call. The computations of the call that you select are the
output of the window: another window can take them as its input and show their results.

## Subpackages

<!-- TODO: diagrams for the other packages. -->

Each package of this section has two diagrams. A class diagram shows its data model: the structs,
their fields, and how they subtype the API abstractions and compose. The call flow diagram shows
which functions call which as arrows, with A -data-> B meaning "A calls B, which returns `data`".

A solid arrow is a call, labelled with the value the callee returns, or for an external library,
with the function that it calls. External calls from other packages are shown as thicker arrows.
"hot path" calls which are very frequent and performance-critical are shown in red.
A dashed arrow is a value that a function passes to another package through a function that the
other package gave it, as the watcher passes the changes of the source to DataBrowserCore.

A thick border marks a symbol the package exports.
`X_or_Nothing` means a field may contain either `X` or `nothing`.

### DataBrowserSources

DataBrowserSources gives `DirectorySource`, a source that lists the files of a folder as
`SourceFile`s and its folders as `SourceDirectory`s, and watches the folder for changes. A
`SourceDirectory` has members, so its `read` gives a group. The `FileFingerprint` of a file, its
size and modification time, is its fingerprint. DataBrowserSources adds methods to functions of
DataBrowserAPI, such as `id` and `label` of a `SourceFile`: DataBrowserCache, DataBrowserGUI and
DataBrowserPlots call them through DataBrowserAPI, without depending on DataBrowserSources.

#### Data model

```mermaid
%%{init: {'theme':'base','themeVariables':{'textColor':'#111','lineColor':'#555'}}}%%
classDiagram
    direction TB
    class AbstractDataSource
    class AbstractDataSourceItem

    class DirectorySource {
        String root_path
        Bool recursive
        Task_or_Nothing watcher_task
        CancellationTokenSource_or_Nothing watcher_cancel
    }
    class SourceFile {
        String filepath
        String filename
        String relative_path
        FileFingerprint fingerprint
    }
    class FileFingerprint {
        String path
        Int64 size_bytes
        Int64 mtime_ns
    }
    class SourceDirectory {
        String path
        String relative_path
        Vector~AbstractDataSourceItem~ members
    }

    AbstractDataSource <|-- DirectorySource
    AbstractDataSourceItem <|-- SourceFile
    AbstractDataSourceItem <|-- SourceDirectory
    DirectorySource --> SourceFile : scans
    DirectorySource --> SourceDirectory : scans
    SourceFile *-- FileFingerprint : fingerprint
    SourceDirectory o-- AbstractDataSourceItem : members

    style AbstractDataSource fill:#cfd8e3,stroke:#5a6b80,stroke-width:1px,color:#111
    style AbstractDataSourceItem fill:#cfd8e3,stroke:#5a6b80,stroke-width:1px,color:#111
    style DirectorySource fill:#c9e4c5,stroke:#5a9a52,stroke-width:3px,color:#111
    style SourceFile fill:#c9e4c5,stroke:#5a9a52,stroke-width:3px,color:#111
    style FileFingerprint fill:#c9e4c5,stroke:#5a9a52,stroke-width:3px,color:#111
    style SourceDirectory fill:#c9e4c5,stroke:#5a9a52,stroke-width:3px,color:#111
```

#### Call flow

```mermaid
%%{init: {'theme':'base','themeVariables':{'textColor':'#111','lineColor':'#555'}}}%%
flowchart TD
    subgraph sgScan["scan"]
        si("items(source)")
        isf("index_source_file")
    end

    subgraph sgLife["watch / lifecycle"]
        osrc("open_source")
        wsrc("watch_source")
        csrc("close_source!")
        cpyds("copy")
    end

    subgraph sgContract["contract methods"]
        idsf("id(::SourceFile) → String")
        lblsf("label(::SourceFile) → String")
        fpsf("fingerprint(::SourceFile) → FileFingerprint")
        metasf("metadata(::SourceFile) → Dict")
        sid("id(::DirectorySource) → String")
        slbl("label(::DirectorySource) → String")
    end

    extCore["DataBrowserCore"]
    extAPI["DataBrowserAPI"]
    extCache["DataBrowserCache"]
    extRecipes["DataBrowserRecipes"]
    extGUI["DataBrowserGUI"]
    extPlots["DataBrowserPlots"]

    subgraph sgExt["external"]
        FSYS["filesystem"]
        BFW["BetterFileWatching"]
        CT["CancellationTokens"]
    end

    si -->|"SourceFile"| isf
    si -->|"readdir"| FSYS
    isf -->|"stat"| FSYS

    osrc -->|"isdir"| FSYS
    wsrc -->|"source items"| si
    wsrc -->|"String"| idsf
    wsrc -->|"FileFingerprint"| fpsf
    wsrc -->|"watch_folder"| BFW
    wsrc -->|"token"| CT
    csrc -->|"cancel"| CT

    extCore ==> osrc
    extCore ==> si
    extCore ==> wsrc
    extCore ==> csrc
    extCore ==> sid
    extCore ==> idsf
    extCore ==> lblsf
    extCore ==> metasf
    extCore ==> fpsf
    extCore ==> cpyds
    extCache ==> sid
    extCache ==> fpsf
    extAPI ==> sid
    extAPI ==> slbl
    extGUI ==> slbl
    extPlots ==> slbl

    wsrc -.->|"SourceChanges<br/>SourceError"| extCore

    idsf ~~~ lblsf ~~~ fpsf ~~~ metasf ~~~ sid ~~~ slbl

    classDef srcExp fill:#c9e4c5,stroke:#5a9a52,stroke-width:3px,color:#111;
    classDef srcInt fill:#c9e4c5,stroke:#5a9a52,stroke-width:1px,color:#111;
    classDef ext fill:#eceff1,stroke:#90a4ae,stroke-width:1px,color:#111;
    classDef coreC fill:#bcd4f0,stroke:#3f6fb0,color:#111;
    classDef apiC fill:#cfd8e3,stroke:#5a6b80,color:#111;
    classDef cacheC fill:#f5d6a8,stroke:#c08a3f,color:#111;
    classDef recipesC fill:#f5ecc0,stroke:#b09a3f,color:#111;
    classDef guiC fill:#d9c6ec,stroke:#7d54b0,color:#111;
    classDef plotsC fill:#f2c6d4,stroke:#b0466a,color:#111;

    class si,isf,osrc,wsrc,csrc,cpyds,idsf,lblsf,fpsf,metasf,sid,slbl srcInt;
    class extCore coreC;
    class extAPI apiC;
    class extCache cacheC;
    class extRecipes recipesC;
    class extGUI guiC;
    class extPlots plotsC;
    class FSYS,BFW,CT ext;

    linkStyle 0,2 stroke:#d1495b,stroke-width:3px;
```
