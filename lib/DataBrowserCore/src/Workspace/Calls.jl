"""
    Call

One call of the code that made items: a stage of the project, such as `process(::Sweep)`, or the
function of a computed item. Items that went through the same code share their calls.

- `title`: the function's name, with the type of the values a stage of the project ran for;
- `code`: the method, or the place in a file, that [`which`](@ref) gives; `nothing` when it is not
  known;
- `count`: the number of items or computed items it made;
- `inputs`: the calls whose results it read. A call of a stage reads the call before it.
"""
mutable struct Call
    title::String
    code::Union{Method,LineNumberNode,Nothing}
    count::Int
    inputs::Vector{Call}
end

"""
    calls(workspace, ids) -> Vector{Call}

How the items `ids` were made: for each way of making them, its last call, which reads the calls
before it through `inputs`. Items whose calls run the same code, on results made in the same way,
share them.
"""
function calls(workspace::Workspace, ids::AbstractVector{<:AbstractString})::Vector{Call}
    # The calls made so far, by their code and inputs; the same code on the same inputs is one call.
    known = Dict{Tuple{String,Any,Vector{UInt}},Call}()
    function call!(title, code, inputs::Vector{Call})::Call
        made = get!(() -> Call(title, code, 0, inputs), known, (title, code, map(objectid, inputs)))
        made.count += 1
        return made
    end
    # The last call that made each item, so that an item read twice is counted once.
    made_by = Dict{ItemKey,Union{Call,Nothing}}()
    last_call(key::ItemKey) = get!(() -> call_of(key), made_by, key)
    function call_of(key::ItemKey)::Union{Call,Nothing}
        value = @lock workspace.catalog.lock get(workspace.computations, key, nothing)
        if value !== nothing
            inputs = Call[]
            for x in reads(value)
                input = last_call(something(item(workspace, x isa Computed ? id(x) : x)))
                input === nothing || push!(inputs, input)
            end
            return call!(function_name(value.f), which(value), unique!(inputs))
        end
        source = source_item(workspace, key)
        source === nothing && return nothing
        project, T = workspace.project, valuetype(workspace, key)
        made = nothing
        stages = Any[(SOURCE_READ, source), (SOURCE_EXPAND, source), (ITEM_PROCESS, T), (ITEM_ANALYZE, T)]
        for collection in ancestors(workspace, key), stage in (COLLECTION_PROCESS, COLLECTION_ANALYZE)
            value = last(values(workspace, collection))
            has_stage(project, value, stage) && push!(stages, (stage, typeof(value)))
        end
        for (stage, x) in stages
            code = which(project, stage, x)
            # A stage that runs no code of the project made nothing; `read` always runs.
            code === nothing && stage != SOURCE_READ && continue
            title = stage_name(stage) * "(::" * string(x isa Type ? label(x) : nameof(typeof(x))) * ")"
            made = call!(title, code, made === nothing ? Call[] : Call[made])
        end
        return made
    end
    found = Call[]
    for x in ids
        key = item(workspace, x)
        made = key === nothing ? nothing : last_call(key)
        made === nothing || made in found || push!(found, made)
    end
    return found
end

"""
    edit(call::Call)

Open the code of `call` in the editor, at its line, as `edit(file, line)` does.
"""
function InteractiveUtils.edit(call::Call)::Nothing
    call.code isa Method && InteractiveUtils.edit(call.code)
    call.code isa LineNumberNode && InteractiveUtils.edit(string(call.code.file), call.code.line)
    return nothing
end

stage_name(stage::PipelineStage)::String =
    stage == SOURCE_READ ? "read" : stage == SOURCE_EXPAND ? "expand" :
    stage in (ITEM_PROCESS, COLLECTION_PROCESS) ? "process" : "analyze"

"""
    which(value::Computed) -> Union{Method,LineNumberNode,Nothing}

The code of a computed item: the method of its function for its arguments, or `nothing` when that
is not known before it runs. A package whose computations are values of its own type, such as the
fits of a plot, can say where their code is.
"""
function Base.which(value::Computed)::Union{Method,LineNumberNode,Nothing}
    # A computed argument is passed as its result, whose type is known only once it is computed.
    types = Tuple{map(x -> x isa Computed ? Any : typeof(x), value.args)...}
    found = methods(value.f, types)
    return length(found) == 1 ? only(found) : nothing
end
