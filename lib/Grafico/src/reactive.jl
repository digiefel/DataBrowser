# Observable inputs remain ordinary Observables. Compilation is scoped to a
# panel; display attributes are passed to Makie without recompiling analyses.

_hasobs(x) = false
_hasobs(::Makie.Observable) = true
_hasobs(x::Tuple) = any(_hasobs, x)
_hasobs(x::NamedTuple) = any(_hasobs, values(x))
_hasobs(x::Pair) = _hasobs(first(x)) || _hasobs(last(x))
_hasobs(x::PlotLines) = any(line -> _hasobs(line.layers), x.lines)
_hasobs(x::YScaleLayers) = any(p -> _hasobs(last(p)), x.layers)
_hasobs(x::Scaled) = _hasobs(x.layers) || any(step -> haskey(step,:points) && _hasobs(step.points),x.coords)

_unobserve(x) = x
_unobserve(x::Makie.Observable) = _unobserve(x[])
_unobserve(x::Tuple) = map(_unobserve, x)
_unobserve(x::NamedTuple) = map(_unobserve, x)
_unobserve(x::Pair) = _unobserve(first(x)) => _unobserve(last(x))

_sources!(out, x) = out
function _sources!(out, x::Makie.Observable)
    any(y -> y === x, out) || push!(out, x)
    out
end
function _sources!(out, x::Union{Tuple,NamedTuple})
    foreach(v -> _sources!(out, v), x)
    out
end
_sources!(out, x::Pair) = (_sources!(out, first(x)); _sources!(out, last(x)); out)
_sources!(out, x::PlotLines) = (foreach(line -> _sources!(out, line.layers), x.lines); out)
_sources!(out, x::YScaleLayers) = (foreach(p -> _sources!(out,last(p)),x.layers); out)
function _sources!(out,x::Scaled)
    _sources!(out,x.layers)
    foreach(step -> haskey(step,:points) && _sources!(out,step.points),x.coords)
    out
end
_sources(x) = _sources!(Makie.Observable[], x)

# Keep the operation and its operands, rather than closing over Observable
# containers and reading them again in the callback. Besides avoiding hidden
# reads, this lets exporters stage the existing grammar without a second AST.
struct _ReactiveReference
    index::Int
end

_reactive_template(x, sources) = x
_reactive_template(x::Makie.Observable, sources) =
    _ReactiveReference(only(findall(source -> source === x, sources)))
_reactive_template(x::Union{Tuple,NamedTuple}, sources) =
    map(value -> _reactive_template(value, sources), x)
_reactive_template(x::Pair, sources) =
    _reactive_template(first(x), sources) => _reactive_template(last(x), sources)

_reactive_value(x, values) = x
_reactive_value(x::_ReactiveReference, values) = values[x.index]
_reactive_value(x::Union{Tuple,NamedTuple}, values) =
    map(value -> _reactive_value(value, values), x)
_reactive_value(x::Pair, values) =
    _reactive_value(first(x), values) => _reactive_value(last(x), values)

struct _ReactiveCall{F,A,K}
    operation::F
    positional::A
    named::K
end

function (call::_ReactiveCall)(values...)
    call.operation(_reactive_value(call.positional, values)...;
                   _reactive_value(call.named, values)...)
end

function _lift_call(f, args...; kwargs...)
    named = (; kwargs...)
    sources = _sources((args, named))
    isempty(sources) && return f(args...; kwargs...)
    call = _ReactiveCall(f, _reactive_template(args, sources),
                        _reactive_template(named, sources))
    Makie.lift(call, sources...)
end

data(x::Makie.Observable) = Makie.lift(data,x)

const ObservablePlot = Makie.Observable{<:ComposablePlot}
const ReactiveOperand = Union{PlotSpecObject,PlotModifier,Fit,Aggregate}
(header::ObservablePlot)(items...) = _lift_call((value,lines...) -> value(lines...),header,items...)

for op in (:+, :*)
    @eval begin
        Base.$op(a::ObservablePlot,b::ObservablePlot) = Makie.lift(Base.$op,a,b)
        Base.$op(a::ObservablePlot,b::ReactiveOperand) = _lift_call(Base.$op,a,b)
        Base.$op(a::ReactiveOperand,b::ObservablePlot) = _lift_call(Base.$op,a,b)
    end
