# The pipeline of a project is the calls of its code: `read` for each source item, and `process` for
# every value that a call gives. The workspace runs each call as a row of its *catalog*, a table with
# one row for each computation, which holds the state of the computation (missing, stale, current or
# failed) and the rows that it reads ([`Catalogs.jl`](../Catalogs.md)).
# The workspace *holds* a row to keep it in the catalog, and *wants* it, with a priority, so that a
# worker runs it, and runs it again when it is *stale*: when its code, an input or its computation
# changed since it ran. A window or a script that reads a row *requests* it: a worker runs it ahead
# of the wanted rows, until it has a result.
#
# Each value has an *id*, a string that the project chooses and that stays the same from one session
# to the next. A call that takes a value and gives a value with the same id gives a later *version*
# of it, and the windows show the *latest version*: the one with the most versions before it. A
# value with another id is a new value. One rule makes every call of `process`, for each version `v`
# that has a result:
#
# | Call                           | When                                                               |
# | ------------------------------ | ------------------------------------------------------------------ |
# | `process(project, v)`          | a method of the project takes `v`                                  |
# | `process(project, v, members)` | `v` is a group, and a method of the project takes it               |
# | `process(project, v, group)`   | `v` is a member of `group`, and a method of the project takes both |
#
# Each value that a call gives is a version with calls of its own, so a chain of calls has any
# length, and each call runs as soon as its inputs have results. A call that gives a value `isequal`
# to the version that it took gives no new version: the chain of that id ends there. This also ends
# a `process` method that returns the type that it takes, once its result stops changing. After
# `MAX_VERSIONS` versions of one id, the next call fails instead.
#
# A call takes the version that it is for, and its other inputs at their latest version that does
# not come from the call itself: the group of a member `process`, and the members of a group
# `process`. So when a member `process` gives a later version of a member, the group keeps the
# version that it took, and the group process of the next version of the group takes the new one.
#
# The source group gives the [`SourceGroup`](@ref) of the source, whose members are all its source
# items. A row fails when it gives one id twice. It also fails when it gives an id that another row
# gives, and neither of the two takes a version of it: when two files hold an item with the same id, the read that
# finishes second fails. Like any failure, a failed row gives no values, and the status panel of the
# browser shows the error next to it. The cache saves the failure of a row that gives one id twice,
# which depends on that row alone. When another row gives the id, the next session runs the row
# again, and the row succeeds once the other row is gone.
#
# A group is a value with members: [`members`](@ref) gives their ids. An id names a value, or a
# source item, which stands for the values that it gives: a group that a folder gives can name the
# files of the folder, and holds the items read from them. A group process takes the values of its
# members of the type `T` that its method takes: for each member, its latest version of type `T`, in
# the order of the members. A member that is a group with no value of type `T` gives the values of
# type `T` of its own members instead, and so on below them. The workspace reads `T` from the
# signature of the method, and asks again when the code changes.

# The row of a group process reads the rows of the versions that it takes, so it runs after all of
# them, and again when one of them gives a later version. It also takes a later version that did not
# run yet but will: one that is wanted or requested, and does not read a failed row. A `process` that
# nothing wants does not run for its group: the group takes the version before it, and runs again
# when a window or a script asks for that `process`. A member whose row fails is left out until it
# runs again. When a member gets a later version, the workspace changes what the group takes for
# that member alone, and the revision of the group follows from a sum over its members, so that the
# change takes the same time whatever the number of members.

# Windows come first: the rows of the values that a window shows run before all others (see
# "Workers" in [`Evaluate.jl`](Evaluate.md)). Reads always run in the background. The rows of
# `process` run in the background only with the option `background_processing` of `open_workspace`,
# which is off by default. Without `background_processing`, they run only when a window or a script
# asks for them.
#
# When a workspace opens again, the cache gives back the values of each row, with their metadata and
# labels, and its revision; a row whose revision is the saved one is current without running. The
# results themselves come from the stores ([`Evaluate.jl`](Evaluate.md)).
#
# All the values under one metadata name have one type in the whole workspace, because the cache
# keeps each name in a column of one type: the type of the first value saved under the name. When
# `a/1` gives `temperature = 300`, an `Int`, and `a/2` then gives `temperature = 300.5`, a
# `Float64`, the row that gives `a/2` fails, the status panel of the browser shows the error next to
# `a/2`, and the cache saves the failure. To change the type of a name, change the project so that
# every value has the new type, and open the workspace with `rebuild=true`.
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
# When you edit a `label`, `id`, `members` or `metadata` method, the rows that give values of its
# type take these values from their stores, without running, and compute their labels, ids, members
# and metadata again; a row whose store no longer has one of them runs again.
#
# Each function on this page runs inside `@lock catalog.lock` while it changes the catalog, so that a
# window never sees half a change. When the change is complete, the workspace calls `publish!`,
# which forgets what the workspace kept for removed rows and tells the windows that something
# changed.

