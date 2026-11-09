# Edits of the code that the panel asks for: a value written, a value removed, a line removed.

# How the panel shows the value of a mapping, as parts of a kind: a `:column` by its name, such as
# `data.V` for `:data.V`, any other value as a `:formula` by its code, and the title after `=>` as a
# `:title`.
# TODO: controls for the simple formulas, such as a choice of the columns `string` joins.
function mapping_parts(text::String)::Vector{Tuple{Symbol,String}}
    expression = Meta.parse(text; raise=false)
    title = nothing
    if Meta.isexpr(expression, :call) && length(expression.args) == 3 && expression.args[1] === :(=>) &&
            expression.args[3] isa String
        title = expression.args[3]
        expression = expression.args[2]
        text = String(strip(text[1:prevind(text, first(findlast("=>", text)))]))
    end
    column(e) = e isa QuoteNode && e.value isa Symbol ? String(e.value) :
        Meta.isexpr(e, :call) && e.args == [:ydims] ? "ydims()" :
        Meta.isexpr(e, :.) && length(e.args) == 2 && e.args[2] isa QuoteNode && column(e.args[1]) !== nothing ?
        "$(column(e.args[1])).$(e.args[2].value)" : nothing
    name = column(expression)
    parts = name !== nothing ? [(:column, name)] : [(:formula, text)]
    title === nothing || push!(parts, (:title, title))
    return parts
end

# The name of a value of a call, as the panel shows it: x, y and z for the positions of `mapping`.
entry_name(name::Int) = name <= 3 ? ("x", "y", "z")[name] : string(name)
entry_name(name::Symbol) = String(name)
# The name of a value from the name the panel shows: a position for x, y and z.
entry_key(name::String) = something(findfirst(==(name), ("x", "y", "z")), Symbol(name))

# The names the "+" of a mapping offers: x and y, then the y after the last one, such as `y2`, once
# there is a y, then the named mappings from `names`, that `present` lacks.
# TODO: z, for the plot types that draw in three dimensions.
function mapping_offers(present, names)::Vector{String}
    ys = [name == 2 ? 1 : mapping_order(name)[2] for name in present if name == 2 || mapping_order(name)[1] == 1]
    further = isempty(ys) ? String[] : ["y$(maximum(ys) + 1)"]
    return [entry_name.(setdiff([1, 2], present)); further; sort(String.(setdiff(names, present)))]
end
# Whether a value of `mapping` is a position: x, y, z, or a further y such as `y2`.
is_position(name) = mapping_order(name)[1] < 2

# The named mappings of the layout, which every plot type takes.
const LAYOUT = [:layout, :row, :col, :group]

# The call that holds the values of a target: `(:mapping, 0)` the header's mapping, `(:mapping, i)`
# and `(:visual, i)` those of line `i`, `(:scales, 0)` the `scales(...)` line, `(:scale, k)` the
# settings of its `k`th scale, `(:legend, 0)` the `legend(...)` line, `(:theme, 0)` the `theme(...)`
# line and `(:group, k)` the settings of its `k`th value. `nothing` when the code has no such call yet.
function target_call(plot::PlotCode, (kind, index)::Tuple{Symbol,Int})::Union{Nothing,CallCode}
    kind === :mapping && return index == 0 ? plot.mapping : plot.lines[index].mapping
    kind === :visual && return plot.lines[index].visual
    kind === :scales && return plot.scales
    kind === :legend && return plot.legend
    kind === :theme && return plot.theme
    kind === :group && return plot.theme_groups[index]
    return plot.scale_settings[index]
end

# Write a value into the code: in place of its old value, or after the call's last value. A line
# without its own mapping or visual gets one, and a plot without `scales(...)` or `legend(...)` gets
# that line at the end of its block.
function write_entry!(code::CodeFile, plot::PlotCode, target, name, text::String)::Nothing
    call = target_call(plot, target)
    found = call === nothing ? nothing : findfirst(entry -> entry.name == name, call.entries)
    if found !== nothing
        edit!(code, call.entries[found].value, text)
    elseif call !== nothing && target[1] in (:theme, :visual) && name isa Int
        ## The theme of `theme(...)` goes first.
        opening = findnext('(', code.text, first(call.range))
        next = findnext(!isspace, code.text, opening + 1)
        edit!(code, opening+1:opening, code.text[next] in (';', ')') ? text : "$text, ")
    elseif call !== nothing && isempty(call.entries) && code.text[first(call.range)] == '('
        ## An empty named tuple, `(;)`.
        edit!(code, call.range, "(; $(entry_name(name))=$text)")
    elseif call !== nothing && isempty(call.entries)
        opening = findnext('(', code.text, first(call.range))
        stop = last(call.range) - 1
        separator = occursin(';', code.text[opening+1:stop]) ? " " : "; "
        edit!(code, stop+1:stop, "$separator$(entry_name(name))=$text")
    elseif call !== nothing
        ## After the last value, so that a call over several lines, or with a comma after its last
        ## value, stays as it is written.
        ## A value written with its name, including a position such as `x = :gap`.
        named = any(entry -> entry.range != entry.value, call.entries)
        after = isempty(call.entries) ? last(call.range) - 1 : maximum(last(entry.range) for entry in call.entries)
        edit!(code, after+1:after, "$(named ? ", " : "; ")$(entry_name(name))=$text")
    elseif target[1] === :mapping
        start = first(plot.lines[target[2]].range)
        edit!(code, start:start-1, "mapping(; $(entry_name(name))=$text) * ")
    elseif target[1] === :visual
        stop = last(plot.lines[target[2]].range)
        edit!(code, stop+1:stop, name isa Int ? " * visual($text)" : " * visual(; $name=$text)")
    else
        edit!(code, plot.ending+1:plot.ending, "\n$(plot.indent)$(target[1])($(name isa Int ? text : "$name=$text"))")
    end
    return nothing
end

# Remove a value from the code, with the comma between it and the next value of its kind, a position
# or a named value, or else the separator before it, so that `;` stays before the named values.
function remove_entry!(code::CodeFile, call::CallCode, name)::Nothing
    index = findfirst(entry -> entry.name == name, call.entries)
    entry = call.entries[index]
    next = index < length(call.entries) && typeof(call.entries[index+1].name) == typeof(name) ? call.entries[index+1] : nothing
    range = next !== nothing ? (first(entry.range):first(next.range)-1) :
        index > 1 ? (last(call.entries[index-1].range)+1:last(entry.range)) : entry.range
    edit!(code, range, "")
    return nothing
end

# Remove a line of the block, with its indent.
function remove_line!(code::CodeFile, line)::Nothing
    start = first(something(line.invisible, line.range))
    edit!(code, something(findprev('\n', code.text, start), start):last(line.range), "")
    return nothing
end
