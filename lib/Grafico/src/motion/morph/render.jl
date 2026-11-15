function _chart_blocks(grid::Makie.GridLayoutSpec)
    result = Makie.BlockSpec[]
    function visit(block::Makie.BlockSpec)
        push!(result, block)
    end
    function visit(layout::Makie.GridLayoutSpec)
        foreach(pair -> visit(last(pair)), layout.content)
    end
    visit(grid)
    result
end

function _chart_native_value(block, key)
    value = getproperty(block, key)
    value isa Makie.Observable ? value[] : value
end

function _chart_set_block!(block, key, value)
    hasproperty(block, key) || return
    isequal(_chart_native_value(block,key),value) || setproperty!(block,key,value)
    nothing
end

function _chart_samples(a, b, u)
    a === nothing && return [_fade_chart_plot(b,u)]
    b === nothing && return [_fade_chart_plot(a,1-u)]
    _blend_chart_plot(a,b,u)
end

function _attach_chart!(state)
    all(reference -> reference.value !== nothing, state.blocks) || return false
    left = _chart_blocks(state.prepared.source)
    right = _chart_blocks(state.prepared.destination)
    for (index,(a,b)) in enumerate(zip(left,right))
        block = state.blocks[index].value
        names = union(keys(a.kwargs), keys(b.kwargs))
        original_values = Dict(key => _motion_copy(_chart_native_value(block,key))
            for key in keys(Makie.default_attribute_values(typeof(block),block.blockscene))
            if hasproperty(block,key))
        baseline = Dict(key => original_values[key] for key in names if haskey(original_values,key))
        push!(state.originals,(kind=:block, object=block, values=baseline))
        source_plots = isempty(a.plots) ? Any[] : last(block.scene.plots,length(a.plots))
        for plot in source_plots
            push!(state.originals,(kind=:plot,object=plot,values=(visible=plot.visible[],)))
            Makie.update!(plot; visible=false)
        end
        for i in 1:max(length(a.plots),length(b.plots))
            pa = i <= length(a.plots) ? a.plots[i] : nothing
            pb = i <= length(b.plots) ? b.plots[i] : nothing
            samples = _chart_samples(pa,pb,state.progress)
            roots = Any[]
            for sample in samples
                plot = Makie.plot!(block, Makie.to_plot_object(sample))
                push!(roots,plot)
                push!(state.owned,plot)
            end
            push!(state.bindings,(; roots,left=pa,right=pb))
        end
        for (key,value) in original_values
            isequal(_chart_native_value(block,key),value) || (baseline[key] = value)
        end
    end
    true
end

function _render_compiled_state!(node,state::_ChartMorphState)
    state.disposed && return
    state.prepared === nothing && return
    if !state.prepared.geometric
        all(reference -> reference.value !== nothing, state.blocks) || return
        for (index, reference) in enumerate(state.blocks)
            reference.value.opacity = index == 1 ? 1 - state.progress : state.progress
        end
        return
    end
    if !state.initialized
        _attach_chart!(state) || return
        state.initialized = true
    end
    left = _chart_blocks(state.prepared.source)
    right = _chart_blocks(state.prepared.destination)
    for (index,(a,b)) in enumerate(zip(left,right))
        block = state.blocks[index].value
        for key in keys(a.kwargs)
            _chart_set_block!(block,key,_motion_mix(a.kwargs[key],b.kwargs[key],state.progress))
        end
    end
    for binding in state.bindings
        samples = _chart_samples(binding.left,binding.right,state.progress)
        for (plot,sample) in zip(binding.roots,samples)
            Makie.update!(plot,sample.args...;sample.kwargs...)
        end
    end
    nothing
end

function _dispose_state!(state::_ChartMorphState)
    state.disposed && return
    state.disposed = true
    for plot in state.owned
        scene = Makie.parent_scene(plot)
        scene.isclosed || Makie.delete!(scene,plot)
    end
    for original in state.originals
        original.kind === :plot || continue
        scene = Makie.parent_scene(original.object)
        scene.isclosed || Makie.update!(original.object;original.values...)
    end
    for original in state.originals
        original.kind === :block || continue
        original.object.blockscene.isclosed && continue
        for (key,value) in original.values
            _chart_set_block!(original.object,key,value)
        end
    end
    empty!(state.bindings); empty!(state.originals); empty!(state.owned)
    nothing
end
