# Reuse Makie's recipe computations instead of implementing plots in JavaScript.
# Unchanged inputs (fonts, layout, camera configuration) are staged constants;
# only nodes downstream of a retained numeric Observable enter the program.
function _stage_compute(callback, names, template, raw_type, result_type; output_index = nothing)
    variables = [gensym(:input) for _ in 1:maximum((x.index for x in template if x isa _ReactiveReference); init = 0)]
    arguments = map(template) do argument
        argument isa _ReactiveReference ? variables[argument.index] : QuoteNode(argument)
    end
    inputs = Expr(:call, QuoteNode(NamedTuple{names}), Expr(:tuple, arguments...))
    changed = QuoteNode(NamedTuple{names}(ntuple(_ -> true, length(names))))
    raw = gensym(:result)
    outputs = [:(Makie.ComputePipeline.deref($raw[$index])::$(fieldtype(result_type, index)))
               for index in 1:fieldcount(result_type)]
    result = output_index === nothing ? Expr(:tuple, outputs...) : outputs[output_index]
    body = quote
        $raw = Base.@inline($(QuoteNode(callback))($inputs, $changed, nothing))::$raw_type
        $result
    end
    # Stage fixed callback configuration as Julia constants before inference.
    # For example, Makie's optional argument expansion then disappears entirely
    # when it is disabled; its open-ended Tuple fallback never enters the module.
    Core.eval(@__MODULE__, Expr(:->, Expr(:tuple, variables...), body))
end

function _stage_native_map(callback, template, result_type)
    variables = [gensym(:input) for _ in 1:maximum((x.index for x in template if x isa _ReactiveReference); init = 0)]
    arguments = map(template) do argument
        argument isa _ReactiveReference ? variables[argument.index] : QuoteNode(argument)
    end
    call = Expr(:call, QuoteNode(callback), arguments...)
    # Native recipes sometimes capture optional label Observables. Their fixed,
    # disabled branches must disappear before the compiler registers field types.
    body = :(Base.@inline($call)::$result_type)
    Core.eval(@__MODULE__, Expr(:->, Expr(:tuple, variables...), body))
end

function _inferred_constant(f, signature)
    code, _ = only(Base.code_typed(f, signature; optimize = true))
    returns = [statement.val for statement in code.code
               if statement isa Core.ReturnNode && isdefined(statement, :val)]
    isempty(returns) && return nothing
    values = map(returns) do value
        value isa QuoteNode && return Some(value.value)
        if value isa GlobalRef && isconst(value.mod, value.name)
            return Some(getfield(value.mod, value.name))
        end
        value isa Union{Core.SSAValue,Core.SlotNumber,Core.Argument,Expr} && return nothing
        Some(value)
    end
    any(isnothing, values) && return nothing
    constant = something(first(values))
    (isbits(constant) || constant isa Symbol) || return nothing
    all(value -> something(value) === constant, values) ? Some(constant) : nothing
end

struct _ComputedInput{F,T}
    conversion::F
end
(call::_ComputedInput{F,T})(value) where {F,T} = convert(T, call.conversion(value))

struct _ComputedOutput{I} end
(::_ComputedOutput{I})(values) where {I} = values[I]

function _computed_origins(graphs; callbacks = ())
    origins = IdDict{Any,Any}()
    for graph in graphs
        for observer in graph.observerfunctions
            callback = observer.f
            # These are the concrete input connections installed by
            # ComputePipeline.add_input!, not arbitrary user effects.
            if parentmodule(typeof(callback)) === Makie.ComputePipeline &&
               hasfield(typeof(callback), :attr) && hasfield(typeof(callback), :k) &&
               callback.attr === graph && callback.k isa Symbol
                origins[graph[callback.k]] = observer.observable
            end
        end
        for (name, observable) in graph.observables
            origins[observable] = graph[name]
        end
    end
    for observer in callbacks
        callback = observer.f
        callback isa Makie.Observables.MapCallback || continue
        previous = get(origins, callback.result, callback)
        previous === callback || throw(ArgumentError("A native Observable has multiple producers."))
        origins[callback.result] = callback
    end
    origins
end

function _compute_dependence(observables, native_graphs; callbacks = ())
    pipeline = Makie.ComputePipeline
    sources = IdDict{Any,Bool}(observable => true for observable in observables)
    origins = _computed_origins(native_graphs; callbacks)
    visiting = IdDict{Any,Nothing}()
    function depends(node)
        haskey(sources, node) && return sources[node]
        haskey(visiting, node) && throw(ArgumentError("A Makie dependency graph contains a cycle."))
        visiting[node] = nothing
        result = if haskey(origins, node)
            origin = origins[node]
            origin isa Makie.Observables.MapCallback ?
                any(argument -> argument isa Makie.Observable && depends(argument), origin.args) : depends(origin)
        elseif node isa pipeline.Computed && node.parent isa pipeline.ComputeEdge
            any(depends, node.parent.inputs)
        elseif node isa Makie.Observable
            producer = _observable_producer(node)
            producer !== nothing && any(argument -> argument isa Makie.Observable && depends(argument), producer.args)
        else
            false
        end
        delete!(visiting, node)
        sources[node] = result
    end
    depends
