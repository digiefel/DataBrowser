import CImGui as ig
import GLMakie.Makie as Makie

using DataBrowserAPI: AbstractDataItem, Setting
import DataBrowserAPI: draw!, prepare!, settings
using DataBrowserGUI: ItemTable, merge_item_tables
using DataBrowserPlots: Layer, PlotDescription, figure
using .MakieImguiIntegration: plot_theme

const NO_TABLE = "Select items with table data to build a plot."
# The width of the panel that shows the description, in pixels.
const DESCRIPTION_WIDTH = 250.0f0

"""
The plot builder: the user builds a plot from menus, for the table data of items or for a table
that another window passes on.

The window shows the figure and, to its right, the [`PlotDescription`](@ref) of the plot written
as code: the roles, then one line for each layer. Every value is a menu.
"""
Base.@kwdef mutable struct BuilderView <: FigureView
    description::PlotDescription = PlotDescription(layers=[Layer(:lines)])
    inspect::Bool = false
    # The data of the items as one table, and the columns the menus offer. With several items,
    # `item` is one of them: it names the item of each row.
    table::Union{Nothing,ItemTable} = nothing
    columns::Vector{Symbol} = Symbol[]
    # The user changed the description since the figure was built.
    stale::Bool = false
    figure::Any = nothing
    dark::Bool = true
    figure_id::String = ""
    message::String = NO_TABLE
    export_error::String = ""
end

DataBrowserAPI.label(::BuilderView) = "Plot builder"

settings(view::BuilderView) =
    view.figure === nothing ? (;) : (inspect=Setting("Inspect"; prepare=false),)

function export_name(view::BuilderView)::String
    roles = Dict(view.description.roles)
    return "$(roles[:y])-over-$(roles[:x])"
end

prepare!(view::BuilderView, items::AbstractVector{<:AbstractDataItem}, ctx) =
    prepare!(view, first(merge_item_tables(items)), ctx)

function prepare!(view::BuilderView, table::ItemTable, ctx)::Nothing
    view.figure_id = "plot_$(ctx.id)"
    view.table = table
    view.columns = Symbol.(view.table.columns)
    several = length(view.table.item_labels) > 1
    # TODO: a column of the data that is also called `item` hides the item of each row.
    several && !(:item in view.columns) && push!(view.columns, :item)
    # Without columns the description stays as it is, for the items selected next.
    isempty(view.columns) && return build!(view, ctx)

    # Keep the roles whose column the items have. The first two columns are on the axes until the
    # user chooses others.
    roles = view.description.roles
    filter!(role -> last(role) in view.columns, roles)
    for (role, column) in zip((:x, :y), view.columns)
        any(taken -> first(taken) === role, roles) || push!(roles, role => column)
    end
    # Without a group for each item, a line would run from the last row of one item to the first
    # row of the next.
    # TODO: this returns the color at each new selection, also after the user removed it.
    several && !any(taken -> first(taken) === :color, roles) && push!(roles, :color => :item)
    build!(view, ctx)
    return nothing
end

function build!(view::BuilderView, ctx)::Nothing
    view.dark = DARK[]
    table = view.table
    description = view.description
    if table === nothing || table.rows == 0 || length(table.columns) < 2
        close(view)
        view.message = NO_TABLE
        return nothing
    end
    try
        # Read only the columns that have a role.
        # TODO: this reads one cell at a time; give `ItemTable` whole columns.
        columns = Dict{Symbol,Vector{Any}}()
        for roles in (description.roles, (layer.roles for layer in description.layers)...), (_, name) in roles
            index = findfirst(==(String(name)), table.columns)
            columns[name] = index === nothing ?
                Any[table.item_labels[item] for item in table.row_item] :
                Any[table.getvalue(row, index) for row in 1:table.rows]
        end
        view.figure = Makie.with_theme(plot_theme(view.dark)) do
            figure(description, columns)
        end
        view.message = ""
    catch err
        bt = catch_backtrace()
        close(view)
        summary = first(split(sprint(showerror, err), '\n'; limit=2))
        view.message = "Plot failed: $summary. See the console for full details."
        @error "Plot builder: drawing failed" description exception=(err, bt)
    end
    return nothing
end

function draw!(view::BuilderView, ctx)::Nothing
    if view.table === nothing || isempty(view.columns)
        ig.TextWrapped(view.message)
        return nothing
    end
    # Build before the figure is drawn: a figure must not be released in the frame that drew it.
    if view.stale
        view.stale = false
        build!(view, ctx)
    end

    available = ig.GetContentRegionAvail()
    spacing = unsafe_load(ig.GetStyle().ItemSpacing).x
    ig.BeginChild("figure", (max(available.x - DESCRIPTION_WIDTH - spacing, 1.0f0), 0.0f0), false)
    invoke(draw!, Tuple{FigureView,Any}, view, ctx)
    ig.EndChild()
    ig.SameLine()
    ig.BeginChild("description", (0.0f0, 0.0f0), true)

    # TODO: these edits become the functions a script changes a description with (roadmap 0.11.0).
    # TODO: roles and fixed values of one layer; "+ argument" for the roles not in use.
    roles = view.description.roles
    ig.TextDisabled("plot(")
    for role in (:x, :y, :color)
        index = findfirst(taken -> first(taken) === role, roles)
        current = index === nothing ? nothing : last(roles[index])
        ig.AlignTextToFramePadding()
        ig.TextUnformatted("  $(rpad(role, 6))")
        ig.SameLine()
        ig.TextDisabled("=")
        ig.SameLine()
        chosen = current
        preview = current === nothing ? "—" : String(current)
        if ig.BeginCombo("##$role", preview, ig.ImGuiComboFlags_WidthFitPreview)
            # The axes need a column; the color can go without one.
            role === :color && ig.Selectable("—", current === nothing) && (chosen = nothing)
            for column in view.columns
                ig.Selectable(String(column), column === current) && (chosen = column)
            end
            ig.EndCombo()
        end
        chosen === current && continue
        index === nothing || deleteat!(roles, index)
        chosen === nothing || push!(roles, role => chosen)
        view.stale = true
    end
    ig.TextDisabled(")")

    layers = view.description.layers
    removed = nothing
    for (index, layer) in enumerate(layers)
        ig.PushID(index)
        ig.AlignTextToFramePadding()
        ig.TextDisabled("+")
        ig.SameLine()
        if ig.BeginCombo("##mark", String(layer.mark), ig.ImGuiComboFlags_WidthFitPreview)
            for mark in sort!(collect(keys(MARKS)))
                if ig.Selectable(String(mark), mark === layer.mark) && mark !== layer.mark
                    layers[index] = Layer(mark, layer.roles, layer.fixed)
                    view.stale = true
                end
            end
            ig.EndCombo()
        end
        ig.SameLine()
        ig.TextDisabled("()")
        ig.SameLine()
        ig.SmallButton("x") && (removed = index)
        ig.SetItemTooltip("Remove this layer")
        ig.PopID()
    end
    if removed !== nothing
        deleteat!(layers, removed)
        view.stale = true
    end
    if ig.SmallButton("+ layer")
        push!(layers, Layer(:points))
        view.stale = true
    end

    ig.EndChild()
    return nothing
end
