using InteractiveUtils: subtypes

using DataBrowserAPI: AbstractProject

"""One plot registered for an item kind with [`register_plot!`](@ref)."""
struct PlotRecipe
    kind::Symbol
    label::String
    setup::Function
    draw::Function
end

# Keyed by project value, not by weak reference: a typed project is naturally an immutable
# singleton, which `WeakKeyDict` cannot hold. Mutable dialect projects still key by identity, so
# separately defined projects keep separate recipes.
const PROJECT_PLOT_RECIPES = Dict{AbstractProject, Dict{Symbol, Dict{String, PlotRecipe}}}()

"""Plot recipes registered for one project."""
function _plot_recipes(project::AbstractProject)::Dict{Symbol, Dict{String, PlotRecipe}}
    return get!(PROJECT_PLOT_RECIPES, project) do
        Dict{Symbol, Dict{String, PlotRecipe}}()
    end
end

"""
Base type for visualizers selectable by the browser and Julia API.

`PlotKind` is an internal identity used by the engine to dispatch plotting. Projects do not define
their own subtypes; they call `register_plot!`, and the engine represents each registered plot as a
`RegisteredPlot{kind,label}`.
"""
abstract type PlotKind end

"""
Internal plot identity for a plot registered with `register_plot!`, parameterized by the item kind
it applies to and the label that distinguishes plots for that kind.
"""
struct RegisteredPlot{Kind,Label} <: PlotKind end

"""Create the figure layout a plot kind requires for the given items."""
function setup_plot end

"""Draw the given items into an existing figure."""
function plot_data! end

"""
    embed(figure, id)

Draw `figure` inside the browser window that is being drawn. `id` names the place of the figure in
that window and stays the same from frame to frame. A plot backend adds a method for its figure
type; the GLMakie extension has the one for a Makie `Figure`.
"""
function embed end

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
    label_string = String(label)
    recipes = get!(_plot_recipes(project), kind) do
        Dict{String,PlotRecipe}()
    end
    recipes[label_string] = PlotRecipe(kind, label_string, setup, draw)
    return project
end

"""Every plot registered for an item kind, sorted by label."""
function registered_plot_kinds(project, kind::Symbol)::Vector{Type{<:PlotKind}}
    recipes = get(_plot_recipes(project), kind, nothing)
    recipes === nothing && return Type{<:PlotKind}[]
    return Type{<:PlotKind}[
        RegisteredPlot{kind,Symbol(label)}
        for label in sort!(collect(keys(recipes)))
    ]
end

"""Human label for a registered plot kind, taken from its recipe."""
function plot_kind_label(project, ::Type{RegisteredPlot{Kind,Label}})::String where {Kind,Label}
    return _plot_recipes(project)[Kind][String(Label)].label
end

"""
Return every loaded concrete visualizer type.

Visualizers are discovered from Julia's type hierarchy, so external project packages require no
registration with the browser engine.
"""
function plot_kinds()::Vector{Type{<:PlotKind}}
    kinds = Type{<:PlotKind}[]
    pending = Type[PlotKind]
    while !isempty(pending)
        for child in subtypes(pop!(pending))
            isabstracttype(child) ? push!(pending, child) : push!(kinds, child)
        end
    end
    sort!(kinds; by=kind -> String(nameof(kind)))
    return kinds
end
