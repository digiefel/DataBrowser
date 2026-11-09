# Mouse gestures on the axes of an embedded figure.
#
# The browser handles zoom, pan and reset itself, in place of the interactions Makie gives each
# axis. Makie lets one axis take a mouse event, so axes that share a cell of a figure, such as two
# y axes over one x axis, do not move together. Here a gesture inside the plot area acts on every
# axis under the mouse, and a gesture on the ticks and label of one axis acts on that axis alone.
#
# Positions are in pixels of the figure, with the origin at the bottom left, as in Makie.

# The interactions of a Makie axis that the gestures replace.
const REPLACED_INTERACTIONS = (:rectanglezoom, :scrollzoom, :dragpan, :limitreset)
# One step of the mouse wheel shows this share less of an axis.
const ZOOM_PER_STEP = 0.1
# A rectangle smaller than this many pixels, on each side, is a click and not a zoom.
const MIN_RECTANGLE = 5

"""
A gesture that lasts while a mouse button is held. `kind` is `:rectangle` or `:pan`. `dims` holds
the directions the gesture changes: 1 for x, 2 for y.
"""
mutable struct AxisGesture
    kind::Symbol
    button::Int
    axes::Vector{Makie.Axis}
    dims::Vector{Int}
    start::Tuple{Float64,Float64}
    last::Tuple{Float64,Float64}
end

"""The area of the figure that holds the ticks and the label of one direction of an axis."""
function strip(axis::Makie.Axis, dim::Int)::Makie.Rect2f
    area = axis.scene.viewport[]
    (x, y), (width, height) = area.origin, area.widths
    outside = axis.layoutobservables.protrusions[]
    if dim == 1
        return axis.xaxisposition[] == :bottom ?
            Makie.Rect2f(x, y - outside.bottom, width, outside.bottom) :
            Makie.Rect2f(x, y + height, width, outside.top)
    end
    return axis.yaxisposition[] == :left ?
        Makie.Rect2f(x - outside.left, y, outside.left, height) :
        Makie.Rect2f(x + width, y, outside.right, height)
end

inside(position, area)::Bool =
    all(area.origin .<= position) && all(position .<= area.origin .+ area.widths)

"""
Where a pixel position lies along one direction of an axis, as a fraction of what the axis shows:
0 at its lower limit and 1 at its upper limit.
"""
function fraction(axis::Makie.Axis, dim::Int, position)::Float64
    area = axis.scene.viewport[]
    value = (position[dim] - area.origin[dim]) / area.widths[dim]
    return (dim == 1 ? axis.xreversed[] : axis.yreversed[]) ? 1 - value : value
end

"""
Make each axis show a window of what it shows now, and add the axes to `zoomed_axes`.
`windows(axis)[dim]` gives the new lower and upper limits as fractions of the current ones: `(0, 1)`
changes nothing, `(0.25, 0.75)` shows the middle half. Fractions are taken on the scale of the axis,
so a logarithmic axis zooms evenly.
"""
function reframe!(windows::Function, axes::Vector{Makie.Axis}, zoomed_axes::Vector{Makie.Axis})::Nothing
    ## Every new limit is computed before any is set: setting the limits of an axis also moves
    ## the axes linked to it.
    framed = map(axes) do axis
        limits = axis.targetlimits[]
        scales = (axis.xscale[], axis.yscale[])
        window = windows(axis)
        bounds = map(1:2) do dim
            lower = scales[dim](limits.origin[dim])
            upper = scales[dim](limits.origin[dim] + limits.widths[dim])
            Makie.inverse_transform(scales[dim]).(lower .+ window[dim] .* (upper - lower))
        end
        Makie.Rect2d(bounds[1][1], bounds[2][1], bounds[1][2] - bounds[1][1], bounds[2][2] - bounds[2][1])
    end
    for (axis, limits) in zip(axes, framed)
        all(isfinite, limits.origin) && all(isfinite, limits.widths) && (axis.targetlimits[] = limits)
    end
    union!(zoomed_axes, axes)
    return nothing
end

# The window that keeps the fraction `center` in place and shows `share` of the axis.
zoomed(center::Float64, share::Float64) = (center * (1 - share), center + (1 - center) * share)

