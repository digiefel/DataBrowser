using DataBrowserGUI: CodeFile, JuliaSyntax, syntax
using .JuliaSyntax: SyntaxNode, byte_range, children, kind, sourcetext, @K_str

# A value given to a call, such as `color = :Chip` of `mapping(...)`: its name, a position (1 for
# the first value) or a symbol, and its bytes in the code.
struct EntryCode
    name::Union{Int,Symbol}
    # The bytes of the value.
    value::UnitRange{Int}
    # The bytes of the whole value with its name, as in `color = :Chip`.
    range::UnitRange{Int}
end

# A call such as `mapping(...)` or `visual(...)`, or a named tuple such as `(; label = "V")`: its
# bytes, and its values, positions first.
struct CallCode
    range::UnitRange{Int}
    entries::Vector{EntryCode}
end

# A line of the block of `@plot` that is a layer, that is, not a `scales`, `legend` or `theme` line.
struct LineCode
    # The bytes of the line, after `@invisible` if it has one.
    range::UnitRange{Int}
    # The bytes of `@invisible ` before the line, or `nothing` when the line is drawn.
    invisible::Union{Nothing,UnitRange{Int}}
    # The name the line gives to its value, as in `contacts = fit(...)`, or `nothing`.
    name::Union{Nothing,Symbol}
    # The line's own mapping, a factor of its product such as `mapping(; marker=:Site) * visual(Scatter)`.
    mapping::Union{Nothing,CallCode}
    # The line's `visual(...)`, whose first value is the plot type.
    visual::Union{Nothing,CallCode}
    # The names of the other factors of the line, such as `expectation` or a fit.
    analyses::Vector{String}
    # Whether the line takes the header's mapping: not when it has its own data, `data(...)` or the
    # name of an earlier line, whose value has its data, such as a fit's result.
    inherits::Bool
end

"""
The parts of the last `@plot` of some code, each with its bytes in the code: the mapping of the
header, the lines that are layers, and the last `scales(...)` and `legend(...)` lines. The plot builder reads them to
show the plot's mappings, layers and scales, and changes the code at those bytes.
"""
struct PlotCode
    mapping::Union{Nothing,CallCode}
    lines::Vector{LineCode}
    scales::Union{Nothing,CallCode}
    # The settings of each scale of `scales`, such as `(; label = "V")` for `y`, in its order.
    scale_settings::Vector{Union{Nothing,CallCode}}
    legend::Union{Nothing,CallCode}
    # The last byte of the block, after which a new line goes, and the indent of its lines; `nothing`
    # when `@plot` has no block.
    ending::Union{Nothing,Int}
    indent::String
end

"""
    tryparse(PlotCode, code::CodeFile) -> Union{PlotCode,Nothing}

The parts of the last `@plot` of the code, or `nothing` if the code has none.
"""
function Base.tryparse(::Type{PlotCode}, code::CodeFile)::Union{Nothing,PlotCode}
    plot = last_plot(syntax(code))
    plot === nothing && return nothing
    text = code.text
    arguments = children(plot)[2:end]
    isempty(arguments) && return PlotCode(nothing, LineCode[], nothing, [], nothing, nothing, "")
    header_mapping = factor_call(text, arguments[1], "mapping")
    block = length(arguments) >= 2 && kind(arguments[2]) == K"block" ? arguments[2] : nothing
    statements = block === nothing ? SyntaxNode[] : children(block)
    lines = LineCode[]
    names = Symbol[]
    scales = legend = nothing
    settings = Union{Nothing,CallCode}[]
    for line in statements
        hidden = kind(line) == K"macrocall" && sourcetext(children(line)[1]) == "invisible" && length(children(line)) == 2
        # The line starts after the space that follows `@invisible`.
        start = hidden ? findnext(!isspace, text, last(byte_range(children(line)[1])) + 1) : first(byte_range(line))
        invisible = hidden ? (first(byte_range(line)):start-1) : nothing
        range = start:last(byte_range(line))
        hidden && (line = children(line)[2])
        if is_call(line, "scales")
            scales = call_code(text, line)
            arguments = reduce(vcat, (kind(a) == K"parameters" ? children(a) : [a] for a in children(line)[2:end]); init=SyntaxNode[])
            settings = Union{Nothing,CallCode}[kind(a) == K"=" ? call_code(text, children(a)[2]) : nothing for a in arguments]
        end
        is_call(line, "legend") && (legend = call_code(text, line))
        any(name -> is_call(line, name), ("scales", "legend", "theme")) && continue
        named = kind(line) == K"=" && kind(children(line)[1]) == K"Identifier"
        value = named ? children(line)[2] : line
        own_data = any(factor -> is_call(factor, "data") || kind(factor) == K"Identifier" && Symbol(sourcetext(factor)) in names,
            factors(value))
        analyses = [kind(factor) == K"Identifier" ? sourcetext(factor) : sourcetext(children(factor)[1])
            for factor in factors(value) if !any(name -> is_call(factor, name), ("mapping", "visual", "data")) &&
                (kind(factor) == K"Identifier" || kind(factor) == K"call")]
        name = named ? Symbol(sourcetext(children(line)[1])) : nothing
        push!(lines, LineCode(range, invisible, name, factor_call(text, value, "mapping"),
            factor_call(text, value, "visual"), analyses, !own_data))
        name === nothing || push!(names, name)
    end
    ending = isempty(statements) ? nothing : last(byte_range(statements[end]))
    first_line = isempty(statements) ? nothing : first(byte_range(statements[1]))
    indent = first_line === nothing ? "    " : text[something(findprev('\n', text, first_line), 0)+1:first_line-1]
    return PlotCode(header_mapping, lines, scales, settings, legend, ending, indent)