# The number of versions after which the next call of an id fails, because its results keep
# changing.
const MAX_VERSIONS = 100

# ## Source items

"""
    source!(workspace, source_item)

Add the row that reads a source item that the source reports for the first time. A source item that
has a row already gets its new computation in that row when it changed, or when it has no
*fingerprint*, the value that a source gives to tell whether a source item changed, such as the
modification time of a file.
"""
function source!(workspace::Workspace, source_item::AbstractDataSourceItem)::Nothing
    row = get(workspace.sources, id(source_item), nothing)
    ## A source item without a fingerprint may have changed whenever it is reported.
    row !== nothing && fingerprint(source_item) !== nothing &&
        isequal(fingerprint(workspace.catalog[row].args[3]), fingerprint(source_item)) && return nothing
    return source!(workspace, workspace.sources, id(source_item), Computation(read, workspace.project, workspace.source, source_item))
end

"""
    source!(workspace, rows, key, value)

Add the row that reads from the source with the computation `value`, kept in `rows` under `key`, or
give the row `value`. When the cache saved the result of a new row, the row is current at once.
"""
function source!(workspace::Workspace, rows::Dict{String,Row}, key::String, value::Computation)::Nothing
    catalog, row = workspace.catalog, get(rows, key, nothing)
    row === nothing || (replace!(catalog, row, value); return nothing)
    row = rows[key] = @timed_dbg "source.add!" add!(catalog, value)
    hold!(catalog, row)
    write!(workspace.items, workspace.items.rows.depth, row.index, 0)
    want!(catalog, row, SOURCES_FIRST)
    @timed_dbg "source.restore" restore!(workspace, row) || finished!(workspace, row, nothing)
    return nothing
end

"""
    source_group!(workspace, ids)

Make the [`SourceGroup`](@ref) of the source hold the source items `ids`, in their order.
"""
function source_group!(workspace::Workspace, ids::Vector{String})::Nothing
    value = Computation(SourceGroup, id(workspace.source), label(workspace.source), ids)
    row = get(workspace.rows, "source group", nothing)
    row !== nothing && isequal(workspace.catalog[row], value) && return nothing
    return source!(workspace, workspace.rows, "source group", value)
end

"""
    remove_source_item!(workspace, source_item_id)

Remove a source item that the source no longer has, with its row: its values leave the workspace,
the groups and the selection.
"""
function remove_source_item!(workspace::Workspace, read_id::String)::Nothing
    row = get(workspace.sources, read_id, nothing)
    row === nothing && return nothing
    release!(workspace, row)
    delete!(workspace.sources, read_id)
    ## The group rows that take it no longer take its read.
    foreach(group -> input!(workspace, group, read_id), copy(get(workspace.takers, read_id, Row[])))
    return nothing
end

"""
    apply!(workspace, changes::SourceChanges)

Apply one batch of changes that the source watcher reported: the source items that were removed,
and the source items that are new or changed (the field `upserts`). The source group follows them.
"""
function apply!(workspace::Workspace, changes::SourceChanges)::Nothing
    foreach(source -> remove_source_item!(workspace, source), changes.removals)
    foreach(source_item -> source!(workspace, source_item), changes.upserts)
    # TODO: this takes the time of the number of source items, for each batch of changes.
    row = get(workspace.rows, "source group", nothing)
    row === nothing ||
        source_group!(workspace, union(setdiff(workspace.catalog[row].args[3], changes.removals), String[id(x) for x in changes.upserts]))
    return nothing
end

