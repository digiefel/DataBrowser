# Native rectangular chart frames. Native GridLayout owns text measurements,
# protrusions and axis layout; this block supplies a reactive outer rectangle.
module _NativeGraphics
using Makie
using ..Grafico: MarkTransform
import Makie.SpecApi as S
import Makie: make_block_docstring

Makie.@Block _GraficoPlotFrame begin
    grid::Makie.GridLayout
    layouts::Any
    bindings::Dict{Symbol,Makie.ObserverFunction}
    compilation::Any
    @attributes begin
        specification = S.GridLayout(Pair[])
        placement = MarkTransform()
        reference = nothing
        depth = 500.0
        backdrop = true
    end
end

end # module _NativeGraphics

const _GraficoPlotFrame = _NativeGraphics._GraficoPlotFrame

function _frame_rectangle(placement, box)
    iszero(placement.b) && iszero(placement.c) && placement.a > 0 && placement.d > 0 ||
        throw(ArgumentError("Complete chart placement supports positive rectangular translation and resizing; rotation and reflection need a different rendering backend."))
    isempty(placement.style) || throw(ArgumentError("Apply chart appearance with plot_theme or visual; a chart placement has no Style attributes."))
    Makie.Rect2f(box.origin .+ box.widths .* (placement.tx, placement.ty),
                box.widths .* (placement.a, placement.d))
end

function _check_chart_axes(specification::Makie.GridLayoutSpec)
    for (_, child) in specification.content
        if child isa Makie.GridLayoutSpec
            _check_chart_axes(child)
        elseif child.type in (:Axis3, :LScene)
            throw(ArgumentError("Complete chart placement currently supports 2D layouts; 3D scenes retain their ordinary Makie recording support."))
        end
    end
    specification
end

function Makie.initialize_block!(frame::_GraficoPlotFrame)
    frame.bindings = Dict{Symbol,Makie.ObserverFunction}()
    frame.compilation = nothing
    bbox = Makie.lift(frame.blockscene, frame.placement, frame.reference,
                      frame.layoutobservables.computedbbox) do placement, reference, box
        _frame_rectangle(placement, something(reference, box))
    end
    frame.grid = Makie.GridLayout(; bbox, alignmode = Makie.Outside())
    frame.grid.parent = frame.blockscene
    if frame.backdrop[]
        background = Makie.root(Makie.get_scene(frame.parent)).backgroundcolor
        visible = Makie.lift(frame.blockscene, frame.specification) do specification
            !isempty(specification.content)
        end
        panel = Makie.poly!(frame.blockscene, bbox; color = background, visible,
                            strokewidth = 0, inspectable = false)
        Makie.translate!(panel, 0, 0, -200)
    end
    Makie.on(frame.blockscene, frame.depth; update = true) do depth
        Makie.translate!(frame.blockscene, 0, 0, depth)
    end
    entries = Pair{Makie.LayoutableKey,Tuple{Makie.Layoutable,Makie.Observable{Vector{Makie.PlotSpec}}}}[]
    frame.layouts = (entries, copy(entries))
    Makie.on(frame.blockscene, frame.specification; update = true) do specification
        _check_chart_axes(specification)
        wrapped = S.GridLayout([(1, 1) => specification]; alignmode = Makie.Outside())
        _update_native_layout!(frame.grid, wrapped, frame.layouts...)
    end
    return
end

function Makie.free(frame::_GraficoPlotFrame)
    if isdefined(frame, :compilation) && frame.compilation !== nothing
        _dispose!(frame.compilation)
        frame.compilation = nothing
    end
    if isdefined(frame, :bindings)
        foreach(Makie.off, values(frame.bindings))
        empty!(frame.bindings)
    end
    isdefined(frame, :layouts) || return
    for (key, (layoutable, _)) in first(frame.layouts)
        specification = last(key)
        if specification isa Makie.BlockSpec
            foreach(Makie.off, specification.then_observers)
            empty!(specification.then_observers)
        end
        layoutable isa Makie.Block && delete!(layoutable)
    end
    foreach(empty!, frame.layouts)
    return
end

struct _FrameBinding{O} <: Function
    key::Symbol
    source::O
end

function (binding::_FrameBinding)(frame)
    haskey(frame.bindings, binding.key) && Makie.off(frame.bindings[binding.key])
    observer = Makie.on(binding.source; update = true) do value
        setproperty!(frame, binding.key, value)
    end
    frame.bindings[binding.key] = observer
    observer
end

function _frame_spec(specification, placement, order; backdrop = true, reference = nothing, compilation = nothing)
    initial = _check_chart_axes(_unobserve(specification))
    _frame_rectangle(_unobserve(placement), Makie.Rect2f(0, 0, 1, 1))
    block = Makie.BlockSpec(:_GraficoPlotFrame; specification = initial,
        placement = _unobserve(placement), reference = _unobserve(reference),
        depth = 500.0 * order, backdrop, tellwidth = false, tellheight = false)
    for (key, source) in ((:specification, specification), (:placement, placement), (:reference, reference))
        source isa Makie.Observable && block.then(_FrameBinding(key, source))
    end
    if compilation !== nothing
        block.then(frame -> (frame.compilation = compilation; nothing))
    end
    block
end

function _host_spec(specification, reference)
    copied = _copy_layout(specification, IdDict{Any,Any}())
    axes = _layout_axes(copied)
    isempty(axes) && return copied
    bounds = Makie.Observable{Any}[Makie.Observable{Any}(nothing) for _ in axes]
    for (axis_spec, bound) in zip(axes, bounds), property in (:computedbbox, :protrusions)
        axis_spec.then() do axis
            Makie.on(getproperty(axis.layoutobservables, property); update = true) do _
                box = axis.layoutobservables.computedbbox[]
                protrusions = axis.layoutobservables.protrusions[]
                origin = box.origin .- (protrusions.left, protrusions.bottom)
                widths = box.widths .+ (protrusions.left + protrusions.right,
                                       protrusions.top + protrusions.bottom)
                bound[] = Makie.Rect2f(origin, widths)
                current = filter(!isnothing, getindex.(bounds))
                reference[] = reduce(union, current)
            end
        end
    end
    copied
end
