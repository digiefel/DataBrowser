# This is an internal export experiment, not a public authoring interface.
# WasmTarget supplies type descriptors and constructors/accessors for values.
function lower_observables(outputs::NamedTuple, input_names, roots, root_bindings)
    foreach(Grafico._check_observable_callbacks, keys(input_names))
    allunique(values(input_names)) || throw(ArgumentError("Export input names must be unique."))
    graph = Grafico._observable_graph(collect(values(outputs)))
    for (observable, name) in input_names
        index = findfirst(node -> node.observable === observable, graph.nodes)
        index === nothing && throw(ArgumentError("Input $name does not drive any exported output."))
        graph.nodes[index].function_value === nothing ||
            throw(ArgumentError("Input $name is derived. Bind controls to its source Observables."))
    end
    bridge = WasmTarget.Bridge
    named_roots = Dict{String,Any}(root[3] => root for root in roots)
    function add_root!(f, signature; name = "computation_$(length(named_roots) + 1)")
        haskey(named_roots, name) && return name
        root = (f, signature, name)
        named_roots[name] = root
        push!(roots, root)
        if fieldcount(typeof(f)) > 0
            constants = Dict(key => getfield(f, key) for key in fieldnames(typeof(f)))
            root_bindings[name] = WasmTarget.RootBindings(;
                captured_constants = constants, elide_closure_context = true)
        end
        name
    end
    function transport(value, direction)
        T = typeof(value)
        result = direction === :argument ? bridge.arg_descriptor(T) : bridge.descriptor(T)
        result === nothing && throw(ArgumentError("Export cannot transport $T across the browser boundary."))
        descriptor, accessors = result
        for (f, signature, name) in accessors
            add_root!(f, signature; name)
        end
        descriptor
    end
    nodes = map(enumerate(graph.nodes)) do (index, node)
        T = eltype(node.observable)
        isconcretetype(T) || throw(ArgumentError("Export needs a concrete Observable value type; got $T."))
        descriptor = transport(node.initial, :result)
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
            typed_function = let f = node.function_value, T = T
                (args...) -> convert(T, f(args...))
            end
            function_name = add_root!(typed_function, signature)
            arguments = map(node.arguments) do argument
                if argument isa Grafico._ObservableReference
                    (; node = argument.index - 1)
                else
                    descriptor = transport(argument, :argument)
                    (; descriptor, value = bridge.value_to_tree(descriptor, argument))
                end
            end
            (; name = nothing, function_name, arguments, descriptor)
        end
    end
    (; nodes, outputs = Dict(string(name) => index - 1 for (name, index) in zip(keys(outputs), graph.outputs)))
end