"""
    values(workspace, source_item_id) -> Vector{String}

The ids of the values of a source item: the values that reading it gives, and the new values that
the calls of `process` give from them, at any depth. Until its read has a result, the source item
is a value of its own, with its id.
"""
function Base.values(workspace::Workspace, read_id::AbstractString)::Vector{String}
    outputs, row = workspace.items.rows.outputs, get(workspace.sources, read_id, Catalogs.NOWHERE)
    found = String[output.id for output in something(outputs[row], Output[])]
    outputs[row] === nothing && row in get(workspace.versions, read_id, Row[]) && push!(found, read_id)
    ## `found` grows while the loop walks it, so the loop reaches the new values too.
    for x in found, version in get(workspace.versions, x, Row[]), key in call_keys(workspace, x, version)
        given = something(outputs[get(workspace.rows, key, Catalogs.NOWHERE)], Output[])
        append!(found, output.id for output in given if !(output.id in found))
    end
    return found
end

# ## Values and their versions

"""
    finished!(workspace, row, outputs)

Make `outputs` the values that the row of the pipeline `row` gives, and add, change or release the
rows that read them. `nothing` stands for a row without a result, which did not run yet or failed. A
worker calls `finished!` when the row finishes, and so does `restore!` when the cache saved its
result. When the row may not give one of these values, `finished!` throws the error of
[`given!`](@ref) and changes nothing.
"""
function finished!(workspace::Workspace, row::Row, outputs::Union{Nothing,Vector{Output}})::Nothing
    read_id = source(workspace, row)
    before = values(workspace, read_id)
    ids = @timed_dbg "finished.given!" given!(workspace, row, outputs)
    @timed_dbg "finished.refresh!" refresh!(workspace, row, ids)
    after = values(workspace, read_id)
    added, gone = setdiff(after, before), setdiff(before, after)
    ## The groups that name the source item hold the values that it gives now, and so do the rows of
    ## the groups that take it.
    for group in copy(get(workspace.parents, read_id, String[]))
        foreach(x -> membership!(workspace, x, group, true), added)
        foreach(x -> membership!(workspace, x, group, false), gone)
    end
    for group in copy(get(workspace.takers, read_id, Row[]))
        foreach(x -> x == read_id || input!(workspace, group, x, 1), added)
        foreach(x -> x == read_id || input!(workspace, group, x, -1), gone)
    end
    return nothing
end

"""
    given!(workspace, row, outputs) -> Vector{String}

Make `outputs` the values of `row`, each a version of its id at the depth of `row`. `given!` throws
an error, and changes nothing, when another row gives one of these ids, and neither of the two rows
takes a version of it. With `outputs = nothing`, for a row without a result, `row` is a version of the value
whose version it takes: for a read, the source item itself, with its id. The table `items` forgets
the metadata of the ids that `row` no longer gives. The stores forget the values that `row` no
longer gives with the same revision. Returns the ids of the values whose versions changed, or none
when `row` gives values of the same ids, types and members as before.
"""
function given!(workspace::Workspace, row::Row, outputs::Union{Nothing,Vector{Output}})::Vector{String}
    catalog, items = workspace.catalog, workspace.items
    depth, given, taken = items.rows.depth[row], something(outputs, Output[]), version_of(catalog[row])
    ## When the row gives an id that it may not give, `given!` throws before it changes anything.
    for output in given
        output.id == taken && continue
        others = filter(other -> other != row && version_of(catalog[other]) != output.id, get(workspace.versions, output.id, Row[]))
        isempty(others) || error("the item \"$(output.id)\" comes from $(id(catalog[others[end]]))")
    end
    before = items.rows.outputs[row]
    ids = unique!(String[[output.id for output in something(before, Output[])]; [output.id for output in given]; taken])
    for x in ids
        rows = filter!(!=(row), get!(Vector{Row}, workspace.versions, x))
        (outputs === nothing ? x == taken : any(output -> output.id == x, given)) &&
            insert!(rows, something(findfirst(other -> items.rows.depth[other] > depth, rows), length(rows) + 1), row)
        isempty(rows) && delete!(workspace.versions, x)
    end
    ## The table `items` forgets the metadata of the ids that the row no longer gives. The stores
    ## forget the values that it gave before, unless it gives them again with the same revision.
    for output in something(before, Output[])
        any(found -> found.id == output.id, given) || store!(items, output, Dict{Symbol,Any}())
        any(found -> (found.type, found.revision) == (output.type, output.revision), given) ||
            forget!(workspace, output.type, output.revision)
    end
    write!(items, items.rows.outputs, row.index, outputs)
    foreach(x -> write!(workspace, x), ids)
    ## The group rows that take one of these values take its latest version now.
    foreach(x -> foreach(group -> input!(workspace, group, x), get(workspace.takers, x, Row[])), ids)
    shape(found) = found === nothing ? nothing : [(output.id, output.type, output.members) for output in found]
    return before !== nothing && isequal(shape(before), shape(items.rows.outputs[row])) ? String[] : ids
