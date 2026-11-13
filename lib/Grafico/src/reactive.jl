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

function _lift_call(f, args...; kwargs...)
    named = (; kwargs...)
    sources = _sources((args,named))
    isempty(sources) && return f(args...; kwargs...)
    Makie.lift(sources...) do _...
        f(_unobserve(args)...; _unobserve(named)...)
    end
end

data(x::Makie.Observable) = Makie.lift(data,x)

const ObservablePlot = Makie.Observable{<:ComposablePlot}
const ReactiveOperand = Union{PlotSpecObject,PlotModifier,Fit,Aggregate}
(header::ObservablePlot)(items...) = _lift_call((value,lines...) -> value(lines...),header,items...)

for op in (:+, :*)
    @eval begin
        Base.$op(a::ObservablePlot,b::ObservablePlot) = Makie.lift(Base.$op,a,b)
        Base.$op(a::ObservablePlot,b::ReactiveOperand) = Makie.lift(x -> Base.$op(x,b),a)
        Base.$op(a::ReactiveOperand,b::ObservablePlot) = Makie.lift(x -> Base.$op(a,x),b)
    end
end

resolve(x::ObservablePlot,items,axes,points=nothing) =
    Makie.lift(value -> resolve(value,items,axes,points),x)
inherit(a::ObservablePlot,b::ObservablePlot) = Makie.lift(inherit,a,b)
inherit(a::ObservablePlot,b) = Makie.lift(x -> inherit(x,b),a)
inherit(a::Layer,b::ObservablePlot) = Makie.lift(x -> inherit(a,x),b)

_snapshot(x) = x
_snapshot(x::Makie.Observable) = _snapshot(x[])
_snapshot(x::PlotLines) = PlotLines([PlotLine(_snapshot(line.layers),line.shared,line.drawn) for line in x.lines])
_snapshot(x::YScaleLayers) = YScaleLayers([role => _snapshot(layer) for (role,layer) in x.layers])
_snapshot(x::Scaled) = Scaled(_snapshot(x.layers),x.scales,x.texts,x.legend,x.theme,
    NamedTuple[(; (key => (key === :points ? _unobserve(value) : value) for (key,value) in pairs(step))...) for step in x.coords])

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
            child[]=Makie.plot!(wrapper,native)
        end
        previous[]=entry
    end
    wrapper
end

function _entry_spec(entry)
    if any(value -> value isa Makie.Observable,values(entry.named))
        Makie.PlotSpec(LiveEntry,entry)
    else
        Makie.PlotSpec(entry.plottype,entry.positional...;pairs(entry.named)...)
    end
end

# Coordinate display settings may contain Observables inside a tuple of limits.
# Bind them to the axis, with SpecApi owning observer replacement and cleanup.
function _axis_spec(axis,plots)
    attributes = (;pairs(axis.attributes)...)
    block = axis.type === Axis3 ? S.Axis3(;plots,_unobserve(attributes)...) :
                                 S.Axis(;plots,_unobserve(attributes)...)
    live = [(key,value,_sources(value)) for (key,value) in pairs(attributes) if _hasobs(value)]
    for (key,value,sources) in live, source in sources
        block.then(ax -> Makie.on(source;update=true) do _
            setproperty!(ax,key,_unobserve(value))
        end)
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
end

function _CompiledPlot(specification)
    node = _CompiledPlot(Makie.Observable{Makie.GridLayoutSpec}(specification),
                         Makie.ObserverFunction[],_CompiledPlot[],Makie.ObserverFunction[])
    finalizer(_dispose!,node)
    node
end

function _dispose!(node::_CompiledPlot)
    foreach(Makie.off,node.observers)
    foreach(Makie.off,node.forwarding)
    foreach(_dispose!,node.children)
    empty!(node.observers); empty!(node.forwarding); empty!(node.children)
    nothing
end

function _compile_plot(plot,args...;kwargs...)
    node = _CompiledPlot(_restore_blocks!(spec(_snapshot(plot),_unobserve(args)...;kwargs...)))
    weak = WeakRef(node)
    for source in _sources(plot isa Declaration ? (plot,args) : plot)
        push!(node.observers,Makie.on(source) do _
            current=weak.value
            current === nothing && return
            current.specification[] = _restore_blocks!(spec(_snapshot(plot),_unobserve(args)...;kwargs...))
        end)
    end
    node
end

function _compile_plot(source::Makie.Observable,args...;kwargs...)
    child = _compile_plot(source[],args...;kwargs...)
    node = _CompiledPlot(child.specification[])
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
        foreach(Makie.off,current.forwarding)
        foreach(_dispose!,current.children)
        replacement = _compile_plot(value,args...;kwargs...)
        current.children = [replacement]
        current.forwarding = [forward(replacement)]
        current.specification[] = replacement.specification[]
    end)
    node
end

function _compile_plot(composed::ComposedFigure,args...;layout=(;),kwargs...)
    children = [_compile_plot(child,args...;kwargs...) for (_,child) in composed.cells]
    assemble(nodes) = _layout_spec(S.GridLayout([position => child.specification[] for ((position,_),child) in zip(composed.cells,nodes)]), layout)
    node = _CompiledPlot(assemble(children))
    node.children=children
    weak=WeakRef(node)
    for source in _sources(layout)
        push!(node.observers, Makie.on(source) do _
            current = weak.value
            current === nothing || (current.specification[] = assemble(current.children))
        end)
    end
    for child in children
        push!(node.forwarding,Makie.on(child.specification) do _
            current=weak.value
            current === nothing || (current.specification[]=assemble(current.children))
        end)
    end
    node
end

function _reactive_figure(plot,args...;figure_kw=(;),kwargs...)
    compiled = _compile_plot(plot,args...;kwargs...)
    fig = Figure(;figure_kw...)
    Makie.plot(fig[1,1],compiled.specification)
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
