# Composition settings operate on Makie's own layout and axis specifications.
# Copy the specifications, not their data, so cached child plots stay reusable.
function _copy_layout(block::Makie.BlockSpec, copies)
    get!(copies, block) do
        copy = Makie.BlockSpec(block.type, Base.copy(block.kwargs), block.plots)
        union!(copy.then_funcs, block.then_funcs)
        copy
    end
end

function _copy_layout(grid::Makie.GridLayoutSpec, copies)
    cells = [position => _copy_layout(child, copies) for (position, child) in grid.content]
    links(groups) = Vector{Makie.BlockSpec}[Makie.BlockSpec[copies[axis] for axis in group] for group in groups]
    S.GridLayout(cells;
        grid.colsizes, grid.rowsizes, grid.colgaps, grid.rowgaps,
        grid.alignmode, grid.tellheight, grid.tellwidth, grid.halign, grid.valign,
        xaxislinks = links(grid.xaxislinks), yaxislinks = links(grid.yaxislinks))
end

# One ordinary panel belongs directly in the parent grid. This lets Makie align
# its plotting area with its neighbours, including their different decorations.
function _panel_content(grid::Makie.GridLayoutSpec)
    if length(grid.content) == 1 && grid.colsizes == [Makie.Auto()] &&
            grid.rowsizes == [Makie.Auto()] && grid.alignmode == Makie.Inside() &&
            grid.tellheight && grid.tellwidth
        position, child = only(grid.content)
        if position == (1:1, 1:1, Makie.GridLayoutBase.Inner()) &&
                child isa Makie.BlockSpec && child.type in (:Axis, :Axis3)
            return child
        end
    end
    grid
end
_panel_content(block) = block

function _layout_axes(block::Makie.BlockSpec)
    block.type === :Axis ? [block] : Makie.BlockSpec[]
end
_layout_axes(grid::Makie.GridLayoutSpec) =
    reduce(vcat, (_layout_axes(child) for (_, child) in grid.content); init = Makie.BlockSpec[])

function _layout_links(grid::Makie.GridLayoutSpec, dimension)
    groups = copy(getproperty(grid, Symbol(dimension, :axislinks)))
    for (_, child) in grid.content
        child isa Makie.GridLayoutSpec || continue
        append!(groups, _layout_links(child, dimension))
    end
    groups
end

function _layout_groups(records, dimension, mode)
    mode === :none && return Vector{typeof(records)}()
    mode === :all && return [records]
    groups = Dict{Int,typeof(records)}()
    for record in records
        indices = dimension === :x ? record.cols : record.rows
        for index in indices
            push!(get!(() -> empty(records), groups, index), record)
        end
    end
    collect(values(groups))
end

function _consistent_layout_axis(records, dimension)
    isempty(records) && return true
    signature(record) = (
        _unobserve(get(record.axis.kwargs, Symbol(dimension, :label), "")),
        _unobserve(get(record.axis.kwargs, Symbol(dimension, :scale), identity)),
    )
    reference = signature(first(records))
    all(record -> isequal(signature(record), reference), records)
end

_overlaps(a, b) = max(first(a), first(b)) <= min(last(a), last(b))

function _outside_neighbour(record, other, dimension, side)
    record.axis === other.axis && return false
    if dimension === :x
        _overlaps(record.cols, other.cols) || return false
        return side === :bottom ? first(other.rows) > last(record.rows) :
                                  last(other.rows) < first(record.rows)
    end
    _overlaps(record.rows, other.rows) || return false
    side === :left ? last(other.cols) < first(record.cols) :
                     first(other.cols) > last(record.cols)
end

function _hide_layout_decorations!(groups, dimension)
    for group in groups, record in group
        side = get(record.axis.kwargs, Symbol(dimension, :axisposition),
                   dimension === :x ? :bottom : :left)
        any(other -> _outside_neighbour(record, other, dimension, side), group) || continue
        for suffix in (:labelvisible, :ticklabelsvisible, :ticksvisible, :minorticksvisible)
            # An explicit per-panel choice takes precedence over automatic hiding.
            get!(record.axis.kwargs, Symbol(dimension, suffix), false)
        end
    end