end

"""
    write!(workspace, id)

Make the cells of the item `id` in the draft of the table `items` follow the workspace: its latest
version, label, type, the revision and the key of its value, groups and source item. A new
item takes a number that no item has, and an id that is not an item is left out. An item that
leaves the workspace gives its number to the next new item: the versions published before keep
their cells. The caller holds the catalog lock.
"""
function write!(workspace::Workspace, x::String)::Nothing
    items, columns = workspace.items, workspace.items.columns
    rows, number = get(workspace.versions, x, nothing), get(items.index, x, Int32(0))
    if rows === nothing
        number == 0 && return nothing
        items.index = Base.delete(items.index, x)
        push!(items.free, number)
    elseif number == 0
        number = isempty(items.free) ? (items.count += Int32(1)) : pop!(items.free)
        items.index = Base.PersistentDict(items.index, x => number)
        write!(items, columns.id, number, x)
    end
    value = output(workspace, x)
    version = rows === nothing ? Catalogs.NOWHERE : rows[end]
    ## The cells that `select` shows: whether the workspace has the item, its label and groups.
    shown = (columns.version[number] == Catalogs.NOWHERE) != (version == Catalogs.NOWHERE)
    write!(items, columns.version, number, version)
    shown |= write!(items, columns.label, number, value === nothing ? x : value.label)
    shown |= write!(items, columns.groups, number, get(workspace.groups, x, String[]))
    write!(items, columns.type, number, value === nothing ? Any : value.type)
    write!(items, columns.source, number, rows === nothing ? "" : source(workspace, rows[1]))
    write!(items, columns.value_revision, number, value === nothing ? UInt64(0) : value.revision)
    shown |= write!(items, columns.key, number, value === nothing ? Int64(0) : value.key)
    shown && push!(items.shown, number)
    return nothing
end

"""
    store!(items, output, values)

Replace the metadata of the value `output` in the draft of `items` with `values`, keeping a copy of
each vector value. The first value stored under a metadata key fixes the type of its column; the
cache admits only values of that type, and saves them first. The caller holds the catalog lock.
"""
function store!(items::Items, output::Output, values::AbstractDict{Symbol})::Nothing
    for (name, value) in values
        value === missing || haskey(items.metadata, name) ||
            (items.metadata[name] = Column{Union{Missing,typeof(value)}}(missing))
    end
    shown = false
    for (name, column) in items.metadata
        shown |= write!(items, column, output.key, get(values, name, missing))
    end
    ## `select` shows the metadata of the value of an item.
    number = get(items.index, output.id, Int32(0))
    shown && number != 0 && items.columns.key[number] == output.key && push!(items.shown, number)
    return nothing
end

