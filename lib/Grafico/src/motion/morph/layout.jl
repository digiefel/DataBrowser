# Retain a source panel's measured space in its native grid while its axis moves.
# This passive layout item has no scene or drawing objects. Sibling allocation
# and window resizing therefore continue through GridLayoutBase as usual.
struct _ChartLayoutSpace
    layoutobservables::Makie.GridLayoutBase.LayoutObservables{Makie.GridLayout}
end
function _chart_layout_space(block,content)
    GL = Makie.GridLayoutBase
    layout = block.layoutobservables
    space = _ChartLayoutSpace(GL.LayoutObservables{Makie.GridLayout}(
        Makie.Observable(layout.suggestedbbox[]),Makie.Observable(layout.protrusions[]),
        Makie.Observable(layout.reporteddimensions[]),Makie.Observable(layout.autosize[]),
        Makie.Observable(layout.computedbbox[]),
        Ref{Union{Nothing,GL.GridContent{Makie.GridLayout}}}(content),Ref(false)))
    GL.disconnect_layoutobservables!(content)
    content.content = space
    GL.connect_layoutobservables!(content)
    space
end

# Match panels before changing their layout. SpecAPI supplies the comparison of
# data and attributes; plot kinds distinguish otherwise identical datasets.
function _chart_panel_matches(left, right)
    scores = Dict()
    candidates = Tuple{Float64,Int,Int,Int}[]
    for (i,a) in enumerate(left), (j,b) in enumerate(right)
        a.type === b.type || continue
        kinds = sum(x.type !== y.type for (x,y) in zip(a.plots,b.plots); init=0)
        score = Makie.distance_score(a,b,scores) + kinds
        push!(candidates,(score,abs(i-j),i,j))
    end
    sort!(candidates)
    matches = Dict{Int,Int}()
    used = Set{Int}()
    for (_,_,i,j) in candidates
        (haskey(matches,i) || j in used) && continue
        matches[i] = j
        push!(used,j)
    end
    matches
end

function _chart_outer_box(block)
    layout = block.layoutobservables
    box, protrusions = layout.computedbbox[], layout.protrusions[]
    Makie.Rect2f(box.origin .- (protrusions.left,protrusions.bottom),
        box.widths .+ (protrusions.left+protrusions.right,protrusions.bottom+protrusions.top))
end

# A new panel grows into the space opened by its neighbours. Collapse its outer
# rectangle at the edge it touches (or its centre for an interior panel), then
# preserve Makie's decoration sizes when recovering the data rectangle.
function _chart_collapsed_box(block, bounds)
    outer = _chart_outer_box(block)
    suggested = block.layoutobservables.suggestedbbox[]
    origin, widths = collect(outer.origin), collect(outer.widths)
    for dim in 1:2
        outer.widths[dim] >= .99bounds.widths[dim] && continue
        low, high = bounds.origin[dim], bounds.origin[dim]+bounds.widths[dim]
        origin[dim] = isapprox(outer.origin[dim],low;atol=1) ? low :
            isapprox(outer.origin[dim]+outer.widths[dim],high;atol=1) ? high :
            outer.origin[dim]+outer.widths[dim]/2
        widths[dim] = 0
    end
    Makie.Rect2f(origin .+ (suggested.origin-outer.origin),
                 widths .+ (suggested.widths-outer.widths))
end

# Capture the displayed child before its compilation is replaced. A composed
# child uses its own rectangle, so a morph does not take over sibling panels.
function _inherit_compiled_state!(replacement::_CompiledPlot, current::_CompiledPlot)
    state = replacement.state
    state isa _ChartMorphState || return
    blocks = _node_blocks(current)
    isempty(blocks) && return
    bounds = reduce(union, _chart_outer_box.(blocks))
    state.context = (; bounds)
    nothing
end

