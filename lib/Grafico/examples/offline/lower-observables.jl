include("compile-values.jl")

# This is an internal export experiment, not a public authoring interface.
# WasmTarget supplies type descriptors and constructors/accessors for values.
function lower_observables(outputs::NamedTuple, input_names, roots, root_bindings)
    foreach(Grafico._check_observable_callbacks, keys(input_names))
    allunique(values(input_names)) || throw(ArgumentError("Export input names must be unique."))
    graph = Grafico._observable_graph(collect(values(outputs)))
    output_indices = Dict(string(name) => index for (name, index) in zip(keys(outputs), graph.outputs))
    lower_observable_graph(graph, output_indices, input_names, roots, root_bindings)
end

function lower_observable_graph(graph::Grafico._ObservableGraph, output_indices, input_names, roots, root_bindings; opaque_outputs = Set{String}())
    live = Set{Int}()
    function retain(index)
        index in live && return
        push!(live, index)
        for argument in graph.nodes[index].arguments
            argument isa Grafico._ObservableReference && retain(argument.index)
        end
    end
    foreach(retain, values(output_indices))
    ordered = sort!(collect(live))
    indices = Dict(index => position for (position, index) in enumerate(ordered))
    for (observable, name) in input_names
        index = findfirst(node -> node.observable === observable, graph.nodes)
        (index === nothing || !(index in live)) && throw(ArgumentError("Input $name does not drive any exported output."))
        graph.nodes[index].function_value === nothing ||
            throw(ArgumentError("Input $name is derived. Bind controls to its source Observables."))
    end
    bridge = WasmTarget.Bridge
    add_root!(f, signature; name = nothing) = add_wasm_root!(roots, root_bindings, f, signature; name)
    transport(value, direction) = transport_type!(typeof(value), direction, roots, root_bindings)
    typed_functions = Dict{Any,Any}()
    exposed = Set(index for (name, index) in output_indices if !(string(name) in opaque_outputs))
    nodes = map(ordered) do index
        node = graph.nodes[index]
        T = eltype(node.observable)
        isconcretetype(T) || throw(ArgumentError("Export needs a concrete Observable value type; got $T."))
        descriptor = index in exposed || node.function_value === nothing ?
            transport(node.initial, :result) : nothing
        if node.function_value === nothing
            input_descriptor = transport(node.initial, :argument)
            (; name = get(input_names, node.observable, "input_$index"),
               function_name = nothing, arguments = (), descriptor,
               input_descriptor, initial = bridge.value_to_tree(input_descriptor, node.initial))
        else
            signature = map(node.arguments) do argument
                argument isa Grafico._ObservableReference ? typeof(graph.nodes[argument.index].initial) : typeof(argument)
            end
            # Observable assignment converts each result to its declared type.
            # Keep that conversion in the compiled function as well.
            typed_function = get!(typed_functions, (node.function_value, signature, T)) do
                f = node.function_value
                if !(f isa Union{Core.Builtin,Core.IntrinsicFunction}) &&
                   fieldcount(typeof(f)) == 0 && Base.return_types(f, signature) == [T]
                    # Staged recipe functions already assert each native output's
                    # exact type. Register them directly as closed-world roots.
                    f
                else
                    variables = [gensym(:argument) for _ in signature]
                    target = if f isa Union{Core.Builtin,Core.IntrinsicFunction}
                        name = nameof(f)
                        owner = first(filter(mod -> isdefined(mod, name) && getfield(mod, name) === f,
                                            (Core, Core.Intrinsics)))
                        GlobalRef(owner, name)
                    else
                        QuoteNode(f)
                    end
                    call = Expr(:call, target, variables...)
                    body = :(convert($T, Base.@inline($call))::$T)
                    Core.eval(@__MODULE__, Expr(:->, Expr(:tuple, variables...), body))
                end
            end
            function_name = add_root!(typed_function, signature)
            arguments = map(node.arguments) do argument
                if argument isa Grafico._ObservableReference
                    (; node = indices[argument.index] - 1)
                else
                    descriptor = transport(argument, :argument)
                    (; descriptor, value = bridge.value_to_tree(descriptor, argument))
                end
            end
            (; name = nothing, function_name, arguments, descriptor)
        end
    end
    (; nodes, outputs = Dict(string(name) => indices[index] - 1 for (name, index) in pairs(output_indices)))
end