"""
    refresh!(workspace, row, ids)

Add, change or release the calls of the versions of the values `ids` that `row` gives, after their
versions changed (see [`calls!`](@ref)). Also make each value whose latest version is a group hold
the members of that version, and a member that names a source item stands for the values that it
gives.
"""
function refresh!(workspace::Workspace, row::Row, ids::Vector{String})::Nothing
    for x in ids
        calls!(workspace, x, row)
        value = output(workspace, x)
        held = value === nothing || value.members === nothing ? String[] : value.members
        before = get(workspace.members, x, String[])
        ## A member that names a source item stands for the values that it gives.
        values_of(ids) = String[v for m in ids for v in (haskey(workspace.sources, m) ? values(workspace, m) : (m,))]
        foreach(v -> membership!(workspace, v, x, false), setdiff(values_of(before), values_of(held)))
        for m in setdiff(before, held)
            above = get(workspace.parents, m, String[])
            filter!(!=(x), above)
            isempty(above) && delete!(workspace.parents, m)
        end
        ## An id that names no source item yet may name one later, when the source reports it.
        for m in held
            above = get!(Vector{String}, workspace.parents, m)
            x in above || push!(above, x)
        end
        isempty(held) ? delete!(workspace.members, x) : (workspace.members[x] = held)
        ## A group row that takes the members of `x` in its place takes its members now.
        for group in get(workspace.takers, x, Row[])
            workspace.taken[group].rows[x].row == Catalogs.NOWHERE || continue
            foreach(member -> input!(workspace, group, member, 1), setdiff(held, before))
            foreach(member -> input!(workspace, group, member, -1), setdiff(before, held))
        end
        ## The member calls in `x` take its latest version.
        foreach(v -> membership!(workspace, v, x, true), values_of(held))
    end
    return nothing
end

"""
    membership!(workspace, x, group, holds)

Make the value `x` a member of `group`, with the member calls of its versions, or with `holds =
false` no longer one.
"""
function membership!(workspace::Workspace, x::String, group::String, holds::Bool)::Nothing
    groups = get!(Vector{String}, workspace.groups, x)
    changed = holds != (group in groups)
    holds ? (changed && push!(groups, group)) : filter!(!=(group), groups)
    isempty(groups) && delete!(workspace.groups, x)
    changed && write!(workspace, x)
    for row in copy(get(workspace.versions, x, Row[]))
        holds ? member!(workspace, x, row, group) : row!(workspace, "member process:$x@$(row.index) in $group", nothing)
    end
    return nothing
end

"""
    calls!(workspace, x, row)

Add, change or release the calls of `process` for the version `v` of the value `x` that `row`
gives: `process(project, v)`; `process(project, v, members)` when `v` is a group; and
`process(project, v, group)` for each group of `x`. Each call exists when a method of the project
takes the types of its arguments, and `v` has a result.
"""
function calls!(workspace::Workspace, x::String, row::Row)::Nothing
    project, value = workspace.project, output(workspace, row, x)
    key, version = "$x@$(row.index)", Part(Input(workspace.catalog, row), x)
    takes = value !== nothing && asked(workspace, hasmethod, process, Tuple{typeof(project),value.type})
    row!(workspace, "process:" * key, takes ? Computation(process, project, version) : nothing)
    T = value === nothing || value.members === nothing ? nothing : asked(workspace, member_type, process, typeof(project), value.type)
    row!(workspace, "group process:" * key, T === nothing ? nothing : Computation(process, project, version, MemberValues{T}(x)),
        T === nothing ? String[] : value.members)
    foreach(group -> member!(workspace, x, row, group), copy(get(workspace.groups, x, String[])))
    return nothing
end

"""
    member!(workspace, x, row, group)

Add, change or release the member call `process(project, v, g)` of the version `v` of `x` that `row`
gives, where `g` is the latest version of `group` that does not come from the result of the call
(see [`latest`](@ref)).
"""
function member!(workspace::Workspace, x::String, row::Row, group::String)::Nothing
    catalog, project, value = workspace.catalog, workspace.project, output(workspace, row, x)
    key = "member process:$x@$(row.index) in $group"
    at = value === nothing ? nothing : latest(workspace, group; T=Any, skip=get(workspace.rows, key, Catalogs.NOWHERE))
    takes = at !== nothing && asked(workspace, hasmethod, process, Tuple{typeof(project),value.type,output(workspace, at, group).type})
    row!(workspace, key, takes ?
        Computation(process, project, Part(Input(catalog, row), x), Part(Input(catalog, at), group)) : nothing)
    return nothing
end

# The keys of the calls of the version of `x` that `row` gives.
call_keys(workspace::Workspace, x::String, row::Row)::Vector{String} =
    ["process:$x@$(row.index)"; "group process:$x@$(row.index)";
     ["member process:$x@$(row.index) in $group" for group in get(workspace.groups, x, String[])]]

