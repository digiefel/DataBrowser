"""
One registered item pipeline: the callbacks given to `register_item!`, and the module and the line
of the code that registered them. `define!` makes the methods of the registration from it, and
registering the same kind again replaces the recipe and its methods.
"""
struct ItemRecipe
    kind::Symbol
    detect
    read
    expand
    process
    analyze
    label
    collection
    id
    ## The module and the line of the project's code that registered the recipe.
    mod::Module
    registered::LineNumberNode
end

"""
The callbacks that run in every collection of one level, over the items below it of one kind, or of
every kind when `members` is `nothing`.
"""
struct CollectionRecipe
    level::Symbol
    members::Union{Nothing,Symbol}
    process
    analyze
end

"""
A project made of registrations: the `read` and `process` methods of its type run the callbacks
given to `register_item!` and `register_collection!`. Plots are registered with `DataBrowserPlots`.

`recipes` keeps the order of registration, in which `read` asks the `detect` callbacks: the first
that accepts a source item wins.

`values` is the file of the `DuckDBStore` that keeps the results of every item type, so they stay
available when the workspace opens again.

`Name` is the name of the project as a `Symbol`. The registrations define methods for
`Project{Name}`, so projects with different names have methods of their own, while projects with
the same name share them: the latest registration into any of them decides what they run.
"""
mutable struct Project{Name} <: AbstractProject
    name::String
    description::String
    recipes::Vector{ItemRecipe}
    collections::Vector{CollectionRecipe}
    values::String
end

DataBrowserAPI.storage(project::Project, ::Type) = DuckDBStore(project.values)
# The groups of the source and of its source items take nothing to make again.
DataBrowserAPI.storage(::Project, ::Type{<:Union{SourceGroup,SourceItemGroup}}) = nothing
