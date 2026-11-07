# API

This page lists the public functions and types of DataBrowser.

The runtime, DataBrowserCore, reads the data of a source with the code of a project, processes the
data and keeps the results. The browser shows those results. Code that uses the API is either a
provider or a client:

- A *provider* is called by DataBrowser. A project is a provider: the runtime calls it to read and
  process data. A visualizer is a provider too: the browser calls it to display a value.
- A *client* calls DataBrowser. A script that asks the runtime for processed data is a client, and
  so is the browser.

The API is divided into surfaces: groups of functions and types that are used together. Each
surface is a provider surface or a client surface.

| Surface                           | Side     | Contents                                                                  | Package            |
|:----------------------------------|:---------|:--------------------------------------------------------------------------|:-------------------|
| [Type API](#Type-API)             | provider | Types and methods that describe a project: its items, processing and storage | DataBrowserAPI |
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

#### Items

An item has an id, a label, data and metadata.

```@docs
DataBrowserAPI.AbstractDataItem
DataBrowserAPI.AbstractGroup
DataBrowserAPI.id
DataBrowserAPI.label
DataBrowserAPI.data
DataBrowserAPI.metadata
Base.isequal(::DataBrowserAPI.AbstractDataItem, ::DataBrowserAPI.AbstractDataItem)
DataBrowserAPI.members(::DataBrowserAPI.AbstractGroup)
```

#### Stages

`read` loads a source item, or makes the group of a source item with members. `process` computes
results from an item, from a group with the values of its members, or from a member with its group.

```@docs
Base.read(::DataBrowserAPI.AbstractProject, ::DataBrowserAPI.AbstractDataSource, ::DataBrowserAPI.AbstractDataSourceItem)
Base.read(::DataBrowserAPI.AbstractProject, ::DataBrowserAPI.AbstractDataSource, ::DataBrowserAPI.AbstractDataSourceItem, ::AbstractVector{<:DataBrowserAPI.AbstractDataItem})
DataBrowserAPI.SourceGroup
DataBrowserAPI.process
DataBrowserAPI.reconstruct
```

#### Storage

```@docs
DataBrowserAPI.AbstractStore
DataBrowserAPI.storage
DataBrowserAPI.stored_size
```

### Sources

A source finds source items and reports when they change. A source item is one unit that `read`
loads, such as a file, a database record or one acquisition of an instrument. A source item with
members, such as a folder, is a group. One source type can serve many projects.

```@docs
DataBrowserAPI.AbstractDataSource
DataBrowserAPI.AbstractDataSourceItem
DataBrowserAPI.open_source
DataBrowserAPI.close_source!
DataBrowserAPI.items
DataBrowserAPI.members(::DataBrowserAPI.AbstractDataSource, ::DataBrowserAPI.AbstractDataSourceItem)
DataBrowserAPI.watch_source
DataBrowserAPI.fingerprint
```

#### Included sources

DataBrowserSources implements this contract for a directory of files.

```@docs
DataBrowserSources.DirectorySource
DataBrowserSources.SourceFile
DataBrowserSources.SourceDirectory
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
Base.haskey(::DataBrowserCore.Workspace.Workspace, ::AbstractString)
Base.sort!(::DataBrowserCore.Workspace.Workspace)
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
```