"""
    row!(workspace, key, computation, held=String[])

Add the row of `process` that `workspace.rows` holds under `key`, such as `"process:a/1@3"`, or give
it `computation` when it has another computation. `nothing` releases the row. The row is one deeper
than the version that it takes, and until it has a result, it is a version of that value. A group
process takes the values of the members `held`.
"""
function row!(workspace::Workspace, key::String, value::Union{Nothing,Computation}, held::Vector{String}=String[])::Nothing
    catalog, items = workspace.catalog, workspace.items
    row = get(workspace.rows, key, nothing)
    group = value !== nothing && value.args[end] isa MemberValues
    if value === nothing
        row === nothing && return nothing
        delete!(workspace.rows, key)
        release!(workspace, row)
    elseif row === nothing
        row = add!(catalog, value)
        hold!(catalog, row)
        workspace.rows[key] = row
        write!(items, items.rows.depth, row.index, items.rows.depth[value.args[2].of.row] + 1)
        ## During a scan, the cache restores what it can first: the scan wants the rows when it ends.
        workspace.background_processing && !source_scan_running(workspace) && want!(catalog, row, BACKGROUND_ITEM)
        given!(workspace, row, nothing)
        group && members!(workspace, row, held)
        restore!(workspace, row)
    else
        isequal(catalog[row], value) || replace!(catalog, row, value)
        group && members!(workspace, row, held)
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
    write!(workspace.items, workspace.items.rows.depth, row.index, nothing)
    release!(workspace.catalog, row)
    return nothing
end

"""
    latest(workspace, id; T=nothing, skip=NOWHERE) -> Union{Nothing,Row}

The row of the latest version of the value `id`. With `T`, the latest row that gave a value of type
`T`; without, also a row that did not run yet. A version that reads the row `skip`, directly or
through other rows, is left out: the call of `skip` takes its other inputs this way, so that it
never takes a version that comes from its own result. `nothing` when there is none.
"""
function latest(workspace::Workspace, x::String; T=nothing, skip::Row=Catalogs.NOWHERE)::Union{Nothing,Row}
    for row in Iterators.reverse(get(workspace.versions, x, Row[]))
        skip != Catalogs.NOWHERE && Catalogs.reads(workspace.catalog, row, skip) && continue
        T === nothing && return row
        found = output(workspace, row, x)
        found !== nothing && found.type <: T && return row
    end
    return nothing
end

# The value with id `x` that `row` gave, or `nothing`.
function output(workspace::Workspace, row::Row, x::String)::Union{Nothing,Output}
    found = something(workspace.items.rows.outputs[row], Output[])
    index = findfirst(output -> output.id == x, found)
    return index === nothing ? nothing : found[index]
end

# The latest version of the value `x` that a row gave, or `nothing`.
function output(workspace::Workspace, x::String)::Union{Nothing,Output}
    row = latest(workspace, x; T=Any)
    return row === nothing ? nothing : output(workspace, row, x)
end

"""
    members!(workspace, row, ids)

Make the row of a group process take the values of the members `ids`, in their order, of the type
`T` of its argument `MemberValues{T}`, in place of those it took. `nothing` takes none, for a row
that leaves or has no members any more. It changes nothing when the row takes these members
already, and else takes the time of the number of members.
"""
function members!(workspace::Workspace, row::Row, ids::Union{Nothing,Vector{String}})::Nothing
    catalog, before = workspace.catalog, get(workspace.taken, row, nothing)
    T = ids === nothing ? nothing : eltype(catalog[row].args[end])
    before !== nothing && before.T == T && isequal(before.root, ids) && return nothing
    ## Leave every value that the row takes, also those that it took after it got its members.
    for (x, found) in (before === nothing ? () : before.rows)
        found.row == Catalogs.NOWHERE || Catalogs.disconnect!(catalog, row, found.row)
        takers = filter!(!=(row), workspace.takers[x])
        isempty(takers) && delete!(workspace.takers, x)
    end
    delete!(workspace.taken, row)
    ids === nothing && return nothing
    ## The order of the members counts in the revision, as the values do.
    workspace.taken[row] = Taken(T, ids, Dict(), hash(ids))
    foreach(x -> input!(workspace, row, x, 1), ids)
    return nothing
end