end

resolve(x::ObservablePlot,items,axes,points=nothing) =
    _lift_call(resolve,x,items,axes,points)
inherit(a::ObservablePlot,b::ObservablePlot) = Makie.lift(inherit,a,b)
inherit(a::ObservablePlot,b) = _lift_call(inherit,a,b)
inherit(a::Layer,b::ObservablePlot) = _lift_call(inherit,a,b)

_snapshot(x) = x
_snapshot(x::Makie.Observable) = _snapshot(x[])
_snapshot(x::PlotLines) = PlotLines([PlotLine(_snapshot(line.layers),line.shared,line.drawn) for line in x.lines], x.document)
_snapshot(x::YScaleLayers) = YScaleLayers([role => _snapshot(layer) for (role,layer) in x.layers])
_snapshot(x::Scaled) = Scaled(_snapshot(x.layers),x.scales,x.texts,x.legend,x.theme,
    NamedTuple[(; (key => (key === :points ? _unobserve(value) : value) for (key,value) in pairs(step))...) for step in x.coords],
    x.inspector, x.document)

spec(x::Makie.Observable,args...;kwargs...) = spec(_snapshot(x),args...;kwargs...)
spec(x::Makie.GridLayoutSpec,args...;kwargs...) = x

_semantic_visual(kwargs) = any(key -> haskey(kwargs,key) && _hasobs(kwargs[key]),(:direction,:orientation))
function _reactive_visual(f,kwargs)
    named=(;kwargs...)
    sources=_sources((get(named,:direction,nothing),get(named,:orientation,nothing)))
    Makie.lift(sources...) do _...
        f(; (key => (key in (:direction,:orientation) ? _unobserve(value) : value) for (key,value) in pairs(named))...)
    end
end
visual(type::Makie.Observable;kwargs...) = Makie.lift(t -> visual(t;kwargs...),type)

# SpecApi's diff updater accepts values, not new Observable inputs. A private
# Makie recipe keeps those connections on the native child across data updates.
Makie.@recipe_internal LiveEntry (entry,) begin
    inspector_label = Makie.automatic
    inspectable = true
end

Makie.convert_arguments(::Type{<:LiveEntry},entry::Entry) = (entry,)

function _same_entry_inputs(a::Entry,b::Entry)
    a.plottype === b.plottype || return false
    length(a.positional) == length(b.positional) || return false
    all(typeof(x) === typeof(y) for (x,y) in zip(a.positional,b.positional)) || return false
    Set(keys(a.named)) == Set(keys(b.named)) || return false
    all(keys(a.named)) do key
        x,y=a.named[key],b.named[key]
        (x isa Makie.Observable || y isa Makie.Observable) ? x === y : typeof(x) === typeof(y)
    end
end

function Makie.plot!(wrapper::LiveEntry)
    child=Ref{Any}(nothing)
    previous=Ref{Union{Nothing,Entry}}(nothing)
    source=Makie.ComputePipeline.get_observable!(wrapper.entry;use_deepcopy=false)
    Makie.on(wrapper,source;update=true) do entry
        if previous[] !== nothing && _same_entry_inputs(previous[],entry)
            attributes=(key=>value for (key,value) in pairs(entry.named) if !(value isa Makie.Observable))
            Makie.update!(child[],entry.positional...;attributes...)
        else
            if child[] !== nothing
                Makie.delete!(Makie.parent_scene(wrapper),child[])
                filter!(p -> p !== child[],wrapper.plots)
            end
            native=entry.plottype(Tuple(entry.positional),Dict{Symbol,Any}(pairs(entry.named)))
            c = Makie.plot!(wrapper,native)
            lbl = wrapper.inspector_label[]
            lbl === Makie.automatic || (c.inspector_label = lbl)
            c.inspectable = wrapper.inspectable[]
            child[] = c
        end
        previous[]=entry
    end
    insp_obs = Makie.ComputePipeline.get_observable!(wrapper.inspector_label; use_deepcopy=false)
    Makie.on(wrapper, insp_obs) do fn
        fn === Makie.automatic && return
        c = child[]
        c === nothing || (c.inspector_label = fn)
    end
    vis_obs = Makie.ComputePipeline.get_observable!(wrapper.inspectable; use_deepcopy=false)
    Makie.on(wrapper, vis_obs) do flag
        c = child[]
        c === nothing || (c.inspectable = flag)
    end
    wrapper
