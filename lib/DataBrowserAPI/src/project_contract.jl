"""
Supertype of every DataBrowser project.

A project defines methods of `read` and `process` for its item types, and may define the
functions below. The workspace keeps the caches, the jobs and the state of the browser, so a project
holds only what its own methods need. `DataBrowserRecipes.Project` is one project type.
"""
abstract type AbstractProject end

"""Return the stable name used to identify a project. Defaults to the project type's name."""
project_name(project::AbstractProject)::String = string(nameof(typeof(project)))

"""Return a short human-readable description of a project."""
project_description(::AbstractProject)::String = ""

"""
The name that the browser shows for the item type whose `label` is `kind`. The default is
`string(kind)`.
"""
kind_label(::AbstractProject, kind::Symbol)::String = string(kind)

# TODO: no package reads `PROJECTS` or `DEFAULT_PROJECT`. Use them for the choice of a project in
# the browser, or delete them.
"""
The projects that the browser can offer when the caller gives none, and the project it offers first.
"""
const PROJECTS = AbstractProject[]
const DEFAULT_PROJECT = Ref{Union{AbstractProject,Nothing}}(nothing)
