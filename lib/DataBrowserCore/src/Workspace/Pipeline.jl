# The pipeline of a project is the calls of its code: `read` for each source item, and `process` for
# the values that reading gives, for groups, and for the members of groups. The workspace runs each
# call as a row of its *catalog*, a table with one row for each computation, which holds the state
# of the computation (missing, stale, current or failed) and the rows that it reads
# ([`Catalogs.jl`](../Catalogs.md)).
# The workspace *holds* a row to keep it in the catalog, and *wants* it, with a priority, so that a
# worker runs it, and runs it again when it is *stale*: when its code, an input or its computation
# changed since it ran. A window or a script that reads a row *requests* it: a worker runs it ahead
# of the wanted rows, until it has a result.
#
# | Row            | Calls                                  | Cache key                  | Added when                                              |
# | -------------- | -------------------------------------- | -------------------------- | ------------------------------------------------------- |
# | read           | `read(project, source, item)`          | `read:a.csv`               | the source reports a source item without members        |
# | group read     | `read(project, source, item, members)` | `read:.`                   | the source reports a source item with members           |
# | process        | `process(project, value)`              | `process:a.csv`            | a read gives the value                                  |
# | group process  | `process(project, group, members)`     | `group process:.`          | a value is a group, and a method of the project takes it |
# | member process | `process(project, member, group)`      | `member process:a.csv in .` | a value is a member of a group, and a method of the project takes both |
#
# A row gives one value, or several when its result is a vector of items. Each value has an *id*, a
# string that the project chooses and that stays the same from one session to the next. A value
# with the id of a value that an earlier row gives is a later *version* of that value: the rows of
# one id run in the order of the table, and the last one gives its *latest version*, which windows
# show. A value with another id is a new value. Two rows that give the same id at the same stage,
# or a row that gives the id of a value that it does not read, are a project error: the status panel
# of the browser shows it next to the row, and the value keeps the version it had.
#
# A group is a value with members: [`members`](@ref) gives their ids. A group read and a group
# process take the values of its members of the type `T` that their method takes: for each member,
# its latest version of type `T`, in the order of their ids. A member that is a group with no value
# of type `T` gives the values of type `T` of its own members instead, and so on below them. The
# workspace reads `T` from the signature of the method, and asks again when the code changes.
#
# The row of a group reads the rows of the versions that it takes, so it runs after all of them, and
# again when one of them gives a later version. It also takes a later version that did not run yet
# but will: one that is wanted or requested, and does not read a failed row. So when a folder is read
# for the first time, its group read runs once, after the reads of its files. A `process` that
# nothing wants does not run for its group: the group takes the version before it, and runs again
# when a window or a script asks for that `process`. A member whose row fails is left out until it
# runs again. When a member gets a later version, the workspace changes what the group takes for
# that member alone, and the version of the group follows from a sum over its members, so that the
# change takes the same time whatever the number of members.
#
# Windows come first: the rows of the values that a window shows run before all others (see
# "Workers" in [`Evaluate.jl`](Evaluate.md)). Reads always run in the background. The rows of
# `process` run in the background only with the option `background_processing` of `open_workspace`,
# which is off by default. Without `background_processing`, they run only when a window or a script
# asks for them.
#
# When a workspace opens again, the cache gives back the values of each row, with their metadata and
# labels, and its version; a row whose version is the saved one is current without running. The
# results themselves come from the stores ([`Evaluate.jl`](Evaluate.md)).
#
# All the values under one metadata name have one type in the whole workspace, because the cache
# keeps each name in a column of one type: the type of the first value saved under the name. When
# `a/1` gives `temperature = 300`, an `Int`, and `a/2` then gives `temperature = 300.5`, a
# `Float64`, the cache does not save the value of `a/2`, and the status panel of the browser shows
# the error next to `a/2`.
#
# Changes reach the pipeline from three places:
#
# ```text
#     the scan, the source watcher  ─▶ source!, remove_source_item!, apply!   reads
#     a worker, when a row finishes ─▶ finished!                              the rows that read it
#     a code change                 ─▶ check_code! (Evaluate.jl)
# ```
#
# When you edit a `process` method, the rows that call it become stale. They run again when a window
# shows their value or a script reads it, or in the background with `background_processing=true`.
#
# Each function on this page runs inside `@lock catalog.lock` while it changes the catalog, so that a
# window never sees half a change. When the change is complete, the workspace calls `publish!`,
# which forgets what the workspace kept for removed rows and tells the windows that something
# changed.