end

# Labels next to an empty cell can occupy that cell. They must not add a gutter
# to every panel in their row or column. Makie's Mixed alignment does this.
function _labels_in_empty_cells!(records, grid)
    firstrow, firstcol = grid.offsets .+ 1
    lastrow, lastcol = grid.offsets .+ grid.size
    for record in records
        haskey(record.axis.kwargs, :alignmode) && continue
        sides = Pair{Symbol,Any}[]
        for dimension in (:x, :y)
            side = get(record.axis.kwargs, Symbol(dimension, :axisposition),
                       dimension === :x ? :bottom : :left)
            boundary = side === :bottom ? last(record.rows) == lastrow :
                       side === :top ? first(record.rows) == firstrow :
                       side === :left ? first(record.cols) == firstcol :
                                        last(record.cols) == lastcol
            boundary && continue
            any(other -> _outside_neighbour(record, other, dimension, side), records) && continue
            push!(sides, side => Makie.GridLayoutBase.Protrusion(0))
        end
        isempty(sides) || (record.axis.kwargs[:alignmode] = Makie.Mixed(; sides...))
    end
end

function _merge_layout_links(groups)
    merged = Vector{Makie.BlockSpec}[]
    for group in groups
        current = unique(group)
        length(current) < 2 && continue
        for index in reverse(eachindex(merged))
            if any(axis -> axis in merged[index], current)
                append!(current, popat!(merged, index))
            end
        end
        push!(merged, unique(current))
    end
    merged
end

function _layout_spec(original::Makie.GridLayoutSpec, settings)
    isempty(settings) && return original
    settings = _unobserve((; settings...))
    copies = IdDict{Any,Any}()
    grid = _copy_layout(original, copies)
    cells = [position => _panel_content(child) for (position, child) in grid.content]
    records = [(; rows = position[1], cols = position[2], axis)
               for (position, child) in cells for axis in _layout_axes(child)]
    xlinks, ylinks = _layout_links(grid, :x), _layout_links(grid, :y)
    for (dimension, links) in ((:x, xlinks), (:y, ylinks))
        directional = dimension === :x ? :colwise : :rowwise
        directional_groups = _layout_groups(records, dimension, directional)
        mode = normalize_link(get(settings, Symbol(:link, dimension, :axes), :none),
            dimension, _consistent_layout_axis(records, dimension),
            all(group -> _consistent_layout_axis(group, dimension), directional_groups))
        groups = _layout_groups(records, dimension, mode)
        append!(links, [[record.axis for record in group] for group in groups])
        if normalize_hide(get(settings, Symbol(:hide, dimension, :decorations), Makie.automatic), mode, dimension)
            _hide_layout_decorations!(mode === :none ? directional_groups : groups, dimension)
        end
    end
    _labels_in_empty_cells!(records, grid)
    controls = (:linkxaxes, :linkyaxes, :hidexdecorations, :hideydecorations)
    native_value(key, value) = if key in (:rowgaps, :colgaps) && value isa Real
        Makie.Fixed(value)
    elseif key in (:rowsizes, :colsizes) && value isa AbstractVector
        Makie.GridLayoutBase.ContentSize[v isa Real ? Makie.Fixed(v) : v for v in value]
    else
        value
    end
    native = (; (key => native_value(key, value)
                 for (key, value) in pairs(settings) if key ∉ controls)...)
    S.GridLayout(cells;
        grid.colsizes, grid.rowsizes, grid.colgaps, grid.rowgaps,
        grid.alignmode, grid.tellheight, grid.tellwidth, grid.halign, grid.valign,
        xaxislinks = _merge_layout_links(xlinks), yaxislinks = _merge_layout_links(ylinks),
        native...)
end