end

_entry_argument(value) = value

function _entry_spec(entry)
    entry = Entry(entry.plottype, map(_entry_argument, entry.positional),
                  map(_entry_argument, entry.named))
    if any(value -> value isa Makie.Observable,values(entry.named))
        Makie.PlotSpec(LiveEntry,entry)
    else
        Makie.PlotSpec(entry.plottype,entry.positional...;pairs(entry.named)...)
    end
end

# Keep the source of each axis connection inspectable. SpecApi owns observer
# replacement and cleanup; exporters can identify axis effects explicitly.
struct _AxisBinding{O} <: Function
    key::Symbol
    source::O
end
function (binding::_AxisBinding)(axis)
    Makie.on(binding.source; update = true) do value
        setproperty!(axis, binding.key, value)
    end
end

function _axis_obs(value)
    value isa Makie.Observable && return value
    sources = _sources(value)
    template = _reactive_template(value, sources)
    out = Makie.Observable{Any}(_unobserve(value))
    Makie.onany(sources...) do vals...
        out[] = _reactive_value(template, vals)
    end
    return out
end

# Coordinate display settings may contain Observables inside a tuple of limits.
function _axis_spec(axis,plots)
    attributes = (;pairs(axis.attributes)...)
    block = axis.type === Axis3 ? S.Axis3(;plots,_unobserve(attributes)...) :
                                 S.Axis(;plots,_unobserve(attributes)...)
    for (key, value) in pairs(attributes)
        _hasobs(value) || continue
        block.then(_AxisBinding(key, _axis_obs(value)))
    end
    block
end

# Makie keeps disconnected blocks for reuse, but removes them from Figure.content.
# Register reused blocks again so the returned Figure describes its visible panels.
function _restore_block!(block)
    block.parent isa Figure && Makie.register_in_figure!(block.parent,block)
    nothing
end
function _restore_blocks!(grid::Makie.GridLayoutSpec)
    for (_,child) in grid.content
        child isa Makie.BlockSpec ? child.then(_restore_block!) : _restore_blocks!(child)
    end
    grid
end

mutable struct _CompiledPlot
    specification::Makie.Observable{Makie.GridLayoutSpec}
    observers::Vector{Makie.ObserverFunction}
    children::Vector{_CompiledPlot}
    forwarding::Vector{Makie.ObserverFunction}
    declaration::Any
    axes::Vector{WeakRef}
    blocks::Vector{WeakRef}
    figure::WeakRef
    state::Any
end

function _CompiledPlot(specification; declaration = nothing, state = nothing)
    node = _CompiledPlot(Makie.Observable{Makie.GridLayoutSpec}(specification),
        Makie.ObserverFunction[], _CompiledPlot[], Makie.ObserverFunction[],
        declaration, WeakRef[], WeakRef[], WeakRef(nothing), state)
    finalizer(_finalize_compilation!,node)
    node
end

_dispose_state!(::Nothing) = nothing

# Scene mutation belongs to explicit replacement while the figure is alive.
# Native Makie scenes release their own resources. In particular, a finalizer
# must not relayout text after FreeType has finalized its fonts at process exit.
function _finalize_compilation!(node::_CompiledPlot)
    foreach(Makie.off,node.observers)
    foreach(Makie.off,node.forwarding)
    empty!(node.observers); empty!(node.forwarding)
    nothing
end

function _dispose!(node::_CompiledPlot)
    _dispose_state!(node.state)
    node.state = nothing
    foreach(Makie.off,node.observers)
    foreach(Makie.off,node.forwarding)
    foreach(_dispose!,node.children)
    empty!(node.observers); empty!(node.forwarding); empty!(node.children)
    nothing