function _prepare_chart_panels(source, destination)
    left, right = _chart_blocks(source.specification), _chart_blocks(destination.specification)
    isempty(left) && return nothing
    isempty(right) && return nothing
    source_bounds = reduce(union,_chart_outer_box.(collect(values(source.blocks))))
    target_bounds = reduce(union,_chart_outer_box.(collect(values(destination.blocks))))
    matches = _chart_panel_matches(left,right)
    normalized = Dict{Int,Any}()
    for (i,j) in collect(matches)
        a,b = _normalize_chart_pair(left[i],right[j],source,destination)
        if _chart_block_attributes(a,b)
            normalized[i] = (a,b)
        else
            delete!(matches,i)
        end
    end
    isempty(matches) && return nothing
    source_skeleton = _copy_layout(source.skeleton, IdDict{Any,Any}())
    target_blocks = _chart_blocks(destination.skeleton)
    panels = Any[]
    for (i,a) in enumerate(left)
        start = source.blocks[a].layoutobservables.suggestedbbox[]
        if haskey(matches,i)
            j = matches[i]
            finish = destination.blocks[right[j]].layoutobservables.suggestedbbox[]
            na,nb = normalized[i]
            push!(panels,(; left=na,right=nb,start,finish,opacity=(1.,1.)))
        else
            na,_ = _normalize_chart_pair(a,a,source,source)
            finish = _chart_collapsed_box(source.blocks[a],source_bounds)
            push!(panels,(; left=na,right=na,start,finish,opacity=(1.,0.)))
        end
    end
    occupied = Set(values(matches))
    for (j,b) in enumerate(right)
        j in occupied && continue
        nb,_ = _normalize_chart_pair(b,b,destination,destination)
        finish = destination.blocks[b].layoutobservables.suggestedbbox[]
        start = _chart_collapsed_box(destination.blocks[b],target_bounds)
        push!(panels,(; left=nb,right=nb,start,finish,opacity=(0.,1.)))
        # The animation owns the entering plots. An empty slot keeps SpecAPI
        # from matching this new panel to a sibling showing identical data.
        target = target_blocks[j]
        slot = Makie.BlockSpec(target.type,copy(target.kwargs))
        push!(source_skeleton.content, first(first(source_skeleton.content)) => slot)
    end
    flat(index) = S.GridLayout([(1,i) => getproperty(panel,index) for (i,panel) in enumerate(panels)])
    (; source=flat(:left),destination=flat(:right),skeleton=source_skeleton,
       geometric=true,panels,bounds=source_bounds)
end

function _attach_chart_layout!(state)
    state.prepared.panels === nothing && return
    for (index,(reference,panel)) in enumerate(zip(state.blocks,state.prepared.panels))
        block = reference.value
        layout = block.layoutobservables
        content = layout.gridcontent[]
        content === nothing && continue
        parent = content.parent
        original = layout.suggestedbbox[]
        space = if panel.opacity == (0.,1.)
            Makie.GridLayoutBase.remove_from_gridlayout!(content)
            nothing
        else
            _chart_layout_space(block,content)
        end
        layout.gridcontent[] = nothing
        start = panel.start
        push!(state.placements,(; block,content,parent,original,space,start,finish=panel.finish))
        if panel.opacity != (1.,1.)
            plots = [(plot,plot.alpha[],haskey(plot,:transparency) ? plot.transparency[] : nothing)
                for plot in _chart_scene_roots(block.blockscene) if haskey(plot,:alpha)]
            push!(state.fades,(; plots,opacity=panel.opacity,placement=last(state.placements)))
        end
    end
    for parent in unique([item.parent for item in state.placements if item.parent !== nothing])
        Makie.GridLayoutBase.update!(parent)
    end
    nothing
end

function _chart_space_bounds(space)
    layout = space.layoutobservables
    box,protrusions = layout.suggestedbbox[],layout.protrusions[]
    Makie.Rect2f(box.origin .- (protrusions.left,protrusions.bottom),
        box.widths .+ (protrusions.left+protrusions.right,protrusions.bottom+protrusions.top))
end

