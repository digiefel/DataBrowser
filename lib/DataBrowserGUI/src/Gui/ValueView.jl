import CImGui as ig

import DataBrowserAPI: draw!, label, prepare!
using DataBrowserAPI: AbstractVisualizer

"""
The visualizer that shows any value as text, as the REPL prints it. It is offered for every value,
so that a window can always show what it is given.
"""
Base.@kwdef mutable struct ValueView <: AbstractVisualizer
    text::String = ""
end

label(::ValueView)::String = "Value"

# The one `prepare!` method that accepts everything: see `prepare!`.
function prepare!(view::ValueView, value, ctx)::Nothing
    # Long values are cut, as in the REPL, so that the text stays quick to draw.
    view.text = sprint(show, MIME"text/plain"(), value; context=(:limit => true, :displaysize => (200, 120)))
    return nothing
end

function draw!(view::ValueView, ctx)::Nothing
    ig.TextUnformatted(view.text)
    return nothing
end
