# The description of a plot as plain data, and the function that draws it. Nothing here knows about
# items or a workspace: a description is drawn from any table.
#
# A description holds column names and marks as values, never as type parameters. Every description
# has the same type, so drawing a plot of a new shape compiles no new code.
#
# TODO: the functions a script writes a description with, and the builder window that edits one
# (roadmap 0.11.0). Until both exist, the types are not exported.

"""
    Layer(mark; roles=[], fixed=[])

One layer of a plot: one kind of mark, drawn for the rows of a table.

- `mark` is `:points` or `:lines`.
- `roles` says which column plays which role in this layer, as `role => column` pairs. It adds to
  the roles of the [`PlotDescription`](@ref) and replaces those with the same name.
- `fixed` gives the marks of this layer one value for all rows, as `attribute => value` pairs, for
  example `:linewidth => 2`. The attributes are those of the Makie plot that draws the mark.
"""
struct Layer
    mark::Symbol
    roles::Vector{Pair{Symbol,Symbol}}
    fixed::Vector{Pair{Symbol,Any}}
end

Layer(mark::Symbol; roles=Pair{Symbol,Symbol}[], fixed=Pair{Symbol,Any}[]) =
    Layer(mark, collect(Pair{Symbol,Symbol}, roles), collect(Pair{Symbol,Any}, fixed))

"""
    PlotDescription(; roles=[], layers=[])

What a plot shows, without the table it shows it for.

`roles` says which column plays which role in every layer, as `role => column` pairs. `layers` are
drawn in order, the first at the back. The roles are:

- `:x` and `:y`, the columns on the two axes. Rows without a finite number in both are left out.
- `:color`. A column of numbers colors each mark by its value. Any other column gives one group of
  marks for each of its values, each group in its own color and named in the legend.

    PlotDescription(
        roles=[:x => :current, :y => :voltage, :color => :item],
        layers=[Layer(:points), Layer(:lines; fixed=[:linewidth => 2])],
    )

Draw a description with [`figure`](@ref).
"""
struct PlotDescription
    roles::Vector{Pair{Symbol,Symbol}}
    layers::Vector{Layer}
end

PlotDescription(; roles=Pair{Symbol,Symbol}[], layers=Layer[]) =
    PlotDescription(collect(Pair{Symbol,Symbol}, roles), collect(Layer, layers))

"""
    figure(description, table)

Draw `description` for `table` and return the figure. `table` is any Tables.jl table. A plot backend
adds the method; the GLMakie extension has the one that returns a Makie `Figure`.
"""
function figure end
