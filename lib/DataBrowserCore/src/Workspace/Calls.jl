"""
    Call

One call of the code that made items: a stage of the project, such as `process(::Sweep)`, or the
function of another computation. Items that went through the same code share their calls.

- `title`: the function's name, with the type of the values a stage of the project ran for;
- `code`: the method, or the place in a file, that [`which`](@ref) gives; `nothing` when it is not
  known;
- `items`: the label of each item it ran for, by id: the source items for `read`, the items for
  `process`, the computations for a function;
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

How the values `ids` were made: for each way of making them, its last call, which reads the calls
before it through `inputs`. Values whose calls run the same code, on results made in the same way,
share them. Ids that the workspace has no value for are left out.
"""
function calls(workspace::Workspace, ids::AbstractVector{<:AbstractString})::Vector{Call}
    known = @lock workspace.catalog.lock filter(x -> haskey(workspace.versions, x), ids)
    return calls(workspace, Computation[computation(workspace, x) for x in known])
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
        ## A value picked from the result of a call that gives several: that call, for that value.
        given = value
        value.f === pick && (value = value.args[1])
        row, ran_for, failure, result, members = @lock catalog.lock begin
            row = get(catalog, value, Catalogs.NOWHERE)
            stage = get(workspace.stages, row, nothing)
            ## The source item that a read reads, or the value that a `process` takes, or the computation.
            ran_for = stage == SOURCE_READ ? (id(value.args[3]), label(value.args[3])) :
                stage !== nothing ? (value.args[2].id, label(workspace, value.args[2].id)) : (id(value), id(value))
            given === value || (ran_for = (given.args[2], label(workspace, given.args[2])))
            current = row != Catalogs.NOWHERE && Catalogs.state(catalog, row) == Catalogs.CURRENT
            ## A group also reads the values of its members that it takes.
            taken = haskey(workspace.taken, row) ? member_values(workspace, row) : Pair{String,Row}[]
            row, ran_for, get(workspace.errors, row, nothing), current ? Catalogs.result_type(catalog, row) : nothing,
                Computation[catalog[at] for (_, at) in taken]
        end
        preceding = unique!(reduce(vcat, map(calls_of, [inputs(value); members]); init=Call[]))
        found = row == Catalogs.NOWHERE ? nothing : stage(@lock catalog.lock get(() -> call_signature(workspace, row), workspace.signatures, row))
        # The call of `value`, with the calls it reads, kept with each call of the same code on the same inputs.
        function made!(title, code, value, preceding, result)
            made = get!(() -> Call(title, code, Dict(), Dict(), nothing, Dict(), preceding), known, (title, code, map(objectid, preceding)))
            made.items[first(ran_for)] = last(ran_for)
            made.computations[first(ran_for)] = given
            result === nothing || result === Any || (made.result = made.result === nothing ? result : typejoin(made.result, result))
            return made
        end
        if found === nothing
            made = made!(function_name(value.f), which(value), value, preceding,
                something(result, Base.infer_return_type(value.f, argument_types(value))))
        elseif found[1] == SOURCE_READ
            made = made!("read(::$(nameof(found[2])))", which(workspace.project, SOURCE_READ, found[2]), value, preceding, nothing)
        else
            code = which(workspace.project, found...)
            # A stage the project does not define passes on what it receives.
            code === nothing && return (visited[given] = preceding)
            made = made!("process(::" * string(label(found[2])) * ")", code, value, preceding, nothing)
        end
        failure === nothing || (made.failed[first(ran_for)] = first(split(failure, '\n')))
        return (visited[given] = Call[made])
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

# The signature of a row that did not run yet.
function call_signature(workspace::Workspace, row::Row)::Type
    value = workspace.catalog[row]
    type(x::Input) = Catalogs.result_type(workspace.catalog, x.row) !== Nothing ? Catalogs.result_type(workspace.catalog, x.row) : Any
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
