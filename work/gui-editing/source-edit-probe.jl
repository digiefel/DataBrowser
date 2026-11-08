module EditorSourceEditProbe
let directory = joinpath(@__DIR__, "source-probe", "packages")
    push!(LOAD_PATH, directory)
    try
        @eval import JuliaSyntax
    finally
        pop!(LOAD_PATH)
    end
end
const JS = JuliaSyntax
const assignment_kind = JS.kind(JS.parsestmt(JS.SyntaxNode, "x = 1"))

function nodes(root)
    result = JS.SyntaxNode[]
    function visit(node)
        push!(result, node)
        JS.is_leaf(node) && return
        foreach(visit, JS.children(node))
    end
    visit(root)
    return result
end

function assignment(root, name)
    matches = filter(nodes(root)) do node
        JS.kind(node) == assignment_kind || return false
        children = JS.children(node)
        return length(children) == 2 && JS.sourcetext(first(children)) == String(name)
    end
    length(matches) == 1 || throw(ArgumentError("Expected one assignment for $name"))
    return only(matches)
end

function replace_keyword(source, owner, keyword, replacement; expected_source=source)
    source == expected_source || throw(ArgumentError("Source changed; parse the current revision"))
    tree = JS.parseall(JS.SyntaxNode, source)
    owner_node = assignment(tree, owner)
    keyword_node = assignment(last(JS.children(owner_node)), keyword)
    rhs = last(JS.children(keyword_node))
    JS.parsestmt(JS.SyntaxNode, replacement)
    JS.sourcetext(rhs) == replacement && return source
    range = JS.byte_range(rhs)
    bytes = collect(codeunits(source))
    prefix, suffix = bytes[1:first(range)-1], bytes[last(range)+1:end]
    edited = String(vcat(prefix, collect(codeunits(replacement)), suffix))
    JS.parseall(JS.SyntaxNode, edited)
    @assert collect(codeunits(edited))[1:length(prefix)] == prefix
    @assert collect(codeunits(edited))[end-length(suffix)+1:end] == suffix
    return edited
end

function run()
    source = """
    # μΩ: preserve Unicode, spacing and comments.
    begin
        observations = visual(Scatter; markersize = 6)
        prediction = mapping(:x, :y) *
            visual(Lines;
                linewidth = 2, # keep this μ comment
                linestyle = :solid,
                color = custom_color(theme))
        observations + prediction
    end
    """
    edited = replace_keyword(source, :prediction, :linewidth, "1 + scale")
    edited = replace_keyword(edited, :prediction, :linestyle, ":dash")
    @assert occursin("# μΩ: preserve Unicode, spacing and comments.", edited)
    @assert occursin("linewidth = 1 + scale, # keep this μ comment", edited)
    @assert occursin("color = custom_color(theme)", edited)
    println("Two length-changing edits preserved Unicode comments and unrelated expressions.")

    external = "# saved by another editor: α\n" * edited
    refused = false
    try
        replace_keyword(external, :prediction, :linewidth, "3"; expected_source=edited)
    catch error
        error isa ArgumentError || rethrow()
        refused = true
    end
    @assert refused
    refreshed = replace_keyword(external, :prediction, :linewidth, "3")
    @assert startswith(refreshed, "# saved by another editor: α\n")
    @assert replace_keyword(refreshed, :prediction, :linewidth, "3") == refreshed
    println("Stale edit refused; refreshed edit retained the external change; no-op retained source.")

    observation = "    observations = visual(Scatter; markersize = 6)\n"
    reordered = replace(refreshed, observation => "")
    reordered = replace(reordered, "    observations + prediction\n" => observation * "    observations + prediction\n")
    reordered = replace_keyword(reordered, :prediction, :linestyle, ":dot")
    @assert occursin("linewidth = 3", reordered)
    @assert occursin("linestyle = :dot", reordered)
    println("Owner/keyword lookup survived moving another definition; no stored byte offset was reused.")
    println("JuliaSyntax ", pkgversion(JS), "; Julia ", VERSION)
end

run()
end