# ## Source items

"""
    source!(workspace, source_item)

Add the row that reads a source item that the source reports for the first time. A source item that
has a row already gets its new computation in that row when it changed, or when it has no
*fingerprint*, the value that a source gives to tell whether a source item changed, such as the
modification time of a file; a source item with members also when its `read` takes member values
of another type. When the cache saved the result of a new row, the row is current at once.
"""
function source!(workspace::Workspace, source_item::AbstractDataSourceItem)::Nothing
    catalog, project, source, read_id = workspace.catalog, workspace.project, workspace.source, id(source_item)
    row = get(workspace.sources, read_id, nothing)
    held = String[id(member) for member in members(source, source_item)]
    value = if isempty(held)
        Computation(read, project, source, source_item)
    else
        ## The default group `read` takes values of any type.
        P, S, I = typeof(project), typeof(source), typeof(source_item)
        T = something(asked(workspace, member_type, read, P, S, I), asked(workspace, member_type, read, S, I), AbstractDataItem)
        Computation(read, project, source, source_item, MemberValues{T}(read_id))
    end
    ## A group read takes the values of its members, and a member stands for its read until it gives them.
    # TODO: when the members of a source item change, this takes the time of the number of members.
    taken = String[held; [x for member in held for x in values(workspace, member)]]
    for member in held
        above = get!(Vector{String}, workspace.parents, member)
        read_id in above || push!(above, read_id)
    end
    if row !== nothing
        before = catalog[row]
        for gone in setdiff(map(id, members(source, before.args[3])), held)
            filter!(!=(read_id), get(workspace.parents, gone, String[]))
        end
        ## A source item without a fingerprint may have changed whenever it is reported.
        fingerprint(source_item) !== nothing && isequal(fingerprint(before.args[3]), fingerprint(source_item)) &&
            isequal(before.args[4:end], value.args[4:end]) && return nothing
        replace!(catalog, row, value)
        isempty(held) || members!(workspace, row, taken)
        return nothing
    end
    row = add!(catalog, value)
    hold!(catalog, row)
    workspace.sources[read_id], workspace.cachekeys[row], workspace.stages[row] = row, "read:" * read_id, SOURCE_READ
    want!(catalog, row, SOURCES_FIRST)
    isempty(held) || members!(workspace, row, taken)
    restore!(workspace, row)
    return nothing
end

"""
    remove_source_item!(workspace, source_item_id)

Remove a source item that the source no longer has, with its row: its values leave the workspace
and the selection.
"""
function remove_source_item!(workspace::Workspace, read_id::String)::Nothing
    row = get(workspace.sources, read_id, nothing)
    row === nothing && return nothing
    source_item = workspace.catalog[row].args[3]
    release!(workspace, row)
    delete!(workspace.sources, read_id)
    ## The source items with members above no longer wait for its read.
    foreach(above -> input!(workspace, workspace.sources[above], read_id), get(workspace.parents, read_id, String[]))
    delete!(workspace.parents, read_id)
    foreach(member -> filter!(!=(read_id), get(workspace.parents, id(member), String[])), members(workspace.source, source_item))
    return nothing
end

"""
    apply!(workspace, changes::SourceChanges)

Apply one batch of changes that the source watcher reported: the source items that were removed,
and the source items that are new or changed (the field `upserts`).
"""
function apply!(workspace::Workspace, changes::SourceChanges)::Nothing
    foreach(source -> remove_source_item!(workspace, source), changes.removals)
    foreach(source_item -> source!(workspace, source_item), changes.upserts)
    return nothing
end

"""
    values(workspace, source_item_id) -> Vector{String}

The ids of the values of a source item: the value that reading it gives, and the values that the
`process` of that value gives.
"""
function Base.values(workspace::Workspace, read_id::AbstractString)::Vector{String}
    row = get(workspace.sources, read_id, nothing)
    found = String[output.id for output in get(workspace.outputs, row, Output[])]
    for value in copy(found)
        processed = get(workspace.rows, "process:" * value, nothing)
        append!(found, output.id for output in get(workspace.outputs, processed, Output[]))
    end
    return unique!(found)
end

# ## Values and their versions

