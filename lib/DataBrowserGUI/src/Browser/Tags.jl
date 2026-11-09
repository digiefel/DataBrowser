import DataBrowserCore.Workspace
import DataBrowserCore.Workspace: Tag, tags, tag!, untag!
using DataBrowserAPI: AbstractGroup

"""Whether the workspace read its tags; they cannot be shown or changed otherwise."""
_tags_ready(state::BrowserState)::Bool = isempty((@atomic state.workspace.shared).tags_error)

"""
    Contains(text)

The filter that passes the values whose text contains `text`, ignoring case: the filter of values of
any type.
"""
struct Contains <: MetadataFilter
    text::String
end

Base.in(value, filter::Contains)::Bool = occursin(lowercase(filter.text), lowercase(string(value)))

"""
    Between{T}(from, to)

The filter that passes the values of type `T` from `from` to `to`, both included, as read by
`tryparse(T, text)`; an empty bound sets no limit. With `T = DateTime`, `from = "2026-11-05"` and an
empty `to`, every time from the start of 5 November 2026 passes. When a bound is not a value of type
`T`, no value passes.
"""
struct Between{T} <: MetadataFilter
    from::String
    to::String
    ## The bounds as values of type `T`, `nothing` when empty, and whether each bound that is not
    ## empty is a value of type `T`.
    low::Union{Nothing,T}
    high::Union{Nothing,T}
    readable::Bool
end

function Between{T}(from::AbstractString, to::AbstractString) where {T}
    bound(text) = isempty(strip(text)) ? nothing : tryparse(T, strip(text))
    low, high = bound(from), bound(to)
    readable = (low !== nothing || isempty(strip(from))) && (high !== nothing || isempty(strip(to)))
    return Between{T}(String(from), String(to), low, high, readable)
end

Base.in(value, filter::Between{T}) where {T} = filter.readable && value isa T &&
    (filter.low === nothing || filter.low <= value) && (filter.high === nothing || value <= filter.high)

"""
    SavedFilter(texts)

The filter of a condition read from `databrowser.toml`, with the texts of its fields, until the filter
bar knows the type of the values of its key. It passes every value. The filter bar then replaces it
with the filter of that type, with the same texts.
"""
struct SavedFilter <: MetadataFilter
    texts::Tuple{Vararg{String}}
end

Base.in(_, ::SavedFilter)::Bool = true

"""The texts of the fields of a filter, which `databrowser.toml` saves."""
_filter_texts(::Nothing)::Tuple{Vararg{String}} = ()
_filter_texts(filter::SavedFilter)::Tuple{Vararg{String}} = filter.texts
_filter_texts(filter::Contains)::Tuple{Vararg{String}} = (filter.text,)
_filter_texts(filter::Between)::Tuple{Vararg{String}} = (filter.from, filter.to)

MetadataFilter(T::Type) = hasmethod(tryparse, Tuple{Type{T},String}) ? Between{T}("", "") : Contains("")

"""
Return whether the metadata `value` of an item matches `condition`. `missing` stands for an item
without the key.
"""
_matches(condition::MetadataCondition, value)::Bool =
    !ismissing(value) && (condition.filter === nothing || value in condition.filter)

(condition::MetadataCondition)(row)::Bool = _matches(condition,
    hasproperty(row, condition.key) ? getproperty(row, condition.key) : missing)

"""
The filters set in the filter bar of `state`. While the workspace cannot read its tags, the tags
filter nothing, so that a broken `tags.txt` never hides data.
"""
function TreeFilters(state::BrowserState)::TreeFilters
    chosen = _tags_ready(state) ? sort!(collect(state.tag_visibility)) : Pair{String,Symbol}[]
    having(list, visibility) = Tuple(first(entry) for entry in list if last(entry) == visibility)
    return TreeFilters(having(chosen, :hidden), having(chosen, :only),
        having(state.conditions, :hidden), having(state.conditions, :only))
end

"""
Return whether `filters` hide an item with the tags `names`: when the item has a hidden tag or
matches a hidden condition. `matches(condition)` tells whether the item matches `condition`.
"""
_hides(filters::TreeFilters, names, matches)::Bool =
    any(in(names), filters.hidden_tags) || any(matches, filters.hidden)

"""
Return whether an item with the tags `names` has every tag and matches every condition that
`filters` show alone. `matches(condition)` tells whether the item matches `condition`.
"""
_keeps(filters::TreeFilters, names, matches)::Bool =
    all(in(names), filters.only_tags) && all(matches, filters.only)

"""
The selected ids that the workspace has and that the filter bar leaves visible: those that no
filter hides, and that pass the filters shown alone, unless they are groups. The selection in the
workspace is left untouched. The result is kept for the next calls: do not change it.
"""
function _visible_selection(state::BrowserState)::VisibleSelection
    workspace, filters = state.workspace, TreeFilters(state)
    ## The tree and every window ask at each frame; looking up each selected id costs time in
    ## proportion to the selection. The ids depend on the selection, the ids of the workspace and
    ## the filters, each replaced whole when it changes, and read before the ids are looked up.
    ## While a filter reads the metadata or the types of the items, these count too: they can change
    ## with each version of the workspace.
    version, shared = (@atomic workspace.items.version), (@atomic workspace.shared)
    reads = !isempty(filters.only_tags) || !isempty(filters.hidden) || !isempty(filters.only)
    key = (shared.selection, version.index, shared.tags, filters, reads ? version.generation : 0)
    kept = state.visible_selection
    kept !== nothing && kept.key === key && return kept
    ids = filter(shared.selection) do x
        haskey(workspace, x) || return false
        names = [tag.name for tag in tags(workspace, x)]
        matches(condition) =
            _matches(condition, get(Workspace.metadata(workspace, x), condition.key, missing))
        _hides(filters, names, matches) && return false
        ## A group stays: the tree shows it above the items that pass.
        return Workspace.valuetype(workspace, x) <: AbstractGroup || _keeps(filters, names, matches)
    end
    visible = VisibleSelection(key, ids, Set(ids))
    state.visible_selection = visible
    return visible
end
