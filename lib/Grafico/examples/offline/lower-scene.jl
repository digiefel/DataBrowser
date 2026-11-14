# Internal exporter: derive renderer bindings from the native scene. No plot
# kinds, scientific variable names, or shader buffer names are authored here.
function scene_observables(specification::Makie.GridLayoutSpec)
    outputs = Makie.Observable[]
    function add(value)
        value isa Makie.Observable && !any(x -> x === value, outputs) && push!(outputs, value)
    end
    function visit(grid)
        for (_, child) in grid.content
            if child isa Makie.GridLayoutSpec
                visit(child)
            else
                for plot in child.plots
                    if plot.type === :LiveEntry
                        entry = only(plot.args)
                        foreach(add, entry.positional)
                        foreach(add, values(entry.named))
                    else
                        foreach(add, plot.args)
                        foreach(add, values(plot.kwargs))
                    end
                end
            end
        end
    end
    visit(specification)
    outputs
end

function scene_plots(scene)
    plots = Makie.Plot[]
    function visit(plot)
        push!(plots, plot)
        foreach(visit, plot.plots)
    end
    foreach(visit, scene.plots)
    for child in scene.children
        append!(plots, scene_plots(child))
    end
    plots
end

function gpu_components(value)
    T = typeof(value)
    if isprimitivetype(T) && value isa Union{Real,Bool}
        return [value]
    elseif value isa AbstractArray
        return reduce(vcat, (gpu_components(item) for item in value); init = Real[])
    elseif isbitstype(T)
        return reduce(vcat, (gpu_components(getfield(value, i)) for i in 1:fieldcount(T)); init = Real[])
    end
    throw(ArgumentError("Cannot pack $(typeof(value)) as a numeric GPU value."))
end

function prepare_scene(declaration; outputs = (;), figure_kw = (;), kwargs...)
    specification = Grafico.spec(Grafico._retained_plot(declaration); kwargs...)
    function validate_axes(grid)
        for (_, child) in grid.content
            if child isa Makie.GridLayoutSpec
                validate_axes(child)
            else
                for callback in child.then_funcs
                    callback isa Grafico._AxisBinding || continue
                    throw(ArgumentError("The live axis setting $(callback.key) needs its native camera, ticks, and layout computations exported together. That connection cannot yet be exported."))
                end
            end
        end
    end
    validate_axes(specification)
    retained = scene_observables(specification)
    append!(retained, values(outputs))
    graph = Grafico._observable_graph(retained)
    output_indices = Dict(string(name) => graph.outputs[length(retained) - length(outputs) + i]
                          for (i, name) in enumerate(keys(outputs)))
    fig = Makie.Figure(; figure_kw...)
    Makie.plot(fig[1, 1], specification)
    Makie.update_state_before_display!(fig)
    plots = scene_plots(fig.scene)
    native_graphs = [plot.attributes for plot in plots]
    callbacks = [observer for plot in plots for observer in plot.deregister_callbacks]
    depends = Grafico._compute_dependence([node.observable for node in graph.nodes], native_graphs; callbacks)
    for observer in callbacks
        depends(observer.observable) || continue
        observer.f isa Makie.Observables.MapCallback && continue
        throw(ArgumentError("A native recipe updates an exported value through an opaque on/onany callback. Its numeric computation must be retained before it can be exported."))
    end
    atomic = filter(plots) do plot
        Makie.is_atomic_plot(plot) && any(depends, values(plot.attributes.outputs))
    end
    # This registers the backend's actual numeric input computations.
    foreach(plot -> WGLMakie.serialize_three(Makie.parent_scene(plot), plot), atomic)
    render_inputs = [input for plot in atomic for input in plot.attributes[:wgl_renderobject].parent.inputs]
    for source in scene_observables(specification)
        reaches = Grafico._compute_dependence([source], native_graphs; callbacks)
        any(reaches, render_inputs) || throw(ArgumentError(
            "An authored numeric input does not reach a native drawing object. The recipe's dependency connection cannot yet be exported."))
    end
    captured, references = Grafico._append_compute_graph(graph, render_inputs,
        native_graphs; callbacks)
    bound_plots = Makie.Plot[]
    bindings = NamedTuple[]
    offset = 0
    for plot in atomic
        inputs = plot.attributes[:wgl_renderobject].parent.inputs
        updates = NamedTuple[]
        for (i, input) in enumerate(inputs)
            reference = references[offset + i]
            reference === nothing && continue
            input.name in (:space, :markerspace) && throw(ArgumentError(
                "WGLMakie cannot change $(input.name) after creating a plot."))
            serialized = WGLMakie.serialize_three(input[])
            format = if serialized isa AbstractArray
                T = eltype(serialized)
                T === Float32 ? "Float32Array" : T === Float64 ? "Float64Array" :
                T === UInt32 ? "Uint32Array" : T === Int32 ? "Int32Array" :
                T === UInt8 ? "Uint8Array" : throw(ArgumentError("Unsupported GPU buffer type $T."))
            elseif serialized isa Union{Number,Bool}
                "scalar"
            else
                throw(ArgumentError("Unsupported changing GPU value $(typeof(serialized))."))
            end
            # Numeric values stay Julia values until the browser boundary. The
            # transport packs their scalar fields; compare that layout with the
            # real backend serializer before accepting it.
            if format !== "scalar"
                components = gpu_components(input[])
                length(components) == length(serialized) && all(isequal.(components, serialized)) ||
                    throw(ArgumentError("The GPU layout for $(typeof(input[])) needs a transport adapter."))
            end
            name = "render_$(length(bindings) + length(updates) + 1)"
            output_indices[name] = reference.index
            push!(updates, (; key = string(input.name), output = name, format))
        end
        offset += length(inputs)
        isempty(updates) && continue
        push!(bound_plots, plot)
        for update in updates
            push!(bindings, (; plot = length(bound_plots) - 1, update...))
        end
    end
    (; figure = fig, graph = captured, outputs = output_indices,
       native_plots = bound_plots, bindings)