"""
    finished!(workspace, row, outputs)

Make `outputs` the values that the row of the pipeline `row` gives, and add, change or release the
rows that read them. `nothing` stands for a row without a result, which did not run yet or failed. The
selection follows the values of its source item. A worker calls `finished!` when the row finishes,
and so does `restore!` when the cache saved its result.
"""
function finished!(workspace::Workspace, row::Row, outputs::Union{Nothing,Vector{Output}})::Nothing
    read_id = source(workspace, row)
    before = values(workspace, read_id)
    ids = given!(workspace, row, outputs)
    refresh!(workspace, ids)
    after = values(workspace, read_id)
    ## The group reads above take the values that the source item gives now, in place of its read.
    for above in get(workspace.parents, read_id, String[])
        group = workspace.sources[above]
        input!(workspace, group, read_id)
        foreach(x -> input!(workspace, group, x, 1), setdiff(after, before))
        foreach(x -> input!(workspace, group, x, -1), setdiff(before, after))
    end
    replaced!(workspace.selection, before, after)
    return nothing
end

"""
    given!(workspace, row, outputs) -> Vector{String}

Make `outputs` the values of `row`: each is a version of its id, unless another row gives that id
at the same stage, or an earlier row gives it and `row` does not read it. With `outputs = nothing`,
for a row without a result, `row` is a version of the value it is expected to give: the value that a
`process` method takes. The cache and the stores forget the values that `row` no longer gives.
Returns the ids of the values whose versions changed, or none when `row` gives values of the same
ids, types and members as before.
"""
function given!(workspace::Workspace, row::Row, outputs::Union{Nothing,Vector{Output}})::Vector{String}
    catalog, stage = workspace.catalog, workspace.stages[row]
    accepted, conflicts = Output[], String[]
    for output in something(outputs, Output[])
        others = filter(!=(row), get(workspace.versions, output.id, Row[]))
        earlier = filter(other -> workspace.stages[other] < stage, others)
        reads = any(x -> x isa Part && x.id == output.id && x.of.row in earlier, catalog[row].args)
        if any(found -> found.id == output.id, accepted)
            push!(conflicts, "it gives the id \"$(output.id)\" twice")
        elseif any(other -> workspace.stages[other] == stage, others) || !(isempty(earlier) || reads)
            push!(conflicts, "the value \"$(output.id)\" comes from $(cachekey(workspace, others[end]))")
        else
            push!(accepted, output)
        end
    end
    expected = stage == SOURCE_READ ? String[] : [catalog[row].args[2].id]
    before = get(workspace.outputs, row, nothing)
    ids = unique!(String[[output.id for output in something(before, Output[])]; [output.id for output in accepted]; expected])
    for x in ids
        rows = filter!(!=(row), get!(Vector{Row}, workspace.versions, x))
        (outputs === nothing ? x in expected : any(output -> output.id == x, accepted)) &&
            insert!(rows, something(findfirst(other -> workspace.stages[other] > stage, rows), length(rows) + 1), row)
        isempty(rows) && delete!(workspace.versions, x)
    end
    for output in something(before, Output[])
        any(found -> found.id == output.id, accepted) && continue
        delete!(workspace.produced, output.key)
        delete_output!(workspace.cache.db, cachekey(workspace, row), output.id)
        place = store(workspace, output.type)
        place === nothing || delete!(place, output.type, cachekey(cachekey(workspace, row), output.id))
    end
    outputs === nothing ? delete!(workspace.outputs, row) : (workspace.outputs[row] = accepted)
    ## The group rows that take one of these values take its latest version now.
    foreach(x -> foreach(group -> input!(workspace, group, x), get(workspace.takers, x, Row[])), ids)
    conflicts!(workspace, row, conflicts)
    shape(found) = found === nothing ? nothing : [(output.id, output.type, output.members) for output in found]
    return before !== nothing && isequal(shape(before), shape(get(workspace.outputs, row, nothing))) ? String[] : ids
end