end

function _append_compute_graph(graph::_ObservableGraph, roots, native_graphs; callbacks = ())
    pipeline = Makie.ComputePipeline
    nodes = copy(graph.nodes)
    indices = IdDict{Any,Int}(node.observable => index for (index, node) in enumerate(nodes))
    origins = _computed_origins(native_graphs; callbacks)
    dependent = IdDict{Any,Bool}()
    visiting = IdDict{Any,Nothing}()

    function depends(node)
        haskey(indices, node) && return true
        haskey(dependent, node) && return dependent[node]
        haskey(visiting, node) && throw(ArgumentError("A Makie dependency graph contains a cycle."))
        visiting[node] = nothing
        result = if haskey(origins, node)
            origin = origins[node]
            origin isa Makie.Observables.MapCallback ?
                any(argument -> argument isa Makie.Observable && depends(argument), origin.args) : depends(origin)
        elseif node isa pipeline.Computed
            edge = node.parent
            edge isa pipeline.ComputeEdge && any(depends, edge.inputs)
        elseif node isa Makie.Observable
            producer = _observable_producer(node)
            producer !== nothing && any(argument -> argument isa Makie.Observable && depends(argument), producer.args)
        else
            false
        end
        delete!(visiting, node)
        dependent[node] = result
    end

    function append_node!(key, f, arguments, initial)
        push!(nodes, _ObservableNode(Makie.Observable(initial), f, arguments, _motion_copy(initial)))
        indices[key] = length(nodes)
        _ObservableReference(length(nodes))
    end
    function lower(node)
        haskey(indices, node) && return _ObservableReference(indices[node])
        depends(node) || return node isa pipeline.Computed ? _motion_copy(node[]) : _motion_copy(node[])
        if haskey(origins, node) && !(origins[node] isa Makie.Observables.MapCallback)
            source = lower(origins[node])
            if node isa pipeline.Computed && node.parent isa pipeline.Input &&
               node.parent.f !== identity
                T = typeof(node[])
                return append_node!(node, _ComputedInput{typeof(node.parent.f),T}(node.parent.f), (source,), node[])
            end
            indices[node] = source.index
            return source
        end
        if node isa Makie.Observable
            producer = get(origins, node, nothing)
            producer === nothing && (producer = _observable_producer(node))
            # Makie's scoped lift keeps producers on the plot, not on the
            # result Observable. Stage its fixed configuration before lowering.
            # Authored computations were checked before creating the native scene.
            dynamic = _ObservableReference[]
            template = map(producer.args) do argument
                value = argument isa Makie.Observable ? lower(argument) : _motion_copy(argument)
                if value isa _ObservableReference
                    push!(dynamic, value)
                    _ReactiveReference(length(dynamic))
                else
                    value
                end
            end
            call = _stage_native_map(producer.f, template, typeof(node[]))
            return append_node!(node, call, Tuple(dynamic), node[])
        end
        edge = node.parent
        edge isa pipeline.ComputeEdge || throw(ArgumentError("A dynamic Makie input has no retained source: $(node.name)."))
        dynamic = _ObservableReference[]
        template = map(Tuple(edge.inputs)) do input
            argument = lower(input)
            if argument isa _ObservableReference
                push!(dynamic, argument)
                _ReactiveReference(length(dynamic))
            else
                argument
            end
        end
        names = Tuple(input.name for input in edge.inputs)
        initial = Tuple(_motion_copy(output[]) for output in edge.outputs)
        fresh_inputs = NamedTuple{names}(Tuple(input[] for input in edge.inputs))
        fresh = edge.callback(fresh_inputs, map(_ -> true, fresh_inputs), nothing)
        fresh isa Tuple || throw(ArgumentError("Makie computation $(names) cannot be evaluated without its native cache."))
        isequal(map(pipeline.deref, fresh), initial) || throw(ArgumentError(
            "Makie computation $(names) depends on mutable cached state and cannot yet be exported."))
        projection = _stage_compute(edge.callback, names, template, typeof(fresh), typeof(initial);
                                    output_index = node.parent_idx)
        signature = Tuple(typeof(nodes[argument.index].initial) for argument in dynamic)
        constant = _inferred_constant(projection, signature)
        if constant !== nothing
            dependent[node] = false
            return something(constant)
        end
        if !haskey(indices, edge)
            call = _stage_compute(edge.callback, names, template, typeof(fresh), typeof(initial))
            append_node!(edge, call, Tuple(dynamic), initial)
        end
        append_node!(node, _ComputedOutput{node.parent_idx}(),
                     (_ObservableReference(indices[edge]),), node[])
    end
    outputs = map(roots) do root
        depends(root) || return nothing
        output = lower(root)
        output isa _ObservableReference ? output : nothing
    end
    _ObservableGraph(nodes, [output.index for output in outputs if output !== nothing]), outputs
end