function _resize_chart_layout!(state)
    state.disposed && return
    spaces = [item.space for item in state.placements if item.space !== nothing]
    isempty(spaces) && return
    bounds = reduce(union,_chart_space_bounds.(spaces))
    previous = state.context === nothing ? state.prepared.bounds : state.context.bounds
    same_origin = isapprox(bounds.origin, previous.origin; atol=0.01)
    same_size = isapprox(bounds.widths, previous.widths; atol=0.01)
    same_origin && same_size && return
    node = state.node.value
    node === nothing && return
    figure = node.figure.value
    figure === nothing && return
    state.context = (;bounds)
    delete!(state.transition.prepared,node)
    state.prepared = _prepare_chart!(state.transition,figure,state.arguments...;
        _context=node,_bounds=bounds,state.options...)
    for (i,panel) in enumerate(state.prepared.panels)
        state.placements[i] = merge(state.placements[i],(;start=panel.start,finish=panel.finish))
    end
    for (i,fade) in enumerate(state.fades)
        index = findfirst(item -> item.block === fade.placement.block,state.placements)
        state.fades[i] = merge(fade,(;placement=state.placements[index]))
    end
    nothing
end

function _chart_panel_geometry(start,finish,u)
    box = _chart_mix_geometry(start,finish,u)
    padding = max.(1,-min.(start.widths,finish.widths))
    fits = clamp(minimum(box.widths ./ padding),0,1)
    Makie.Rect2f(box.origin,max.(1,box.widths)),fits
end

function _render_chart_layout!(state)
    u = state.progress
    for placement in state.placements
        box,_ = _chart_panel_geometry(placement.start,placement.finish,u)
        placement.block.layoutobservables.suggestedbbox[] = box
    end
    for fade in state.fades
        _,fits = _chart_panel_geometry(fade.placement.start,fade.placement.finish,u)
        opacity = _motion_mix(fade.opacity...,u)*fits
        for (plot,alpha,transparency) in fade.plots
            values = transparency === nothing ? (; alpha=alpha*opacity) :
                (; alpha=alpha*opacity,transparency=opacity<1 || transparency)
            Makie.update!(plot;values...)
        end
    end
    nothing
end

function _restore_chart_layout!(state)
    for placement in state.placements
        placement.block.blockscene.isclosed && continue
        layout = placement.block.layoutobservables
        Makie.GridLayoutBase.disconnect_layoutobservables!(placement.content)
        placement.content.content = placement.block
        layout.gridcontent[] = placement.content
        Makie.GridLayoutBase.connect_layoutobservables!(placement.content)
        if placement.space !== nothing
            placement.space.layoutobservables.gridcontent[] = nothing
        elseif placement.parent !== nothing
            blocked = placement.parent.block_updates
            placement.parent.block_updates = true
            Makie.GridLayoutBase.add_to_gridlayout!(placement.parent,placement.content)
            placement.parent.block_updates = blocked
        end
        layout.suggestedbbox[] = placement.original
    end
    for fade in state.fades, (plot,alpha,transparency) in fade.plots
        Makie.parent_scene(plot).isclosed && continue
        values = transparency === nothing ? (; alpha) : (; alpha,transparency)
        Makie.update!(plot;values...)
    end
    empty!(state.placements); empty!(state.fades)
    nothing
end

# SpecAPI assigns grid cells again when any child publishes a new specification.
# Give it back the native blocks before the update, then reapply the active
# morph. Retain the animated plots when SpecAPI keeps the same blocks.
function _with_chart_layouts(update, reusable)
    active = IdDict{_ChartMorphState,Vector{Any}}()
    for (key, _) in reusable
        spec = last(key)
        spec isa Makie.BlockSpec || continue
        for callback in spec.then_funcs
            callback isa _RememberChartBlock || continue
            state = callback.state.value
            state === nothing && continue
            isempty(state.placements) && continue
            get!(active, state) do
                [reference.value for reference in state.blocks]
            end
        end
    end
    isempty(active) && return update()

    for state in keys(active)
        _restore_chart_layout!(state)
        fill!(state.blocks, WeakRef(nothing))
    end
    try
        update()
    finally
        for (state, previous) in active
            node = state.node.value
            (node === nothing || state.disposed) && continue
            if all(reference.value === block for (reference, block) in zip(state.blocks, previous))
                _attach_chart_layout!(state)
            else
                _release_chart_rendering!(state)
            end
            _resize_chart_layout!(state)
            _render_compiled_state!(node, state)
        end
    end
end
