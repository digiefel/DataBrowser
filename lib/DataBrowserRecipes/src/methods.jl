"""
Registrations as methods.

Each registration defines ordinary methods of `read`, `process` and `label` for the type of its
project, `Project{Name}`, so a workspace runs a registered project as it runs any other project.
A method is defined in the module of the code that registered it, at the line of the registration,
and holds the callbacks of the registration as values. So the code revision of a method covers its
callbacks and the code they call, and registering a changed callback makes the results of the
method stale.
"""

# Define the method `DataBrowserAPI.f(arguments...)` with `body`, in `mod` at `line`.
define(mod::Module, line::LineNumberNode, f::Symbol, arguments::Vector, body) = Core.eval(mod,
    Expr(:function, Expr(:call, Expr(:., DataBrowserAPI, QuoteNode(f)), arguments...),
        Expr(:block, line, body)))

# Delete the method of `f` for exactly the argument types `types`, when there is one.
forget(f, types::Type...) = foreach(Base.delete_method,
    [m for m in methods(f, Tuple{types...}) if m.sig == Tuple{typeof(f),types...}])

"""
Define the methods of one item registration, and delete those it no longer has: the `process` of
what its `read` gives, when it has `expand`, `process` or `analyze`, and the `label` of its items.
"""
function define!(project::Project{N}, r::ItemRecipe) where {N}
    P, R, D = Project{N}, RegisteredDataItem{r.kind}, ReadData{r.kind}
    r.expand === r.process === r.analyze === nothing ? forget(process, P, D) : define(r.mod, r.registered,
        :process, [:(::$P), :(value::$D)], :($_items(value, $(r.expand), $(r.id), $(r.process), $(r.analyze))))
    r.label === nothing ? forget(label, P, R) : define(r.mod, r.registered, :label,
        [:(::$P), :(item::$R)], :(String($(r.label)(item.data, item.metadata))))
    return nothing
end

"""
Define the methods of the whole project: its `read`, which makes a [`SourceItemGroup`](@ref) of a
source item with members and asks the `detect` callback of each item registration, in the order of
registration, for any other source item; the `process` of the [`SourceGroup`](@ref) of the source,
which makes the collections; and the group `process` of a collection, which runs the callbacks of
its level. Without a `collection` callback, the project has no `process` of the `SourceGroup`,
and without collection callbacks, it has no group `process` of a collection.
"""
function define!(project::Project{N}, mod::Module, line::LineNumberNode) where {N}
    P, C, V = Project{N}, NamedCollection{<:Any,:made}, AbstractVector{RegisteredDataItem{<:Any,:made}}
    ## What `read` gives is the item, unless the item needs one of its callbacks.
    asks = [Expr(:block, r.registered, :($(r.detect)(item)::Bool && return $_read(
        $(r.expand === r.process === r.analyze === nothing ? RegisteredDataItem{r.kind,:made} : ReadData{r.kind}),
        $(r.read), item))) for r in project.recipes]
    group = :(isempty($members(source, item)) ||
        return $SourceItemGroup(item, map($id, $members(source, item))))
    define(mod, line, :read, [:(::$P), :(source::$AbstractDataSource), :(item::$AbstractDataSourceItem)],
        Expr(:block, group, asks..., :(return $AbstractDataItem[])))
    paths = [:($(QuoteNode(r.kind)) => $(r.collection))
        for r in project.recipes if r.collection !== nothing]
    waiting = Tuple(unique(c.level for c in project.collections if c.process !== nothing || c.analyze !== nothing))
    levels = [:(($(QuoteNode(c.level)), $(QuoteNode(c.members)), $(c.process), $(c.analyze)))
        for c in project.collections]
    isempty(paths) ? forget(process, P, SourceGroup, V) : define(mod, line, :process,
        [:(::$P), :(::$SourceGroup), :(items::$V)], :($_collections(items, ($(paths...),), $waiting)))
    isempty(waiting) ? forget(process, P, C, V) : define(mod, line, :process,
        [:(::$P), :(collection::$C), :(items::$V)], :($_processed(collection, items, ($(levels...),))))
    return nothing
end
