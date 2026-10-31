# TODO: move this file to DataBrowserRecipes, the package of the registration dialect, beside
# `register_item!`. The plot window would then read `registered_plots` from there.
using DataBrowserAPI: AbstractProject

"""
One plot that [`register_plot!`](@ref) added: the item `kind` it applies to, its `label`, and its
`setup` and `draw` functions.
"""
struct RegisteredPlot
    kind::Symbol
    label::String
    setup::Function
    draw::Function
end

# Keyed by project value, not by weak reference: a typed project is naturally an immutable
# singleton, which `WeakKeyDict` cannot hold. Mutable dialect projects still key by identity, so
# separately defined projects keep separate plots.
const PROJECT_PLOTS = Dict{AbstractProject,Dict{Symbol,Dict{String,RegisteredPlot}}}()

"""
    register_plot!(project, kind; label, setup, draw)

Add a plot definition for items of `kind`, shown in the browser as `label`.

`setup(selection)` creates the figure, and `draw(selection, figure)` draws into it.
Both receive a [`Selection`](@ref) containing the items to plot.

This example draws one line per item, using the `x` and `y` columns of its data:

```julia
register_plot!(project, :series; label="X–Y",
    setup = selection -> Figure(),
    draw = function (selection, figure)
        axis = Axis(figure[1, 1])
        for entry in selection
            lines!(axis, entry.data.x, entry.data.y; label=entry.label)
        end
    end)
```

Registering the same `kind` and `label` again replaces the existing plot definition.
"""
function register_plot!(
    project::AbstractProject,
    kind::Symbol;
    label::AbstractString,
    setup::Function,
    draw::Function,
)::AbstractProject
    by_kind = get!(Dict{Symbol,Dict{String,RegisteredPlot}}, PROJECT_PLOTS, project)
    by_label = get!(Dict{String,RegisteredPlot}, by_kind, kind)
    by_label[String(label)] = RegisteredPlot(kind, String(label), setup, draw)
    return project
end

"""
    registered_plots(project, kind) -> Vector{RegisteredPlot}

The plots that [`register_plot!`](@ref) added for items of `kind`, sorted by label. A plot draws a
selection without the browser:

```julia
plot = only(registered_plots(project, :series))
figure = plot.setup(selection)
plot.draw(selection, figure)
```
"""
function registered_plots(project::AbstractProject, kind::Symbol)::Vector{RegisteredPlot}
    by_kind = get(PROJECT_PLOTS, project, nothing)
    by_kind === nothing && return RegisteredPlot[]
    by_label = get(by_kind, kind, Dict{String,RegisteredPlot}())
    return sort!(collect(values(by_label)); by=plot -> plot.label)
end
