"""
One registered item pipeline.

Immutable, and parameterized on the concrete type of every callback. `Function`-typed fields would
make each stage call a dynamic dispatch through an abstract field, once per item; with concrete
parameters, the recipe fully determines the call. The heterogeneity moves to the project's recipe
vector, where it belongs: selecting a recipe is one dynamic step, and a function barrier then
specializes the whole stage.

Re-registering a name replaces the recipe *value* in its project. It never defines methods, so
registrations cannot accumulate and there is no world-age problem.
"""
struct ItemRecipe{Detect,Read,Expand,Process,Analyze,Label,Collection,Id}
    kind::Symbol
    detect::Detect
    read::Read
    expand::Expand
    process::Process
    analyze::Analyze
    label::Label
    collection::Collection
    id::Id
    # The line of the project's code that registered the recipe.
    registered::LineNumberNode
end

"""
The callbacks that run in every collection of one level, over the items below it of one kind, or of
every kind when `members` is `nothing`.
"""
struct CollectionRecipe{Process,Analyze}
    level::Symbol
    members::Union{Nothing,Symbol}
    process::Process
    analyze::Analyze
    registered::LineNumberNode
end

"""
A callback project assembled from registered recipes.

The dialect's implementation of `AbstractProject`, and nothing more: reading and data processing
are defined by the registered callbacks, plot registration lives in `DataBrowserPlots`, and
package-owned cache, job, and browser state does not belong here.

`recipes` is deliberately a `Vector` of differently parameterized recipes. Detection order is
registration order — the first match wins — so the vector has to preserve order, and different
registrations genuinely have different callback types.

`values` is the file of the `DuckDBStore` that keeps the results of every item type, so they stay
available when the workspace opens again.
"""
mutable struct Project <: AbstractProject
    name::String
    description::String
    recipes::Vector{ItemRecipe}
    collections::Vector{CollectionRecipe}
    values::String
end

DataBrowserAPI.storage(project::Project, ::Type) = DuckDBStore(project.values)
