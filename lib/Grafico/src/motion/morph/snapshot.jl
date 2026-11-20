# `spec` has no live compilation to place native panels after the layout diff.
# A snapshot therefore owns that layout and applies the same sampled rectangles.
@eval _NativeGraphics begin
    Makie.@Block _GraficoChartSnapshot begin
        grid::Makie.GridLayout
        layouts::Any
        blocks::Vector{Any}
        @attributes begin
            specification = S.GridLayout(Pair[])
            rectangles = Makie.Rect2f[]
            opacities = Float64[]
            reference = Makie.Rect2f(0,0,1,1)
        end
    end
end
const _GraficoChartSnapshot = _NativeGraphics._GraficoChartSnapshot

function Makie.initialize_block!(frame::_GraficoChartSnapshot)
    frame.blocks = Any[]
    frame.grid = Makie.GridLayout(; bbox=frame.layoutobservables.computedbbox,
                                  alignmode=Makie.Outside())
    frame.grid.parent = frame.blockscene
    entries = Pair{Makie.LayoutableKey,Tuple{Makie.Layoutable,Makie.Observable{Vector{Makie.PlotSpec}}}}[]
    frame.layouts = (entries,copy(entries))
    specification = _copy_layout(frame.specification[],IdDict{Any,Any}())
    for block in _chart_blocks(specification)
        block.then(native -> (push!(frame.blocks,native);nothing))
    end
    _update_native_layout!(frame.grid,specification,frame.layouts...)
    for (block,opacity) in zip(frame.blocks,frame.opacities[])
        layout = block.layoutobservables
        Makie.GridLayoutBase.remove_from_gridlayout!(layout.gridcontent[])
        layout.gridcontent[] = nothing
        for plot in _chart_scene_roots(block.blockscene)
            haskey(plot,:alpha) || continue
            values = haskey(plot,:transparency) ?
                (;alpha=plot.alpha[]*opacity,transparency=opacity<1 || plot.transparency[]) :
                (;alpha=plot.alpha[]*opacity)
            Makie.update!(plot;values...)
        end
    end
    Makie.on(frame.blockscene,frame.layoutobservables.computedbbox;update=true) do bounds
        reference = frame.reference[]
        scale = bounds.widths ./ reference.widths
        for (block,rectangle) in zip(frame.blocks,frame.rectangles[])
            origin = bounds.origin .+ scale .* (rectangle.origin-reference.origin)
            widths = max.(1,scale .* rectangle.widths)
            block.layoutobservables.suggestedbbox[] = Makie.Rect2f(origin,widths)
        end
    end
    nothing
end

function Makie.free(frame::_GraficoChartSnapshot)
    isdefined(frame,:layouts) || return
    for (key,(block,_)) in first(frame.layouts)
        specification = last(key)
        if specification isa Makie.BlockSpec
            foreach(Makie.off,specification.then_observers)
            empty!(specification.then_observers)
        end
        block isa Makie.Block && delete!(block)
    end
    foreach(empty!,frame.layouts)
    empty!(frame.blocks)
    nothing
end

function _chart_specification(prepared,u)
    if prepared.panels === nothing
        return prepared.geometric ? _blend_chart(prepared.source,prepared.destination,u) :
            _chart_fade_layout(prepared.source,prepared.destination,u)
    end
    rectangles,opacities = Makie.Rect2f[],Float64[]
    for panel in prepared.panels
        rectangle,fits = _chart_panel_geometry(panel.start,panel.finish,u)
        push!(rectangles,rectangle)
        push!(opacities,_motion_mix(panel.opacity...,u)*fits)
    end
    specification = _blend_chart(prepared.source,prepared.destination,u)
    block = Makie.BlockSpec(:_GraficoChartSnapshot; specification,rectangles,opacities,
                            reference=prepared.bounds,tellwidth=false,tellheight=false)
    S.GridLayout([(1,1)=>block])
end