end

# GPU values are numeric buffers, so they need neither JSON-shaped trees nor
# JavaScript copies of Julia structs. Generate typed accessors from the native
# value type and validate their layout against the backend serializer above.
function gpu_arity(T)
    if isprimitivetype(T) && T <: Union{Real,Bool}
        return 1
    elseif isbitstype(T)
        count = sum(gpu_arity, fieldtypes(T); init = 0)
        count > 0 && return count
    end
    throw(ArgumentError("A GPU element must have a fixed numeric layout; got $T."))
end

function gpu_component_expression(T, value, index)
    if isprimitivetype(T) && T <: Union{Real,Bool}
        return value
    elseif T <: AbstractArray
        width = gpu_arity(eltype(T))
        item = :($value[div($index - 1, $width) + 1])
        local_index = width == 1 ? 1 : :(mod($index - 1, $width) + 1)
        return gpu_component_expression(eltype(T), item, local_index)
    end
    widths = map(gpu_arity, fieldtypes(T))
    offset = 0
    result = :(throw(BoundsError()))
    for i in reverse(eachindex(widths))
        start = sum(widths[1:i-1]; init = 0)
        field = :(getfield($value, $i))
        component = gpu_component_expression(fieldtype(T, i), field, :($index - $start))
        result = :($index <= $(start + widths[i]) ? $component : $result)
    end
    result
end

function lower_renderer_bindings(prepared, roots, root_bindings)
    formats = Dict("Float32Array" => Float32, "Float64Array" => Float64,
        "Uint32Array" => UInt32, "Int32Array" => Int32, "Uint8Array" => UInt8)
    accessors = Dict{Any,Any}()
    map(prepared.bindings) do binding
        binding.format == "scalar" && return binding
        node = prepared.graph.nodes[prepared.outputs[binding.output]]
        T = typeof(node.initial)
        output_type = formats[binding.format]
        kernels = get!(accessors, (T, output_type)) do
            value, index = gensym(:value), gensym(:index)
            count = T <: AbstractArray ? :(length($value) * $(gpu_arity(eltype(T)))) : gpu_arity(T)
            component = gpu_component_expression(T, value, index)
            count_function = Core.eval(@__MODULE__, Expr(:->, Expr(:tuple, value), count))
            component_function = Core.eval(@__MODULE__, Expr(:->, Expr(:tuple, value, index),
                :(convert($output_type, $component))))
            count_kernel = add_wasm_root!(roots, root_bindings, count_function, (T,); prefix = "gpu_count")
            component_kernel = add_wasm_root!(roots, root_bindings, component_function, (T, Int64); prefix = "gpu_component")
            (; count_kernel, component_kernel)
        end
        merge(binding, kernels)
    end
end
