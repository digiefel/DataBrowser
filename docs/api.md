# API

DataBrowserCore is the runtime: the part of DataBrowser that does the work. You give it two things:
where your data comes from, such as a lab database, an instrument or a folder of files, and code
that says how to read and process that data. The runtime reads the data with your code, processes
it when something asks for it, such as when you select it in the browser, and keeps the results.

In DataBrowser's terms, your code is a *project*, where the data comes from is a *source*, and a
project opened on a source is a *workspace*.

Code on both sides of the runtime uses the API:

- **Providers** are code that the runtime calls, such as your project, or a visualizer that
  displays your data.
- **Clients** are code that calls the runtime, such as a script that asks for the processed data,
  or the browser.

The API is divided into surfaces: groups of functions and types that are used together. Each
surface is a provider surface or a client surface.

| Surface                           | Side     | Contents                                                                  | Package            |
|:----------------------------------|:---------|:--------------------------------------------------------------------------|:-------------------|
| [Type API](#Type-API)             | provider | Types and methods that describe a project: its items, collections, processing and storage | DataBrowserAPI |
| [Sources](#Sources)               | provider | Types and methods that find source items and report their changes        | DataBrowserAPI, DataBrowserSources |
| [Visualizers](#Visualizers)       | provider | Types that display data and metadata in the browser, in any form the data needs | DataBrowserAPI   |
| [GUI extensions](#GUI-extensions) | provider | Types that add windows and menus to the browser                           | DataBrowserGUI     |
| [Workspace](#Workspace)           | client   | Functions that open a project on a source, select items and return their data | DataBrowserCore |
| [Browser](#Browser)               | client   | Functions that open and close the browser on a workspace                  | DataBrowserGUI     |

Two packages implement a provider surface and add functions of their own:

| Package                           | Implements  | Contents                                                                    |
|:----------------------------------|:------------|:----------------------------------------------------------------------------|
| [DataBrowserRecipes](#Recipes)    | Type API    | Functions that describe a project with plain functions of data and metadata, without defining types |
| [DataBrowserPlots](#Plots)        | Visualizers | A plot visualizer, and functions that define plots in AlgebraOfGraphics syntax, drawn with Makie |

`using DataBrowser` loads every package and exports the names of every surface and of both packages.

## Provider surfaces

### Type API

A project describes its data with Julia types and methods. DataBrowser calls the methods in the
order of the stages below, and keeps their results.

#### Projects

```@docs
DataBrowserAPI.AbstractProject
```

#### Items and collections

An item has an id, a label, data and metadata. Collections arrange items in a tree.

```@docs
DataBrowserAPI.AbstractDataItem
DataBrowserAPI.AbstractCollection
DataBrowserAPI.AbstractGroup
DataBrowserAPI.id
DataBrowserAPI.label
DataBrowserAPI.data
DataBrowserAPI.metadata
DataBrowserAPI.collection
DataBrowserAPI.members
```

#### Stages

`read` loads a source item, `expand` turns what it loaded into items, and `process` computes the
processed version of an item or a collection.

```@docs
Base.read(::DataBrowserAPI.AbstractProject, ::DataBrowserAPI.AbstractDataSource, ::DataBrowserAPI.AbstractDataSourceItem)
DataBrowserAPI.expand
DataBrowserAPI.process
DataBrowserAPI.reconstruct
DataBrowserAPI.has_stage
DataBrowserAPI.stage_roots
```

#### Storage

```@docs
DataBrowserAPI.AbstractStore
DataBrowserAPI.storage
DataBrowserAPI.stored_size
```

### Sources

A source finds source items and reports when they change. A source item is one unit that `read`
loads, such as a file, a database record or one acquisition of an instrument. One source type can
serve many projects.

```@docs
DataBrowserAPI.AbstractDataSource
DataBrowserAPI.AbstractDataSourceItem
DataBrowserAPI.open_source
DataBrowserAPI.close_source!
DataBrowserAPI.items
DataBrowserAPI.watch_source
DataBrowserAPI.fingerprint
```

#### Included sources

DataBrowserSources implements this contract for a directory of files.

```@docs
DataBrowserSources.DirectorySource
DataBrowserSources.SourceFile
```

### Visualizers

A visualizer shows one value in the form its domain needs: an X-ray diffraction pattern with its
indexed peaks, the wind field of a weather simulation on a globe, a crystal structure that the user
can rotate, a micrograph with its grain boundaries drawn over it. The browser calls `prepare!` when
the value changes and `draw!` in every frame.

```@docs
DataBrowserAPI.AbstractVisualizer
DataBrowserAPI.Setting
DataBrowserAPI.prepare!
DataBrowserAPI.draw!
DataBrowserAPI.draw_header!
DataBrowserAPI.settings
DataBrowserAPI.initial_size
DataBrowserAPI.output
DataBrowserAPI.select!
DataBrowserAPI.selection
DataBrowserAPI.export!
```

### GUI extensions

```@docs
DataBrowserGUI.GuiExtension
DataBrowserGUI.register_gui_extension!
DataBrowserGUI.with_font
DataBrowserGUI.CodeFile
```

## Client surfaces

### Workspace

`open_workspace(project, source)` gives the runtime your project and your source, and returns a
workspace. You use the workspace to select items and get their data.

```@docs
DataBrowserCore.open_workspace
DataBrowserCore.close_workspace!
DataBrowserCore.wait_workspace_idle!
DataBrowserCore.workspace_status
```

#### Items and selection

```@docs
DataBrowserCore.select
DataBrowserCore.Selection
DataBrowserCore.materialize_items
DataBrowserCore.query_items
DataBrowserCore.unnest
```

#### Computations

A computation is a function call that the workspace runs when its value is needed, and whose
result it keeps.

```@docs
DataBrowserAPI.Computation
DataBrowserAPI.evaluate
DataBrowserAPI.computation
DataBrowserAPI.inputs
DataBrowserAPI.last_execution
DataBrowserAPI.ComputationExecution
DataBrowserAPI.cache_info
DataBrowserCore.ResultItem
DataBrowserCore.Group
DataBrowserCore.ComputationItem
```

#### Tags

```@docs
DataBrowserCore.Tag
DataBrowserCore.tags
DataBrowserCore.tag!
DataBrowserCore.untag!
```

### Browser

```@docs
DataBrowserGUI.open_browser
DataBrowserGUI.close_browser!
DataBrowserGUI.BrowserSession
DataBrowserGUI.wait_browser_ready
```

## Built on the surfaces

### Recipes

A project made with functions: each function receives data and metadata, and DataBrowserRecipes
implements the type API for it.

```@docs
DataBrowserRecipes.define_project
DataBrowserRecipes.register_item!
DataBrowserRecipes.register_collection!
DataBrowserRecipes.register_csv!
```

### Plots

```@docs
DataBrowserPlots.figure
DataBrowserPlots.@plot
DataBrowserPlots.@invisible
DataBrowserPlots.register_plot!
DataBrowserPlots.add_layer!
DataBrowserPlots.set_analysis!
```
