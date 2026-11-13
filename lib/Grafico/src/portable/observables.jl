# Private compiler input. The author continues to use ordinary lift/map calls.
struct _ObservableReference
    index::Int
end

struct _ObservableNode
    observable::Makie.Observable
    function_value::Any
    arguments::Tuple
    initial::Any
end

struct _ObservableGraph
    nodes::Vector{_ObservableNode}
    outputs::Vector{Int}
end

function _check_observable_callbacks(observable)
    for (_, callback) in Makie.Observables.listeners(observable)
        callback isa Makie.Observables.MapCallback ||
            throw(ArgumentError("Observable $(observable.id) has an opaque callback. Export follows pure lift/map computations; on/onany effects need an explicit browser implementation."))
    end
end

function _observable_producer(observable)
    producers = Any[]
    for input in observable.inputs
        callback = input.f
        callback isa Makie.Observables.MapCallback && callback.result === observable ||
            throw(ArgumentError("Observable $(observable.id) has an unsupported producer. Export currently follows lift/map dependencies."))
        any(x -> x === callback, producers) || push!(producers, callback)
    end
    length(producers) <= 1 ||
        throw(ArgumentError("Observable $(observable.id) has multiple map! writers. Export needs one producer per derived value."))
    isempty(producers) ? nothing : only(producers)
end

# Reading another Observable through a captured field would hide a dependency.
# Ordinary @lift expands its reads into explicit map arguments and is supported.
function _check_observable_capture(value, seen = IdDict{Any,Nothing}())
    value isa Makie.Observable &&
        throw(ArgumentError("A computation captures an Observable. Pass it as a lift/map argument so export can follow its dependency."))
    T = typeof(value)
    isbitstype(T) && return
    value isa Union{Module,Type,AbstractString,Symbol} && return
    haskey(seen, value) && return
    seen[value] = nothing
    if value isa AbstractArray
        isbitstype(eltype(value)) || foreach(item -> _check_observable_capture(item, seen), value)
    elseif isstructtype(T)
        for name in fieldnames(T)
            isdefined(value, name) && _check_observable_capture(getfield(value, name), seen)
        end
    end
end

function _observable_graph(outputs::AbstractVector{<:Makie.Observable})
    nodes = _ObservableNode[]
    indices = IdDict{Any,Int}()
    visiting = IdDict{Any,Nothing}()
    function visit(observable)
        haskey(indices, observable) && return indices[observable]
        haskey(visiting, observable) && throw(ArgumentError("The Observable dependency graph contains a cycle."))
        visiting[observable] = nothing
        _check_observable_callbacks(observable)
        producer = _observable_producer(observable)
        if producer === nothing
            function_value, arguments = nothing, ()
        else
            function_value = producer.f
            _check_observable_capture(function_value)
            arguments = map(producer.args) do argument
                argument isa Makie.Observable ? _ObservableReference(visit(argument)) : _motion_copy(argument)
            end
        end
        push!(nodes, _ObservableNode(observable, function_value, arguments, _motion_copy(observable[])))
        index = indices[observable] = length(nodes)
        delete!(visiting, observable)
        index
    end
    roots = map(visit, outputs)
    _ObservableGraph(nodes, roots)
end