end

_inherit_compiled_state!(replacement, current) = nothing

_compile_plot(plot,args...;kwargs...) = _compile_plain_plot(plot,args...;kwargs...)

function _compile_plain_plot(plot,args...;kwargs...)
    node = _CompiledPlot(_restore_blocks!(spec(_snapshot(plot),_unobserve(args)...;kwargs...)); declaration = plot)
    _remember_axes!(node, node.specification[])
    weak = WeakRef(node)
    for source in _sources(plot isa Declaration ? (plot,args) : plot)
        push!(node.observers,Makie.on(source) do _
            current=weak.value
            current === nothing && return
            current.specification[] = _remember_axes!(current,
                _restore_blocks!(spec(_snapshot(plot),_unobserve(args)...;kwargs...)))
        end)
    end
    node
end

function _compile_plot(source::Makie.Observable,args...;kwargs...)
    child = _compile_plot(source[],args...;kwargs...)
    node = _CompiledPlot(child.specification[]; declaration = source)
    weak = WeakRef(node)
    push!(node.children,child)
    forward(child) = Makie.on(child.specification) do value
        current=weak.value
        current === nothing || (current.specification[]=value)
    end
    push!(node.forwarding,forward(child))
    push!(node.observers,Makie.on(source) do value
        current=weak.value
        current === nothing && return
        if length(current.children) == 1 && _update_compiled_state!(only(current.children), value)
            return
        end
        replacement = _compile_plot(value,args...;kwargs...)
        _inherit_compiled_state!(replacement, current)
        foreach(Makie.off,current.forwarding)
        foreach(_dispose!,current.children)
        _set_figure!(replacement, current.figure.value)
        current.children = [replacement]
        current.forwarding = [forward(replacement)]
        current.specification[] = replacement.specification[]
        _render_compilation!(replacement)
    end)
    node
end

function _compile_plot(composed::ComposedFigure,args...;layout=(;),kwargs...)
    children = [_compile_plot(child,args...;kwargs...) for (_,child) in composed.cells]
    function assemble(nodes, changed = nothing)
        # Reserve unchanged native panels before SpecAPI matches a changing
        # child's new panels. Otherwise an identical new plot can take a sibling's
        # axis from the shared reuse cache.
        order = changed === nothing ? collect(eachindex(nodes)) :
            [filter(i -> i != changed,collect(eachindex(nodes))); changed]
        _layout_spec(S.GridLayout([first(composed.cells[i]) => nodes[i].specification[]
                                  for i in order]),layout)
    end
    node = _CompiledPlot(assemble(children); declaration = composed)
    node.children=children
    weak=WeakRef(node)
    for source in _sources(layout)
        push!(node.observers, Makie.on(source) do _
            current = weak.value
            current === nothing || (current.specification[] = assemble(current.children))
        end)
    end
    for (index,child) in enumerate(children)
        push!(node.forwarding,Makie.on(child.specification) do _
            current=weak.value
            current === nothing || (current.specification[]=assemble(current.children,index))
        end)
    end
    node
end

# SpecAPI retains unused grids for reuse. Detach those owned grids before it
# shrinks their parent; stale column spans otherwise break reverse layout seeks.
function _update_native_layout!(layout, specification, reusable, current)
    _with_chart_layouts(reusable) do
        for (_, (child, _)) in reusable
            child isa Makie.GridLayout || continue
            content = child.layoutobservables.gridcontent[]
            (content === nothing || content.parent === nothing) && continue
            content.parent.block_updates = true
            Makie.GridLayoutBase.remove_from_gridlayout!(content)
        end
        Makie.update_gridlayout!(layout, specification, reusable, current)
        for ((_, _, child_spec), (block, _)) in current
            child_spec isa Makie.BlockSpec || continue
            (block isa Axis || block isa Axis3) || continue
            for fn in child_spec.then_funcs
                fn isa _InspectorHook && fn(block)
            end
        end
    end
end

