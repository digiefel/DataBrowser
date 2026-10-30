"""
    Call

One call of the code that made items: a stage of the project, such as `process(::Sweep)`, or the
function of a computed item. Items that went through the same code share their calls.

- `title`: the function's name, with the type of the values a stage of the project ran for;
- `code`: the method, or the place in a file, that [`which`](@ref) gives; `nothing` when it is not
  known;
- `items`: the label of each item it ran for, by id: the source items for `read` and `expand`, the
  items for the other stages, the computed items for a function;
- `failed`: the first line of the error of each item it failed for, by id;
- `result`: the type of the values a function gives, as Julia infers it before running it;
  `nothing` when Julia cannot tell, and for a stage of the project;
- `computations`: the actual computation for each item, by the same id as `items`;
- `inputs`: the calls whose results it read. A call of a stage reads the call before it.
"""
mutable struct Call
    title::String
    code::Union{Method,LineNumberNode,Nothing}
    items::Dict{String,String}
    failed::Dict{String,String}
    result::Union{Type,Nothing}
    computations::Dict{String,Computation}
    inputs::Vector{Call}
end

"""
    calls(workspace, ids) -> Vector{Call}

How the items `ids` were made: for each way of making them, its last call, which reads the calls
before it through `inputs`. Items whose calls run the same code, on results made in the same way,
share them.
"""
function calls(workspace::Workspace, ids::AbstractVector{<:AbstractString})::Vector{Call}
    definitions = Computation[]
    for id in ids
        key = item(workspace, id)
        key === nothing && continue
        push!(definitions, computation(workspace, key))
        for holder in ancestors(workspace, key)
            Catalogs.status(workspace.catalog, holder, COLLECTION_ANALYZE).absent && continue
            push!(definitions, computation(workspace, holder, COLLECTION_ANALYZE))
        end
    end
    return calls(workspace, definitions)
end

"""The calls producing a selection, including unindexed computation results."""
function calls(workspace::Workspace, selection::Selection)
    # Catalog selections also expose collection analyses, which contribute metadata without
    # replacing the item's value. A selection of view results follows its own node references.
    getfield(selection.data, :workspace) === workspace && return calls(workspace, selection.id)
    return calls(workspace, Computation[computation(selection, i) for i in eachindex(selection)])
end

"""Inspect computation references without evaluating them or adding catalog entries."""
function calls(workspace::Workspace, definitions::AbstractVector{<:Computation})::Vector{Call}
    # The calls made so far, by their code and inputs; the same code on the same inputs is one call.
    known = Dict{Tuple{String,Any,Vector{UInt}},Call}()
    # The call of `code` on `inputs`, which ran for the item `x` with the key `key` in the errors.
    function call!(title, code, inputs::Vector{Call}, x, key, stage; result=nothing)::Call
        made = get!(() -> Call(title, code, Dict(), Dict(), result, Dict(), inputs), known, (title, code, map(objectid, inputs)))
        keyed = x isa Union{ItemKey,CollectionKey}
        x_id = keyed ? id(workspace, x) : id(x)
        made.items[x_id] = keyed ? label(workspace, x) : label(x)
        made.computations[x_id] = computation(workspace, key, stage)
        failure = @lock workspace.catalog.lock get(workspace.errors, (key, stage), nothing)
        failure === nothing || (made.failed[x_id] = first(split(failure, '\n')))
        result === nothing || (made.result = made.result === nothing ? result : typejoin(made.result, result))
        return made
    end
    # Walk the actual computation inputs. Projection and identity helpers have no project call
    # of their own, so their inputs pass through. This also handles computations supplied by a
    # linked visualizer without registering copies of their preceding calls.
    visited = IdDict{Computation,Vector{Call}}()
    function calls_of(value::Computation)::Vector{Call}
        haskey(visited, value) && return visited[value]
        target = @lock workspace.catalog.lock get(workspace.catalog.computation_targets, value, nothing)
        preceding = unique!(reduce(vcat, map(calls_of, inputs(value)); init=Call[]))
        if target === nothing
            parentmodule(typeof(value.f)) === (@__MODULE__) && return (visited[value] = preceding)
            title, code = function_name(value.f), which(value)
            made = get!(() -> Call(title, code, Dict(), Dict(), nothing, Dict(), preceding),
                known, (title, code, map(objectid, preceding)))
            identity, description = computation_identity(workspace, value)
            made.items[identity] = description
            made.computations[identity] = value
            stored = get(workspace.results, value, nothing)
            inferred = stored === nothing ? Base.infer_return_type(value.f, argument_types(value)) : stored.value_type
            inferred === Any || (made.result = made.result === nothing ? inferred : typejoin(made.result, inferred))
            return (visited[value] = Call[made])
        end
        key, stage = target
        key in workspace.catalog || return (visited[value] = preceding)
        derived = key isa ItemKey ? get(workspace.computations, key, nothing) : nothing
        if derived !== nothing
            original = get(workspace.catalog.computation_targets, derived, nothing)
            # A row exposing an existing computation adds no function call.
            original !== nothing && original != target && return (visited[value] = preceding)
            result = Base.infer_return_type(derived.f, argument_types(derived))
            made = call!(function_name(derived.f), which(derived), preceding, key, key, stage;
                result=result === Any ? nothing : result)
        else
            ran_for = key isa SourceKey ? get(workspace.source_items, key, nothing) : key
            ran_for === nothing && return (visited[value] = preceding)
            type = key isa SourceKey ? typeof(ran_for) : valuetype(workspace, key)
            code = which(workspace.project, stage, key isa SourceKey ? ran_for : type)
            code === nothing && stage != SOURCE_READ && return (visited[value] = preceding)
            title = stage_name(stage) * "(::" * string(key isa SourceKey ? nameof(type) : label(type)) * ")"
            made = call!(title, code, preceding, ran_for, key, stage)
        end
        return (visited[value] = Call[made])
    end
    found = reduce(vcat, map(calls_of, definitions); init=Call[])
    unique!(found)
    preceding = Set{Call}()
    visit(call) = call in preceding || (push!(preceding, call); foreach(visit, call.inputs))
    for call in found
        foreach(visit, call.inputs)
    end
    return filter(call -> !(call in preceding), found)
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

# A computed argument is passed as its result, whose type is known only once it is computed.
argument_types(value::Computation)::Type{<:Tuple} = Tuple{map(x -> x isa Computation ? Any : typeof(x), value.args)...}

"""
    which(value::Computation) -> Union{Method,LineNumberNode,Nothing}

The code of a computed item: the method of its function for its arguments, or `nothing` when that
is not known before it runs. A package whose computations are values of its own type, such as the
fits of a plot, can say where their code is.
"""
function Base.which(value::Computation)::Union{Method,LineNumberNode,Nothing}
    found = methods(value.f, argument_types(value))
    return length(found) == 1 ? only(found) : nothing
end