"""
    refresh!(workspace, ids)

Add, change or release the rows that read the values `ids`, after their versions changed: the
`process` of a value that a read gives, the group `process` of a group, the member `process`
methods of its members, and those of a value in each group it is a member of. The members of a
group are those of its latest version.
"""
function refresh!(workspace::Workspace, ids::Vector{String})::Nothing
    catalog, project = workspace.catalog, workspace.project
    for x in ids
        versions = get(workspace.versions, x, Row[])
        read_row = findfirst(row -> workspace.stages[row] == SOURCE_READ, versions)
        # TODO: `process` runs once, on what `read` gave; call it again on its results until they are
        # `isequal` to its inputs.
        row!(workspace, "process:" * x, ITEM_PROCESS, read_row === nothing ? nothing :
            Computation(process, project, Part(Input(catalog, versions[read_row]), x)))
        group!(workspace, x)
        value = output(workspace, x)
        held = value === nothing || value.members === nothing ? String[] : value.members
        before = get(workspace.members, x, String[])
        for member in setdiff(before, held)
            groups = get(workspace.groups, member, String[])
            filter!(!=(x), groups)
            isempty(groups) && delete!(workspace.groups, member)
            row!(workspace, "member process:$member in $x", MEMBER_PROCESS, nothing)
        end
        isempty(held) ? delete!(workspace.members, x) : (workspace.members[x] = held)
        ## A group row that takes the members of `x` in its place takes its members now.
        for group in get(workspace.takers, x, Row[])
            workspace.taken[group].rows[x].row == Catalogs.NOWHERE || continue
            foreach(member -> input!(workspace, group, member, 1), setdiff(held, before))
            foreach(member -> input!(workspace, group, member, -1), setdiff(before, held))
        end
        for member in held
            groups = get!(Vector{String}, workspace.groups, member)
            x in groups || push!(groups, x)
            member!(workspace, member, x)
        end
        foreach(group -> member!(workspace, x, group), copy(get(workspace.groups, x, String[])))
    end
    return nothing
end

"""
    group!(workspace, group)

Add, change or release the group `process` of the value `group`: it runs when the value is a group,
and a method of the project takes its type and a vector of member values.
"""
function group!(workspace::Workspace, group::String)::Nothing
    project, key = workspace.project, "group process:" * group
    found = latest(workspace, group, GROUP_PROCESS; T=Any)
    value = found === nothing ? nothing : output(workspace, found, group)
    T = value === nothing || value.members === nothing ? nothing : asked(workspace, member_type, process, typeof(project), value.type)
    T === nothing && return row!(workspace, key, GROUP_PROCESS, nothing)
    row!(workspace, key, GROUP_PROCESS, Computation(process, project,
        Part(Input(workspace.catalog, latest(workspace, group, GROUP_PROCESS)), group), MemberValues{T}(group)), value.members)
    return nothing
end

"""
    member!(workspace, member, group)

Add, change or release the member `process` of the value `member` in `group`: it runs when a method
of the project takes the types of their latest values.
"""
function member!(workspace::Workspace, member::String, group::String)::Nothing
    key = "member process:$member in $group"
    own = get(workspace.rows, key, Catalogs.NOWHERE)
    of_member, of_group = latest(workspace, member, MEMBER_PROCESS; T=Any, skip=own), latest(workspace, group, nothing; T=Any, skip=own)
    applies = of_member !== nothing && of_group !== nothing && asked(workspace, hasmethod, process,
        Tuple{typeof(workspace.project),output(workspace, of_member, member).type,output(workspace, of_group, group).type})
    row!(workspace, key, MEMBER_PROCESS, applies ? Computation(process, workspace.project,
        Part(Input(workspace.catalog, latest(workspace, member, MEMBER_PROCESS)), member),
        Part(Input(workspace.catalog, latest(workspace, group, nothing; skip=own)), group)) : nothing)
    return nothing
end

"""
    row!(workspace, key, stage, computation, held=String[])

Add the row of `process` with the cache key `key`, or give it `computation` when it has another
computation. `nothing` releases the row. Until the row has a result, it is a version of the value
that its `process` takes. A group process takes the values of the members `held`.
"""
function row!(workspace::Workspace, key::String, stage::PipelineStage, value::Union{Nothing,Computation}, held::Vector{String}=String[])::Nothing
    catalog = workspace.catalog
    row = get(workspace.rows, key, nothing)
    if value === nothing
        row === nothing && return nothing
        delete!(workspace.rows, key)
        release!(workspace, row)
    elseif row === nothing
        row = add!(catalog, value)
        hold!(catalog, row)
        workspace.rows[key], workspace.cachekeys[row], workspace.stages[row] = row, key, stage
        workspace.background_processing && want!(catalog, row, BACKGROUND_ITEM)
        given!(workspace, row, nothing)
        stage == GROUP_PROCESS && members!(workspace, row, held)
        restore!(workspace, row)
    else
        isequal(catalog[row], value) || replace!(catalog, row, value)
        stage == GROUP_PROCESS && members!(workspace, row, held)
    end
    return nothing
