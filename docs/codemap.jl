# The data of the code map: the types of every package, made from the code at each build of the
# docs. JuliaSyntax finds where each `struct` and `abstract type` is written, and reflection on the
# loaded packages gives its fields and its supertype. The page `codemap.md` draws the result.
#
# `codemap(modules, root)` returns the map as plain dictionaries, and `write_codemap` saves it as
# `assets/codemap.js`, a script that sets `window.CODEMAP`, so that the page also works when it is
# opened from disk.
#
# TODO: the calls between functions, from the call sites that JuliaSyntax finds in each method.
# TODO: dispatch and hot paths, from the methods that a benchmark run compiles (MethodAnalysis.jl)
# and from the timings of DataBrowserProfiling.

const JuliaSyntax = Base.JuliaSyntax

# The name of the type that a `struct` or `abstract` node defines: the leftmost identifier of its
# signature, as in `Name{T} <: Super`.
function defined_name(node)
    while !JuliaSyntax.is_leaf(node)
        node = first(JuliaSyntax.children(node))
    end
    return JuliaSyntax.kind(node) == JuliaSyntax.K"Identifier" ? node.val : nothing
end

# Where each type is written: name => (path, line), for the Julia files of `folder` below `root`.
# TODO: two types of one name in two modules of a package get the place of the last one found.
function type_locations(root, folder)
    found = Dict{Symbol,Tuple{String,Int}}()
    isdir(joinpath(root, folder)) || return found
    for (dir, _, names) in walkdir(joinpath(root, folder)), name in names
        endswith(name, ".jl") || continue
        path = joinpath(dir, name)
        tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, read(path, String); filename=path, ignore_errors=true)
        stack = [tree]
        while !isempty(stack)
            node = pop!(stack)
            JuliaSyntax.is_leaf(node) && continue
            if JuliaSyntax.kind(node) in (JuliaSyntax.K"struct", JuliaSyntax.K"abstract")
                type = defined_name(first(JuliaSyntax.children(node)))
                type === nothing || (found[type] = (relpath(path, root), JuliaSyntax.source_line(node)))
            end
            append!(stack, JuliaSyntax.children(node))
        end
    end
    return found
end

# The module `m` and every module defined inside it.
function submodules(m::Module)
    found = [m]
    for name in names(m; all=true)
        inner = isdefined(m, name) ? getfield(m, name) : nothing
        inner isa Module && inner !== m && parentmodule(inner) === m && append!(found, submodules(inner))
    end
    return found
end

# The types of our packages that appear in the type `t`, such as `Row` in `Vector{Union{Nothing,Row}}`.
function named_types(t, ours, found=Set{Any}())
    t isa UnionAll && return named_types(Base.unwrap_unionall(t), ours, found)
    t isa Union && (named_types(t.a, ours, found); named_types(t.b, ours, found); return found)
    t isa DataType || return found
    base = Base.typename(t).wrapper
    base in ours && push!(found, base)
    foreach(p -> named_types(p, ours, found), t.parameters)
    return found
end

"""
    codemap(modules, root) -> Dict

The types of `modules`, the packages of the repository at `root`: for each type, its package, its
file and line, its fields and its supertype, and the edges between types (`subtype` and `field`).
"""
function codemap(modules, root)
    types = Dict{Any,Dict{String,Any}}()
    for package in modules
        folder = joinpath("lib", string(nameof(package)))
        locations = merge(type_locations(root, joinpath(folder, "src")), type_locations(root, joinpath(folder, "ext")))
        ## The modules of the package, and of its extensions that are loaded.
        extensions = isdir(joinpath(root, folder, "ext")) ?
            filter(!isnothing, [Base.get_extension(package, Symbol(splitext(name)[1])) for name in readdir(joinpath(root, folder, "ext"))]) : Module[]
        for m in [submodules(package); [inner for e in extensions for inner in submodules(e)]], name in names(m; all=true)
            isdefined(m, name) || continue
            t = getfield(m, name)
            ## Only the types written in the package: this leaves out closures and aliases.
            (t isa Union{DataType,UnionAll} && parentmodule(t) === m && nameof(t) === name && haskey(locations, name)) || continue
            path, line = locations[name]
            types[t] = Dict{String,Any}("id" => string(m, ".", name), "name" => string(name),
                "package" => string(nameof(package)), "file" => path, "line" => line,
                "abstract" => isabstracttype(t), "exported" => Base.isexported(package, name))
        end
    end
    ours = Set(keys(types))
    edges = Dict{String,String}[]
    for (t, node) in types
        body = Base.unwrap_unionall(t)
        if !isabstracttype(t)
            node["fields"] = [Dict("name" => string(f), "type" => short(ft))
                for (f, ft) in zip(fieldnames(body), fieldtypes(body))]
            for ft in fieldtypes(body), target in named_types(ft, ours)
                target === t || push!(edges, Dict("source" => node["id"], "target" => types[target]["id"], "kind" => "field"))
            end
        end
        super = Base.typename(supertype(body)).wrapper
        node["supertype"] = short(supertype(body))
        super in ours && push!(edges, Dict("source" => node["id"], "target" => types[super]["id"], "kind" => "subtype"))
    end
    return Dict("types" => collect(values(types)), "edges" => unique(edges))
end

# A type as text, with each name of a type alone, such as `Vector{Row}` for a vector of `Catalogs.Row`.
short(t) = replace(string(t), r"\b(?:[A-Za-z]\w*\.)+(?=[A-Za-z@])" => "")

# JSON text of plain dictionaries, vectors, strings, numbers and booleans.
json(x::AbstractString) = "\"" * escape_string(x, "\"") * "\""
json(x::Union{Bool,Integer}) = string(x)
json(x::AbstractVector) = "[" * join(json.(x), ",") * "]"
json(x::AbstractDict) = "{" * join((json(string(k)) * ":" * json(v) for (k, v) in x), ",") * "}"

"""
    write_codemap(path, modules, root)

Save the code map of `modules` to `path` as a script that sets `window.CODEMAP`, with the commit of
the repository for the links to GitHub.
"""
function write_codemap(path, modules, root)
    commit = readchomp(Cmd(`git rev-parse HEAD`; dir=root))
    mkpath(dirname(path))
    write(path, "window.CODEMAP = " * json(merge(codemap(modules, root), Dict("commit" => commit))) * ";\n")
    return path
end