"""
Handle the mouse for the axes of `figure` during one frame. `position` is the mouse in pixels of
the figure and `hovered` says whether the mouse is over the figure. `to_screen` converts a position
to the coordinates ImGui draws in. `zoomed_axes` holds the axes that a gesture zoomed or panned and
that no Ctrl-click has reset since. Returns the gesture in progress, or `nothing`.
"""
function axis_gestures!(
    gesture::Union{Nothing,AxisGesture},
    zoomed_axes::Vector{Makie.Axis},
    figure::Makie.Figure,
    position::Tuple{Float64,Float64},
    hovered::Bool,
    to_screen::Function,
)::Union{Nothing,AxisGesture}
    axes = Makie.Axis[content for content in figure.content if content isa Makie.Axis]
    for axis in axes, name in REPLACED_INTERACTIONS
        haskey(Makie.interactions(axis), name) && Makie.deregister_interaction!(axis, name)
    end
    io = ig.GetIO()
    ## Holding x or y limits a gesture in the plot area to that direction.
    held = Int[dim for (dim, key) in ((1, ig.ImGuiKey_X), (2, ig.ImGuiKey_Y)) if ig.IsKeyDown(key)]
    free = isempty(held) ? [1, 2] : held

    if gesture !== nothing
        if ig.IsMouseDown(gesture.button)
            if gesture.kind == :pan
                reframe!(gesture.axes, zoomed_axes) do axis
                    ntuple(2) do dim
                        dim in gesture.dims || return (0.0, 1.0)
                        moved = fraction(axis, dim, position) - fraction(axis, dim, gesture.last)
                        (-moved, 1 - moved)
                    end
                end
            else
                area = first(gesture.axes).scene.viewport[]
                low, high = area.origin, area.origin .+ area.widths
                ## A rectangle limited to one direction spans the plot area in the other.
                from = ntuple(dim -> dim in free ? gesture.start[dim] : low[dim], 2)
                to = ntuple(dim -> dim in free ? clamp(position[dim], low[dim], high[dim]) : high[dim], 2)
                ig.AddRectFilled(ig.GetWindowDrawList(), to_screen(from), to_screen(to),
                    ig.GetColorU32(ig.ImGuiCol_TextSelectedBg))
            end
            gesture.last = position
            return gesture
        end
        if gesture.kind == :rectangle
            drawn = [dim for dim in free if abs(gesture.last[dim] - gesture.start[dim]) >= MIN_RECTANGLE]
            ## Every direction that is not held to its full span must be drawn.
            if drawn == free
                reframe!(gesture.axes, zoomed_axes) do axis
                    ntuple(2) do dim
                        dim in free || return (0.0, 1.0)
                        ends = clamp.(fraction.(Ref(axis), dim, (gesture.start, gesture.last)), 0, 1)
                        (minimum(ends), maximum(ends))
                    end
                end
            end
        end
        return nothing
    end
    hovered || return nothing

    ## Inside the plot area a gesture acts on every axis there. On the ticks and label of one axis
    ## it acts on that axis, in that direction.
    targets = Makie.Axis[axis for axis in axes if inside(position, axis.scene.viewport[])]
    dims = free
    if isempty(targets)
        found = findfirst(pair -> inside(position, strip(pair...)), [(axis, dim) for axis in axes for dim in 1:2])
        found === nothing && return nothing
        targets, dims = [axes[cld(found, 2)]], [isodd(found) ? 1 : 2]
    end

    steps = unsafe_load(io.MouseWheel)
    if steps != 0
        share = Float64((1 - ZOOM_PER_STEP)^steps)
        reframe!(targets, zoomed_axes) do axis
            ntuple(dim -> dim in dims ? zoomed(fraction(axis, dim, position), share) : (0.0, 1.0), 2)
        end
    end
    ## macOS reports a left click with Ctrl held as a right click.
    control_click = (ig.IsMouseClicked(0) && unsafe_load(io.KeyCtrl)) ||
        (ig.IsMouseClicked(1) && unsafe_load(io.MouseCtrlLeftAsRightClick))
    if control_click
        foreach(Makie.reset_limits!, targets)
        setdiff!(zoomed_axes, targets)
    elseif ig.IsMouseClicked(0)
        kind = length(targets) == 1 && !inside(position, only(targets).scene.viewport[]) ? :pan : :rectangle
        return AxisGesture(kind, 0, targets, dims, position, position)
    elseif ig.IsMouseClicked(1)
        return AxisGesture(:pan, 1, targets, dims, position, position)
    end
    return nothing
end
