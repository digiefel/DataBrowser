using DataBrowser

length(ARGS) == 1 || error("Usage: julia --project=examples project.jl DATA_DIRECTORY")

project = define_project("CSV tables")

# The recipe detects CSV files, reads their tables, and labels items with their filenames.
# Other `register_item!` callbacks still apply, including a custom `label`.
register_csv!(project)

workspace = open_workspace(project, only(ARGS))
open_browser(workspace)