"""
    member_values(workspace, row) -> Vector{Pair{String,Row}}

The ids of the values that the row of a group process takes, each with the row of
the version that it takes, in the order of the members: each member, then the values that it gives
when it is a source item, and the members of a group that stands for its members. It takes the time
of the number of members, as the call that reads these values does.
"""
function member_values(workspace::Workspace, row::Row)::Vector{Pair{String,Row}}
    rows, found, seen = workspace.taken[row].rows, Pair{String,Row}[], Set{String}()
    function visit(x)
        (x in seen || !haskey(rows, x)) && return
        push!(seen, x)
        rows[x].row == Catalogs.NOWHERE ? foreach(visit, get(workspace.members, x, String[])) : push!(found, x => rows[x].row)
        foreach(visit, values(workspace, x))
    end
    foreach(visit, workspace.taken[row].root)
    return found
end

"""
    input!(workspace, row, id, change=0)

Follow the value `id` among the values that the row of a group takes, after its versions changed,
or after one more (`change` 1) or one fewer (`change` -1) of the ids above it lead to it. The row
takes the latest version of the type `T` of its argument `MemberValues{T}` that does not come from
its own result (see [`latest`](@ref)), or a later version that did not run yet but will: it is
wanted or requested, and does not read a failed row. A source item stands for the values that it
gives, and for its read while that will run, and a group without such a version stands for its
members. The row reads the row of each version that it takes, and its revision follows theirs.
"""
function input!(workspace::Workspace, row::Row, x::String, change::Int=0)::Nothing
    catalog, taken = workspace.catalog, workspace.taken[row]
    before = get(taken.rows, x, (row=Catalogs.NOWHERE, term=UInt64(0), paths=Int32(0)))
    paths, after = before.paths + change, Catalogs.NOWHERE
    runs(other) = Catalogs.state(catalog, other) in (Catalogs.MISSING, Catalogs.STALE) &&
        Catalogs.wanted(catalog, other) && !Catalogs.stuck(catalog, other)
    if paths > 0
        for version in Iterators.reverse(get(workspace.versions, x, Row[]))
            Catalogs.reads(catalog, version, row) && continue
            found = output(workspace, version, x)
            (found === nothing ? runs(version) : found.type <: taken.T) && (after = version; break)
        end
        read = get(workspace.sources, x, Catalogs.NOWHERE)
        after == Catalogs.NOWHERE && read != Catalogs.NOWHERE && runs(read) && (after = read)
    end
    ## The new row is connected first, so that a row that the group reads twice stays.
    after == before.row || after == Catalogs.NOWHERE || Catalogs.connect!(catalog, row, after)
    after == before.row || before.row == Catalogs.NOWHERE || Catalogs.disconnect!(catalog, row, before.row)
    term = after == Catalogs.NOWHERE ? UInt64(0) : value_revision(x, Catalogs.revision(catalog, after))
    taken.revision += term - before.term
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
    haskey(workspace.sources, x) && (before.paths > 0) != (paths > 0) &&
        foreach(v -> v == x || input!(workspace, row, v, paths > 0 ? 1 : -1), values(workspace, x))
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
# again after a code change. It looks at the latest methods, also when the caller runs in an older
# world, as code that defines the methods of a project and opens its workspace in one function.
asked(workspace::Workspace, query, arguments...) =
    get!(() -> Base.invokelatest(query, arguments...), workspace.methods, (query, arguments...))

# The id of the value whose version a row of the pipeline takes: for a read, the source item that
# it reads, and for the source group, the source.
version_of(value::Computation)::String = value.f === process ? value.args[2].id : first(read_of(value))

# The id and the label of what the row of a read reads: a source item, or for the source group, the
# source.
read_of(value::Computation) = value.f === SourceGroup ? (value.args[1], value.args[2]) : (id(value.args[3]), label(value.args[3]))

# The id of the source item that the values of a row of the pipeline come from, or of the source for
# the source group.
function source(workspace::Workspace, row::Row)::String
    value = workspace.catalog[row]
    value.f === SourceGroup && return value.args[1]
    length(value.args) >= 3 && value.args[3] isa AbstractDataSourceItem && return id(value.args[3])
    return source(workspace, value.args[2].of.row)
end