end

# The last `@plot` call in the tree, or `nothing`.
function last_plot(node::SyntaxNode)::Union{Nothing,SyntaxNode}
    found = nothing
    for child in something(children(node), SyntaxNode[])
        inner = last_plot(child)
        inner === nothing || (found = inner)
    end
    found === nothing && kind(node) == K"macrocall" && sourcetext(children(node)[1]) == "plot" && return node
    return found
end

is_call(node::SyntaxNode, name::String) =
    kind(node) == K"call" && !isempty(children(node)) && sourcetext(children(node)[1]) == name

# The factors of a product such as `data(t) * mapping(...) * visual(Lines)`, or the node itself.
function factors(node::SyntaxNode)::Vector{SyntaxNode}
    product = kind(node) == K"call" && length(children(node)) >= 3 && sourcetext(children(node)[2]) == "*"
    return product ? filter(factor -> sourcetext(factor) != "*", children(node)) : [node]
end

# The call of that name among the factors of a product, such as its `mapping(...)`. The positions
# of `mapping` written by name, as in `mapping(; x=:gap)`, are read as positions.
function factor_call(text::String, node::SyntaxNode, name::String)::Union{Nothing,CallCode}
    index = findfirst(factor -> is_call(factor, name), factors(node))
    index === nothing && return nothing
    call = call_code(text, factors(node)[index])
    name == "mapping" || return call
    position(entry) = entry.name in (:x, :y, :z) ? EntryCode(findfirst(==(entry.name), (:x, :y, :z)), entry.value, entry.range) : entry
    return CallCode(call.range, sort(map(position, call.entries); by=entry -> entry.name isa Int ? (0, entry.name) : (1, 0)))
end

# The bytes of a node without the spaces and line breaks around it, which JuliaSyntax can count
# as part of the node.
function trimmed(text::String, node::SyntaxNode)::UnitRange{Int}
    range = byte_range(node)
    start = something(findnext(!isspace, text, first(range)), first(range))
    stop = something(findprev(!isspace, text, last(range)), last(range))
    return start:stop
end

# The values of a call, or of a named tuple such as `(; label = "V")`; `nothing` for any other node.
function call_code(text::String, node::SyntaxNode)::Union{Nothing,CallCode}
    kind(node) in (K"call", K"tuple") || return nothing
    arguments = kind(node) == K"call" ? children(node)[2:end] : children(node)
    entries = EntryCode[]
    entry(name, argument, value) = push!(entries, EntryCode(name, trimmed(text, value), trimmed(text, argument)))
    # A value without a name, even after `;` where Julia refuses it, is read as the next position.
    read(argument) = kind(argument) == K"=" ?
        entry(Symbol(sourcetext(children(argument)[1])), argument, children(argument)[2]) :
        entry(count(e -> e.name isa Int, entries) + 1, argument, argument)
    for argument in arguments
        kind(argument) == K"parameters" ? foreach(read, children(argument)) : read(argument)
    end
    # A named tuple of settings has only names; other tuples are read as code.
    kind(node) == K"tuple" && any(e -> e.name isa Int, entries) && return nothing
    # Positions come first, as `mapping` takes them.
    return CallCode(byte_range(node), sort(entries; by=e -> e.name isa Symbol))
end