function _connect_native_layout!(figure, specification)
    entries = Pair{Makie.LayoutableKey,Tuple{Makie.Layoutable,Makie.Observable{Vector{Makie.PlotSpec}}}}[]
    current = copy(entries)
    layout = Makie.get_layout!(figure[1, 1])
    Makie.on(figure.scene, specification; update = true) do value
        _update_native_layout!(layout, value, entries, current)
    end
    nothing
end

function _reactive_figure(plot,args...;figure_kw=(;),figure=(;),kwargs...)
    contents = Makie.Observable{Any}(plot)
    compiled = _compile_plot(contents,args...;kwargs...)
    fig = Figure(;figure...,figure_kw...)
    fig.attributes[:_grafico_compilation] = compiled
    _set_figure!(compiled, fig)
    _connect_native_layout!(fig, compiled.specification)
    _render_compilation!(compiled)
    # Keep the compilation with its output; input observers hold only WeakRefs.
    # Dropping the figure then allows the entire graph and its observers to die.
    Makie.on(compiled.specification) do _
        GC.@preserve compiled nothing
    end
    fig
end

_axis_reactive(plot::Scaled) = any(step -> any(_hasobs,values(step)),plot.coords)

const ReactiveComposable = Union{ComposablePlot,ObservablePlot}
Base.hcat(plots::ReactiveComposable...) = ComposedFigure([(1,j)=>p for (j,p) in enumerate(plots)])
Base.vcat(plots::ReactiveComposable...) = ComposedFigure([(i,1)=>p for (i,p) in enumerate(plots)])
function Base.hvcat(rows::Tuple{Vararg{Int}},plots::ReactiveComposable...)
    cells=Pair{Tuple{Int,Int},Any}[]
    index=1
    for (row,ncols) in enumerate(rows), col in 1:ncols
        push!(cells,(row,col)=>plots[index]); index+=1
    end
    ComposedFigure(cells)
end
Base.:|(a::Union{ComposablePlot,Makie.Observable},b::Union{ComposablePlot,Makie.Observable}) =
    ComposedFigure([(1,1)=>a,(1,2)=>b])
Base.:/(a::Union{ComposablePlot,Makie.Observable},b::Union{ComposablePlot,Makie.Observable}) =
    ComposedFigure([(1,1)=>a,(2,1)=>b])
Base.:|(a::Union{ComposablePlot,Makie.Observable},::Nothing) = ComposedFigure([(1,1)=>a,(1,2)=>nothing])
Base.:|(::Nothing,b::Union{ComposablePlot,Makie.Observable}) = ComposedFigure([(1,1)=>nothing,(1,2)=>b])
Base.:/(a::Union{ComposablePlot,Makie.Observable},::Nothing) = ComposedFigure([(1,1)=>a,(2,1)=>nothing])
Base.:/(::Nothing,b::Union{ComposablePlot,Makie.Observable}) = ComposedFigure([(1,1)=>nothing,(2,1)=>b])

function _grid(matrix::AbstractMatrix)
    all(x -> x === nothing || x isa Union{ComposablePlot,Makie.Observable},matrix) ||
        throw(ArgumentError("A Grafico grid contains plot declarations, Observables, or nothing."))
    ComposedFigure(vec([Tuple(i)=>matrix[i] for i in CartesianIndices(matrix)]))
end

child_spec(::Nothing,args...;kwargs...) = S.GridLayout(Pair{Tuple{Int,Int},Any}[];tellwidth=false,tellheight=false)
child_spec(x::Makie.Observable,args...;kwargs...) = child_spec(x[],args...;kwargs...)
spec(::Nothing,args...;kwargs...) = child_spec(nothing)
spec(matrix::AbstractMatrix,args...;kwargs...) = spec(_grid(matrix),args...;kwargs...)
figure(matrix::AbstractMatrix,args...;kwargs...) = _reactive_figure(_grid(matrix),args...;kwargs...)
_compile_plot(matrix::AbstractMatrix,args...;kwargs...) = _compile_plot(_grid(matrix),args...;kwargs...)

figure(plot::Makie.GridLayoutSpec, args...; options...) = _reactive_figure(plot, args...; options...)

figure(plot::Nothing, args...; options...) = _reactive_figure(plot, args...; options...)
