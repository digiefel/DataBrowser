using DataBrowserGUI: CodeFile, JuliaSyntax, syntax
using .JuliaSyntax: SyntaxNode, byte_range, children, kind, sourcetext, @K_str

# A `mapping(...)` of the code: its bytes, and the bytes of the value of each role. A position is
# a number, 1 for x and 2 for y; a named role is a symbol, such as `:color`.
struct MappingCode
    range::UnitRange{Int}
    roles::Vector{Pair{Union{Int,Symbol},UnitRange{Int}}}
end

# A line of the block of `@plot` that is a layer, that is, not a `scales` or `legend` line.
struct LineCode
    # The bytes of the line, after `@invisible` if it has one.
    range::UnitRange{Int}
    # The bytes of `@invisible ` before the line, or `nothing` when the line is drawn.
    invisible::Union{Nothing,UnitRange{Int}}
    # The name the line gives to its value, as in `contacts = fit(...)`, or `nothing`.
    name::Union{Nothing,Symbol}
    # The line's own mapping, a factor of its product such as `mapping(; marker=:Site) * visual(Scatter)`.
    mapping::Union{Nothing,MappingCode}
    # Whether the line takes the header's mapping: not when it has its own data, `data(...)` or the
    # name of an earlier line, whose value has its data, such as a fit's result.
    inherits::Bool
end

"""
The parts of the last `@plot` of some code, each with its bytes in the code: the mapping of the
header and the lines that are layers. The plot builder reads them to show the plot's roles and
layers, and changes the code at those bytes.
"""
struct PlotCode
    mapping::Union{Nothing,MappingCode}
    lines::Vector{LineCode}
end

"""
    tryparse(PlotCode, code::CodeFile) -> Union{PlotCode,Nothing}

The parts of the last `@plot` of the code, or `nothing` if the code has none.
"""
function Base.tryparse(::Type{PlotCode}, code::CodeFile)::Union{Nothing,PlotCode}
    plot = last_plot(syntax(code))
    plot === nothing && return nothing
    arguments = children(plot)[2:end]
    isempty(arguments) && return PlotCode(nothing, LineCode[])
    header_mapping = mapping_code(arguments[1])
    block = length(arguments) >= 2 && kind(arguments[2]) == K"block" ? arguments[2] : nothing
    lines = LineCode[]
    names = Symbol[]
    for line in (block === nothing ? SyntaxNode[] : children(block))
        hidden = kind(line) == K"macrocall" && sourcetext(children(line)[1]) == "invisible" && length(children(line)) == 2
        # The line starts after the space that follows `@invisible`.
        start = hidden ? findnext(!isspace, code.text, last(byte_range(children(line)[1])) + 1) : first(byte_range(line))
        invisible = hidden ? (first(byte_range(line)):start-1) : nothing
        range = start:last(byte_range(line))
        hidden && (line = children(line)[2])
        (is_call(line, "scales") || is_call(line, "legend")) && continue
        named = kind(line) == K"=" && kind(children(line)[1]) == K"Identifier"
        value = named ? children(line)[2] : line
        own_data = any(factor -> is_call(factor, "data") || kind(factor) == K"Identifier" && Symbol(sourcetext(factor)) in names,
            factors(value))
        name = named ? Symbol(sourcetext(children(line)[1])) : nothing
        push!(lines, LineCode(range, invisible, name, mapping_code(value), !own_data))
        name === nothing || push!(names, name)
    end
    return PlotCode(header_mapping, lines)
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

# The `mapping(...)` among the factors of a product.
function mapping_code(node::SyntaxNode)::Union{Nothing,MappingCode}
    index = findfirst(factor -> is_call(factor, "mapping"), factors(node))
    index === nothing && return nothing
    call = factors(node)[index]
    roles = Pair{Union{Int,Symbol},UnitRange{Int}}[]
    named(argument) = push!(roles, Symbol(sourcetext(children(argument)[1])) => byte_range(children(argument)[2]))
    for argument in children(call)[2:end]
        if kind(argument) == K"parameters"
            foreach(named, children(argument))
        elseif kind(argument) == K"="
            named(argument)
        else
            push!(roles, count(role -> first(role) isa Int, roles) + 1 => byte_range(argument))
        end
    end
    # Positions come first, as `mapping` takes them.
    return MappingCode(byte_range(call), sort(roles; by=role -> first(role) isa Symbol))
end
