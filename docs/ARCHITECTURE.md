# DataBrowser Architecture

This document describes the current implementation unless a section explicitly states a target.
The broader product direction is in `docs/vision.md`; proposed contract evolution is in
`docs/plans/scientific-workspace.md` (Scientific workspace: analysis and acquisition). In particular,
production non-repeatable sources, multiple live sources in one workspace, and headless tab/view
definitions are not implied by the current diagrams. The [active plan index](plans/README.md)
records the newer group, processing and storage proposals. Their decisions and candidate APIs are
not claims about the engine described below.

## What this is

DataBrowser is a Julia working environment for data projects. It should be strictly
better than opening a REPL, finding files, loading them, extracting useful tables, computing values,
and writing figure code by hand. The app makes that workflow interactive: open a project, browse the
source structure, select items, inspect data-derived values, and switch plots or views
without repeating the same parsing work.

Project code should describe the project in the same terms a script would use: which logical items a
source item contains, how to load data for those items, and how to present that data. The
package owns scanning, cache storage, background jobs, and UI state.

The intended experience is live and composable. A project can stay open while source files are added
or changed, and the browser should update without forcing the user back through startup or manual
reload steps. Views should be able to follow selections or matching rules, so a plot or
inspection tool can continue to show the relevant data as the source tree changes. Built-in
visualizers should handle common inspection tasks, while project code adds only the reading
and presentation details that are specific to the experiment.

## Package map

A solid arrow from A to B means A depends on B at compile time: A needs B to build.
A dotted arrow from A to B means A calls functions whose methods live in B through dispatch, even though A has no dependency on B.
🦆 marks DuckDB, 📈 GLMakie, 🖼 CImGui / GLFW.

```mermaid
flowchart TB
    db["<b>DataBrowser</b><br/>install target<br/>defines the public API"]
    prof["<b>DataBrowserProfiling</b><br/>internal tooling"]
    fitting["<b>DataBrowserFitting</b><br/>least-squares solver of fit<br/>loads on the first fit"]

    subgraph projects["Project packages"]
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
        api["<b>DataBrowserAPI</b><br/>AbstractProject, stage, source, item and visualizer interfaces"]
    end

    db --> recipes
    db --> plots
    gui -->|"open_workspace<br/>modify_workspace!<br/>select!<br/>select<br/>materialize_items<br/>workspace_status"| core
    gui --> cache
    plots -->|"GUI extension hooks<br/>ItemTable<br/>merge_item_tables"| gui
    plots -->|"materialize_items"| core
    plots --> fitting
    core --> src
    core --> cache
    core --> ann
    core --> api
    src --> api
    cache --> api
    ann --> api
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

## Core Flow

A workspace opens one project on one source. The project says how to read each source item and how
to process items. The workspace makes each of these calls a computation, keeps all of them in one catalog, and keeps their results. It runs a
computation when its result is needed, and runs it again when the source or the code that it
depends on changes.

The project defines:

- reading each source item (`read`), and making a group from a source item with members and the
  values of its members (the group form of `read`);
- processing one item (`process`), a group with the values of its members, and a member with its
  group;
- project-specific visualizers, when generic ones are not enough.

The workspace owns:

- the open source and its identity (several sources in one workspace are a target, not the current
  implementation);
- the catalog of computations, and the values that their results give, each addressed by its id;
- the order in which computations run, their results, and the cache;
- scanning the source, progress, failures and cancellation;
- the selection.

The browser owns windows, controls, filters and temporary rendering state. Annotations store tags,
notes and other metadata that people write. Project code does not know whether a value came from
memory, the cache or the source, and the package does not know what a source item means beyond the
methods of the contract it calls.

### The engine

The workspace makes each call of the project a computation, and keeps all of its computations in one
catalog: a graph whose rows are computations, linked by the results that one row reads from another.
Workers run the rows that something wants or requests. They keep each result in the store that the
project chooses for its type, and record its version in the cache, so that a workspace that opens
again computes only what changed. A change to the source or to the code makes the rows that depend
on it stale, and they run again when something wants or requests them. A row that throws an error is
failed: it keeps its error until its code or an input changes.

```mermaid
flowchart LR
    source["source"] -->|source items| pipeline["pipeline: adds rows"]
    pipeline --> catalog["catalog: rows and their states"]
    catalog -->|jobs| workers["workers: call project code"]
    workers -->|results| stores["stores"]
    workers -->|versions and failures| cache["cache"]
    workers -->|finished rows| pipeline
    code["code changes"] -->|stale rows| catalog