end

"""
    release!(workspace, row)

Release a row of the pipeline: its values leave the workspace, and the cache forgets them.
"""
function Catalogs.release!(workspace::Workspace, row::Row)::Nothing
    finished!(workspace, row, Output[])
    haskey(workspace.taken, row) && members!(workspace, row, nothing)
    delete!(workspace.stages, row)
    release!(workspace.catalog, row)
    return nothing
end

"""
    latest(workspace, id, before; T=nothing, skip=NOWHERE) -> Union{Nothing,Row}

The row of the latest version of the value `id` from a stage before `before`, or from any stage for
`before = nothing`, other than `skip`. With `T`, the latest row that gave a value of type `T`;
without, also a row that did not run yet. `nothing` when there is none.
"""
function latest(workspace::Workspace, x::String, before::Union{Nothing,PipelineStage}; T=nothing, skip::Row=Catalogs.NOWHERE)::Union{Nothing,Row}
    for row in Iterators.reverse(get(workspace.versions, x, Row[]))
        (row == skip || before !== nothing && workspace.stages[row] >= before) && continue
        T === nothing && return row
        found = output(workspace, row, x)
        found !== nothing && found.type <: T && return row
    end
    return nothing
end

# The value with id `x` that `row` gave, or `nothing`.
function output(workspace::Workspace, row::Row, x::String)::Union{Nothing,Output}
    found = get(workspace.outputs, row, Output[])
    index = findfirst(output -> output.id == x, found)
    return index === nothing ? nothing : found[index]
end

# The latest version of the value `x` that a row gave, or `nothing`.
function output(workspace::Workspace, x::String)::Union{Nothing,Output}
    row = latest(workspace, x, nothing; T=Any)
    return row === nothing ? nothing : output(workspace, row, x)
end

"""
    members!(workspace, row, ids)

Make the row of a group read or a group process take the values of the members `ids`, of the type
`T` of its argument `MemberValues{T}`, in place of those it took; `nothing` takes none, for a row
that leaves. It changes nothing when the row takes these members already, and else takes the time
of the number of members.
"""
function members!(workspace::Workspace, row::Row, ids::Union{Nothing,Vector{String}})::Nothing
    T, before = eltype(workspace.catalog[row].args[end]), get(workspace.taken, row, nothing)
    before !== nothing && before.T == T && isequal(before.root, ids) && return nothing
    before === nothing || foreach(x -> input!(workspace, row, x, -1), before.root)
    ids === nothing && return (delete!(workspace.taken, row); nothing)
    workspace.taken[row] = Taken(T, ids, Dict(), 0)
    foreach(x -> input!(workspace, row, x, 1), ids)
    return nothing
end

"""
    input!(workspace, row, id, change=0)

Follow the value `id` among the values that the row of a group takes, after its versions changed,
or after one more (`change` 1) or one fewer (`change` -1) of the ids above it lead to it. The row
takes the latest version of the type `T` of its argument `MemberValues{T}`, from before the member
`process` methods, or a later version that did not run yet but will: it is wanted or requested, and
does not read a failed row. A source item stands for its values while its read will run, and a
group without such a version stands for its members. The row reads the row of each version that it
takes, and its version follows theirs.
"""
# TODO: a group read and a group process see the values of members from before the member `process`
# methods, of their own group too. Choose how they converge (docs/plans/processing.md).
function input!(workspace::Workspace, row::Row, x::String, change::Int=0)::Nothing
    catalog, taken = workspace.catalog, workspace.taken[row]
    before = get(taken.rows, x, (row=Catalogs.NOWHERE, term=UInt64(0), paths=Int32(0)))
    paths, after = before.paths + change, Catalogs.NOWHERE
    runs(other) = Catalogs.state(catalog, other) in (Catalogs.MISSING, Catalogs.STALE) &&
        Catalogs.wanted(catalog, other) && !Catalogs.stuck(catalog, other)
    if paths > 0
        for version in Iterators.reverse(get(workspace.versions, x, Row[]))
            (version == row || workspace.stages[version] >= MEMBER_PROCESS) && continue
            found = output(workspace, version, x)
            (found === nothing ? runs(version) : found.type <: taken.T) && (after = version; break)
        end
        read = get(workspace.sources, x, Catalogs.NOWHERE)
        after == Catalogs.NOWHERE && read != Catalogs.NOWHERE && runs(read) && (after = read)
    end
    ## The new row is connected first, so that a row that the group reads twice stays.
    after == before.row || after == Catalogs.NOWHERE || Catalogs.connect!(catalog, row, after)
    after == before.row || before.row == Catalogs.NOWHERE || Catalogs.disconnect!(catalog, row, before.row)
    term = after == Catalogs.NOWHERE ? UInt64(0) : hash(x, Catalogs.version(catalog, after))
    taken.version += term - before.term
    if paths > 0
        taken.rows[x] = (row=after, term, paths)
        before.paths > 0 || push!(get!(Vector{Row}, workspace.takers, x), row)
    else
        delete!(taken.rows, x)
        takers = filter!(!=(row), workspace.takers[x])
        isempty(takers) && delete!(workspace.takers, x)
    end
    ## A group without a version to take stands for its members.
    stands(found, count) = count > 0 && found == Catalogs.NOWHERE
    stands(before.row, before.paths) == stands(after, paths) ||
        foreach(member -> input!(workspace, row, member, stands(after, paths) ? 1 : -1), get(workspace.members, x, String[]))
    return nothing
