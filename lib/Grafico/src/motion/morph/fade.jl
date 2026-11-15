# A native layout wrapper gives any Makie block the same opacity transition.
# All data, decorations, and text remain ordinary Makie plots.
@eval _NativeGraphics begin
    Makie.@Block _GraficoChartFade begin
        grid::Makie.GridLayout
        layouts::Any
        originals::Vector{Any}
        @attributes begin
            specification = S.GridLayout(Pair[])
            opacity = 1.0
        end
    end
end

const _GraficoChartFade = _NativeGraphics._GraficoChartFade

function _chart_scene_roots(scene)
    roots = Any[scene.plots...]
    for child in scene.children
        append!(roots, _chart_scene_roots(child))
    end
    roots
end

function _chart_opacity!(frame)
    for (plot, alpha, transparency) in frame.originals
        values = (; alpha = alpha * frame.opacity[])
        if transparency !== nothing
            values = merge(values, (; transparency = frame.opacity[] < 1 || transparency))
        end
        Makie.update!(plot; values...)
    end
    nothing
end

function Makie.initialize_block!(frame::_GraficoChartFade)
    frame.originals = Any[]
    frame.grid = Makie.GridLayout(; bbox = frame.layoutobservables.computedbbox,
                                  alignmode = Makie.Outside())
    frame.grid.parent = frame.blockscene
    entries = Pair{Makie.LayoutableKey,Tuple{Makie.Layoutable,Makie.Observable{Vector{Makie.PlotSpec}}}}[]
    frame.layouts = (entries, copy(entries))
    Makie.on(frame.blockscene, frame.specification; update = true) do specification
        # Restore before SpecAPI reuses a plot, so opacity never compounds.
        for (plot, alpha, transparency) in frame.originals
            Makie.parent_scene(plot).isclosed && continue
            values = transparency === nothing ? (; alpha) : (; alpha, transparency)
            Makie.update!(plot; values...)
        end
        empty!(frame.originals)
        wrapped = S.GridLayout([(1, 1) => specification]; alignmode = Makie.Outside())
        _update_native_layout!(frame.grid, wrapped, frame.layouts...)
        for plot in _chart_scene_roots(frame.blockscene)
            haskey(plot, :alpha) || continue
            alpha = plot.alpha[]
            transparency = haskey(plot, :transparency) ? plot.transparency[] : nothing
            push!(frame.originals, (plot, alpha, transparency))
        end
        _chart_opacity!(frame)
    end
    Makie.on(_ -> _chart_opacity!(frame), frame.blockscene, frame.opacity)
    nothing
end

function Makie.free(frame::_GraficoChartFade)
    isdefined(frame, :layouts) || return
    for (key, (block, _)) in first(frame.layouts)
        specification = last(key)
        if specification isa Makie.BlockSpec
            foreach(Makie.off, specification.then_observers)
            empty!(specification.then_observers)
        end
        block isa Makie.Block && delete!(block)
    end
    foreach(empty!, frame.layouts)
    empty!(frame.originals)
    nothing
end

function _chart_fade_layout(source, destination, u)
    blocks = [Makie.BlockSpec(:_GraficoChartFade; specification,
              opacity, tellwidth = false, tellheight = false)
              for (specification, opacity) in ((source, 1-u), (destination, u))]
    S.GridLayout([(1, 1) => block for block in blocks])
end