```

The code of each part explains it:

| Page | What it explains |
| --- | --- |
| [`Catalogs.jl`](code/lib/DataBrowserCore/src/Catalogs.md) | rows, their states, and the rules that decide what runs and what stays |
| [`Pipeline.jl`](code/lib/DataBrowserCore/src/Workspace/Pipeline.md) | the rows of the project's calls, the versions of each value, groups and their members, and when rows are added |
| [`Evaluate.jl`](code/lib/DataBrowserCore/src/Workspace/Evaluate.md) | how rows run, their names and versions, where results are kept, code changes |
| [`CodeRevisions.jl`](code/lib/DataBrowserCore/src/CodeRevisions.md) | the code revision of a function: what it follows and what it cannot see |

<!-- TODO: move the sections below into the code that they describe (Items.jl, Calls.jl). -->

### Items

A value is addressed by its id. The rows that give a value with that id are its versions, in the
order of the pipeline, and the last one is its current version: the readiness of the value is the
state of that row. Views, queries and the tree of the browser use the latest version that gave the
value, with its metadata and label.

The source items that are not read yet (`unread`) are known from the moment the source lists them.
`read_first!` reads some of them before any other.

### Other computations

Scripts, windows and plots also compute what no `process` of the project describes, because its
inputs are chosen elsewhere, such as the groups of a fit in a plot. `evaluate(workspace,
computation)` gives the result of such a computation: the workspace adds its row to the catalog,
runs it ahead of background work, and keeps it until it closes. An item of the workspace among its
arguments stands for the row of the item's latest value, so the next `evaluate` computes it again
after the item changed. Windows evaluate computations this way in their background preparation.
`computation(workspace, id)` gives the computation of the current version of a value, and
`inputs(computation)` the computations it reads. Neither loads a value nor runs project code.

### The code view

The code view shows the computations as calls, in the order they ran. The row of a source item shows
as one call, `read`. Each call keeps the computations of its items, and the selection passes them on through
`output`. Linked windows evaluate those computations the same way as table selections.

A window holds the values it computed as a selection of computations, whose data is their results.
A value computed from one item keeps the metadata of that item, and a computation that gives an item
has the id and label of that item, with its metadata on top. Scientific transforms receive the
result of the call before them.

## Core–Cache boundary

Core owns the workspace, catalog, and scan. Cache owns cache storage and returns data
snapshots or payloads through its exported interface. Core does not inspect Cache stores or use its
private buffer helpers.

Both persistent and in-memory workspaces use the same DuckDB stores and cache operations.
`cache=false` opens a private `:memory:` database that moves data it cannot hold in memory to a
temporary directory of its own; closing the workspace discards it without changing the project's
cache file. The values of items are in the stores of their item types, not in the cache.

```mermaid
flowchart LR
    core["DataBrowserCore<br/>workspace and catalog"]
    cache["DataBrowserCache<br/>storage and cache buffers"]
    snapshot[("saved outputs<br/>of each computation")]
    records[("version and failure<br/>of each computation")]
    source["project callbacks"]

    core -->|"load_outputs"| cache
    cache -->|"id, label, type, members<br/>and metadata of each output"| snapshot
    snapshot --> core
    core -->|"recorded_revision"| cache
    cache -->|"recorded version and failure"| records
    records --> core
    core -->|"store_output!<br/>delete_output!<br/>store_computation_revision!"| cache
    source -->|"read / process"| core

    classDef coreC fill:#bcd4f0,stroke:#3f6fb0,color:#111
    classDef cacheC fill:#f5d6a8,stroke:#c08a3f,color:#111
    classDef stateC fill:#c9e4c5,stroke:#5a9a52,color:#111
    class core,source coreC
    class cache cacheC
    class snapshot,records stateC
```

## Subpackages

Each package gets two views. A class diagram shows its data model: the structs, their fields, and
how they subtype the API abstractions and compose. The call flow diagram shows which functions
call which as arrows, with A -data-> B meaning "A calls B, which returns `data`".

A solid arrow is a call, labelled with the value the callee returns.
External calls from other packages are shown as thicker arrows.
"hot path" calls which are very frequent and performance-critical are shown in red.
A dashed arrow is data written to or read from storage.

A thick border marks a symbol the package exports.
`X_or_Nothing` means a field may contain either `X` or `nothing`.

### DataBrowserSources

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

    class isf srcExp;
    class si,osrc,wsrc,csrc,cpyds,idsf,lblsf,fpsf,metasf,sid,slbl srcInt;
    class extCore coreC;
    class extAPI apiC;
    class extCache cacheC;
    class extRecipes recipesC;
    class extGUI guiC;
    class extPlots plotsC;
    class FSYS,BFW,CT ext;

    linkStyle 0,2 stroke:#d1495b,stroke-width:3px;
```