end

"""
    member_type(f, types...) -> Union{Nothing,Type}

The type `T` of the member values that a method of the project for `f` takes after arguments of
`types`: the method that Julia calls for `f(::types..., ::Vector{T})`, whose last argument is an
`AbstractVector{T}`. `nothing` when no method of the project takes one.
"""
function member_type(f, types...)::Union{Nothing,Type}
    for method in methods(f, Tuple{types...,AbstractVector})
        Base.moduleroot(method.module) in (Base, Core, DataBrowserAPI) && continue
        vector = Base.unwrap_unionall(Base.unwrap_unionall(method.sig).parameters[end])
        element = vector isa DataType && !isempty(vector.parameters) ? vector.parameters[1] : Any
        T = element isa TypeVar ? element.ub : element
        T isa Type || continue
        called = try which(f, Tuple{types...,Vector{T}}) catch; nothing end
        called === method && return T
    end
    return nothing
end

# The answer of `query(arguments...)` about the methods of the project, which `check_code!` asks
# again after a code change.
asked(workspace::Workspace, query, arguments...) =
    get!(() -> query(arguments...), workspace.methods, (query, arguments...))

# The id of the source item that the values of a row of the pipeline come from.
function source(workspace::Workspace, row::Row)::String
    value = workspace.catalog[row]
    length(value.args) >= 3 && value.args[3] isa AbstractDataSourceItem && return id(value.args[3])
    return source(workspace, value.args[2].of.row)
end

conflict_message(conflict::MetadataConflict)::String =
    "$(conflict.name) holds values of type $(conflict.expected), not $(conflict.found)"

"""
    conflicts!(workspace, row, messages)

Add the values of a row that the workspace or the cache did not keep to the error of that row: the
status panel of the browser shows the error next to the row, and a warning with the cache key of the
row goes to the log.
"""
function conflicts!(workspace::Workspace, row::Row, messages::Vector{String})::Nothing
    isempty(messages) && return nothing
    workspace.errors[row] = join([get(workspace.errors, row, String[]); messages], "; ")
    @warn("Values were not kept", computation=cachekey(workspace, row), messages)
    return nothing
end

"""
    replaced!(selection, before, after)

Let the selection follow the values of a source item that gave the ids `before` and gives `after`
now. The values that it no longer gives leave the selection. When it gives as many new ids as it
lost, the first new id replaces the first lost id, and so on, in the order that the source item gave
them: when another recipe reads the source item, it usually gives the same measurements under other
ids. With `a/1` selected, a source item that gave `a/1` and `a/2` and gives `a/x` and `a/y` now
leaves `a/x` selected.
"""
function replaced!(selection::WorkspaceSelection, before::Vector{String}, after::Vector{String})::Nothing
    gone, added = setdiff(before, after), setdiff(after, before)
    replaced = selection.replaced
    foreach(id -> delete!(replaced, id), added)
    if length(gone) == length(added)
        for (old, new) in zip(gone, added)
            ## An item replaced before is replaced by the newest item.
            map!(id -> id == old ? new : id, values(replaced))
            replaced[old] = new
        end
    end
    selected = unique!([get(replaced, id, id) for id in selection.item_ids if !(id in gone) || haskey(replaced, id)])
    selected == selection.item_ids || (selection.item_ids = selected; selection.revision += 1)
    return nothing
end
