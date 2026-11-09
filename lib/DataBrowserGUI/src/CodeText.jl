import CImGui as ig
using .JuliaSyntax: @K_str

# The colors of the kinds of Julia tokens, for ImGui's dark style.
const CODE_COLORS = (
    call=(0.51f0, 0.67f0, 1.0f0),
    symbol=(0.54f0, 0.87f0, 1.0f0),
    number=(0.97f0, 0.55f0, 0.42f0),
    string=(0.76f0, 0.91f0, 0.55f0),
    operator=(0.6f0, 0.66f0, 0.75f0),
    keyword=(0.78f0, 0.57f0, 0.92f0),
    comment=(0.45f0, 0.5f0, 0.58f0),
)

"""
    code_tokens(text) -> Vector{Tuple{String,Symbol}}

The tokens of Julia code, each with the kind that gives its color: `:call`, `:symbol`, `:number`,
`:string`, `:operator`, `:keyword`, `:comment`, or `:plain` for names and punctuation.
"""
function code_tokens(text::AbstractString)::Vector{Tuple{String,Symbol}}
    tokens = JuliaSyntax.tokenize(text)
    found = Tuple{String,Symbol}[]
    ## Whether the last token that is not a space ends a value, after which a colon is a range, as
    ## in `1:n`, not the start of a symbol.
    after_value = false
    for (index, token) in enumerate(tokens)
        kind = JuliaSyntax.kind(token)
        piece = text[token.range]
        next = index < length(tokens) ? JuliaSyntax.kind(tokens[index+1]) : nothing
        role = if kind == K":" && next == K"Identifier" && !after_value
            :symbol
        elseif kind == K"Identifier" && !isempty(found) && found[end] == (":", :symbol)
            :symbol
        elseif kind == K"Identifier"
            !Base.isidentifier(piece) ? :operator : next == K"(" ? :call : :plain
        elseif JuliaSyntax.is_keyword(kind) || kind == K"Bool"
            :keyword
        elseif kind in (K"Integer", K"Float", K"HexInt", K"BinInt", K"OctInt")
            :number
        elseif kind in (K"String", K"\"", K"\"\"\"", K"Char", K"'")
            :string
        elseif kind == K"Comment"
            :comment
        elseif JuliaSyntax.is_operator(kind)
            :operator
        else
            :plain
        end
        push!(found, (piece, role))
        kind == K"Whitespace" || (after_value = kind in (K")", K"]", K"\"", K"Integer", K"Float") ||
            kind == K"Identifier" && Base.isidentifier(piece))
    end
    return found
end

function code_color(role::Symbol, alpha::Float32)::UInt32
    role === :plain && return ig.GetColorU32(ig.ImGuiCol_Text, alpha)
    red, green, blue = getfield(CODE_COLORS, role)
    return ig.GetColorU32(ig.ImVec4(red, green, blue, alpha))
end

"""
    draw_code(draw_list, position, text, width; alpha=1) -> Bool

Draw Julia code on one line with the colors of its tokens, in the current font, from `position`.
Text past `width` is left out and an ellipsis ends the line. Returns whether text was left out.
`alpha` dims the colors, as for code that is not in effect.
"""
function draw_code(draw_list, position, text::AbstractString, width::Real; alpha::Real=1.0f0)::Bool
    x, y = position.x, position.y
    right = x + width
    ellipsis = ig.CalcTextSize("…").x
    for (piece, role) in code_tokens(text)
        size = ig.CalcTextSize(piece).x
        if x + size > right
            ## The characters that fit before the ellipsis.
            fitting = ""
            for character in piece
                x + ig.CalcTextSize(fitting * character).x + ellipsis > right && break
                fitting *= character
            end
            ig.AddText(draw_list, ig.ImVec2(x, y), code_color(role, Float32(alpha)), fitting)
            ig.AddText(draw_list, ig.ImVec2(x + ig.CalcTextSize(fitting).x, y),
                ig.GetColorU32(ig.ImGuiCol_TextDisabled), "…")
            return true
        end
        ig.AddText(draw_list, ig.ImVec2(x, y), code_color(role, Float32(alpha)), piece)
        x += size
    end
    return false
end

"""
    code_text(text)

Show Julia code with the colors of its tokens, keeping its lines, as `TextUnformatted` shows text.
"""
function code_text(text::AbstractString)::Nothing
    for line in split(text, '\n')
        tokens = code_tokens(line)
        isempty(tokens) && ig.TextUnformatted("")
        for (index, (piece, role)) in enumerate(tokens)
            index > 1 && ig.SameLine(0.0f0, 0.0f0)
            ig.PushStyleColor(ig.ImGuiCol_Text, code_color(role, 1.0f0))
            ig.TextUnformatted(piece)
            ig.PopStyleColor()
        end
    end
    return nothing
end
