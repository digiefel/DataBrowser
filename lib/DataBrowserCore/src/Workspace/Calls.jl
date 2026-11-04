"""
    Call

One call of the code that made items: a stage of the project, such as `process(::Sweep)`, or the
function of another computation. Items that went through the same code share their calls.

- `title`: the function's name, with the type of the values a stage of the project ran for;
- `code`: the method, or the place in a file, that [`which`](@ref) gives; `nothing` when it is not
  known;
- `items`: the label of each item it ran for, by id: the source items for `read`, the items and
  collections for `process`, the computations for a function;
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
    end
    return calls(workspace, definitions)
end

"""The calls producing a selection, including unindexed computation results."""
calls(workspace::Workspace, selection::Selection) =
    calls(workspace, Computation[computation(selection, i) for i in eachindex(selection)])

"""How computations were made, without computing them or adding them to the workspace."""
function calls(workspace::Workspace, definitions::AbstractVector{<:Computation})::Vector{Call}
    catalog = workspace.catalog
    # The calls made so far, by their code and inputs; the same code on the same inputs is one call.
    known = Dict{Tuple{String,Any,Vector{UInt}},Call}()
    visited = IdDict{Computation,Vector{Call}}()
    function calls_of(value::Computation)::Vector{Call}
        haskey(visited, value) && return visited[value]
        preceding = unique!(reduce(vcat, map(calls_of, inputs(value)); init=Call[]))
        row, place, ran_for, failure, result = @lock catalog.lock begin
            row = get(catalog, value, Catalogs.NOWHERE)
            place = row == Catalogs.NOWHERE ? nothing : get(workspace.places, row, nothing)
            ran_for = place isa String ? (id(value.args[3]), label(value.args[3])) :
                place === nothing ? (row == Catalogs.NOWHERE ? (id(value), id(value)) : (cachekey(workspace, row), cachekey(workspace, row))) :
                (workspace.tree[place].id, place isa ItemKey ? workspace.tree[place].label : label(workspace.tree[place].value))
            current = row != Catalogs.NOWHERE && Catalogs.state(catalog, row) == Catalogs.CURRENT
            row, place, ran_for, get(workspace.errors, row, nothing), current ? Catalogs.result_type(catalog, row) : nothing
        end
        found = row == Catalogs.NOWHERE ? nothing : stage(@lock catalog.lock get(() -> call_signature(workspace, row), workspace.signatures, row))
        # The call of `value`, with the calls it reads, kept with each call of the same code on the same inputs.
        function made!(title, code, value, preceding, result)
            made = get!(() -> Call(title, code, Dict(), Dict(), nothing, Dict(), preceding), known, (title, code, map(objectid, preceding)))
            made.items[first(ran_for)] = last(ran_for)
            made.computations[first(ran_for)] = value
            result === nothing || result === Any || (made.result = made.result === nothing ? result : typejoin(made.result, result))
            return made
        end
        if found === nothing
            made = made!(function_name(value.f), which(value), value, preceding,
                something(result, Base.infer_return_type(value.f, argument_types(value))))
        elseif found[1] == SOURCE_READ
            # The row of a source item runs `read` and then `expand`, which are two calls of the
            # project's code. The call of `read` gives what `read` returns, computed when asked for.
            type = string(nameof(found[2]))
            expand = which(workspace.project, SOURCE_EXPAND, found[2])
            made = made!("read(::$type)", which(workspace.project, SOURCE_READ, found[2]),
                expand === nothing ? value : Computation(DataBrowserAPI.read, value.args...), preceding, nothing)
            expand === nothing || (made = made!("expand(::$type)", expand, value, Call[made], nothing))
        else
            code = which(workspace.project, found...)
            # A stage the project does not define passes on what it receives.
            code === nothing && return (visited[value] = preceding)
            made = made!("process(::" * string(label(found[2])) * ")", code, value, preceding, nothing)
        end
        failure === nothing || (made.failed[first(ran_for)] = first(split(failure, '\n')))
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

# The signature of a row that did not run yet. The result type of a collection row that did not run
# is the type of its collection.
function call_signature(workspace::Workspace, row::Row)::Type
    value = workspace.catalog[row]
    type(x::Input) = Catalogs.result_type(workspace.catalog, x.row) !== Nothing ? Catalogs.result_type(workspace.catalog, x.row) :
        get(workspace.places, x.row, nothing) isa CollectionKey ? typeof(workspace.tree[workspace.places[x.row]].value) : Any
    type(x) = argument_type(workspace, x)
    return Tuple{typeof(value.f),map(type, value.args)...}
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

# A computed argument is passed as its result, whose type is known only once it is computed.
argument_types(value::Computation)::Type{<:Tuple} =
    Tuple{map(x -> x isa Union{Computation,Input,Part} ? Any : typeof(x), value.args)...}

"""
    which(value::Computation) -> Union{Method,LineNumberNode,Nothing}

The code of a computation: the method of its function for its arguments, or `nothing` when that
is not known before it runs. A package whose computations are values of its own type, such as the
fits of a plot, can say where their code is.
"""
function Base.which(value::Computation)::Union{Method,LineNumberNode,Nothing}
    found = methods(value.f, argument_types(value))
    return length(found) == 1 ? only(found) : nothing
end
