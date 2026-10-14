"""
The revision of the code that a stage runs: a content hash of every method, type and constant the
stage can reach by name from its [`stage_roots`](@ref), in modules that can change during a session.

Two definitions with the same source give the same revision, also in a new session, so running a
script again changes nothing, and a revision can be stored with cached results. Code in Base, the
standard library, registered packages and DataBrowser's own packages never changes during a session
and is not entered.

A revision is a static analysis. It is conservative where it can be: every method of a reached
function counts, and every project method added to a library function (such as `Base.show` or
`Base.iterate` for a project type) counts for every stage. Some code is out of its reach; the
revision lists it under `untracked`. See `research_notes/code-change-detection/design.md`.
"""
module CodeRevisions

using SHA: sha1, SHA1_CTX, update!, digest!
import TOML
using DataBrowserAPI: AbstractProject, AbstractDataSource

export CodeRevision, code_revision

"""
The hash of the code a stage can reach, and the reasons some of that code may change unseen.
`parts` names each method, type and value with its own hash, to tell what changed.
"""
struct CodeRevision
    hash::String
    parts::Vector{Pair{String,String}}
    untracked::Vector{String}
end

# ---------------------------------------------------------------------------
# Which modules can change
# ---------------------------------------------------------------------------

# Answers per module; modules are never unloaded.
const CHANGEABLE = IdDict{Module,Bool}()
const LOCK = ReentrantLock()

"""
Whether code in `mod` can change during a session: `Main` and the modules made in it, and the
packages that an environment of the load path develops from a local folder (`Pkg.develop`), or that
an environment is itself. DataBrowser's own packages count as libraries, and so do packages that
no environment lists, such as the one VS Code loads into the session.
"""
function changeable(mod::Module)::Bool
    return @lock LOCK get!(CHANGEABLE, mod) do
        root = Base.moduleroot(mod)
        databrowser(root) && return false
        (root === Base || root === Core) && return false
        root === Main && return true
        return Base.PkgId(root).uuid in developed()
    end
end

const DEVELOPED = Ref{Union{Nothing,Set{Base.UUID}}}(nothing)

"""The packages that the environments of the load path develop from a local folder, or are."""
function developed()::Set{Base.UUID}
    known = @lock LOCK DEVELOPED[]
    known === nothing || return known
    found = Set{Base.UUID}()
    for environment in Base.load_path()
        project = Base.env_project_file(environment)
        project isa String || continue
        uuid = get(TOML.parsefile(project), "uuid", nothing)
        uuid === nothing || push!(found, Base.UUID(uuid))
        manifest = Base.project_file_manifest_path(project)
        manifest === nothing && continue
        for (_, entries) in get(TOML.parsefile(manifest), "deps", Dict())
            for entry in entries
                haskey(entry, "path") && push!(found, Base.UUID(entry["uuid"]))
            end
        end
    end
    @lock LOCK DEVELOPED[] = found
    return found
end

# ---------------------------------------------------------------------------
# One method: its text and what it names
# ---------------------------------------------------------------------------

"""The content of one method: its name, a hash of its lowered code, and the globals and values it names."""
struct MethodContent
    name::String
    hash::String
    names::Vector{Any}
    untracked::Vector{String}
end

# A method never changes: a redefinition makes a new `Method`.
const CONTENTS = IdDict{Method,MethodContent}()

# Generated names of closures and keyword bodies contain '#' and a counter that depends on the order
# of definitions; their content is hashed where they are reached.
normal(name::Symbol)::String = occursin('#', String(name)) ? "#gen" : String(name)
normal(@nospecialize(type))::String =
    replace(string(type), r"var\"#[^\"]*\"" => "#gen", r"#[\w#]+" => "#gen")

"""Calls whose target the code computes at run time: the revision cannot follow them."""
const DYNAMIC = Dict(
    GlobalRef(Core, :eval) => "eval", GlobalRef(Base, :eval) => "eval",
    GlobalRef(Base, :invokelatest) => "invokelatest", GlobalRef(Base, :include) => "include",
    GlobalRef(Base, :getglobal) => "getglobal", GlobalRef(Core, :getglobal) => "getglobal")

function content(method::Method)::MethodContent
    known = @lock LOCK get(CONTENTS, method, nothing)
    known === nothing || return known
    io = IOBuffer()
    names = Any[]
    untracked = String[]
    print(io, normal(method.sig), '\n')
    append!(names, Base.unwrap_unionall(method.sig).parameters)
    isdefined(method, :generator) && push!(untracked, "$(method.name) is a generated function")
    code = try
        Base.uncompressed_ast(method).code
    catch
        nothing
    end
    if code === nothing
        print(io, "<no source>")
    else
        for statement in code
            write_statement!(io, names, untracked, code, statement)
            print(io, '\n')
        end
    end
    name = string(method.module, '.', normal(method.name), ' ', normal(method.sig))
    found = MethodContent(name, bytes2hex(sha1(take!(io))), names, untracked)
    @lock LOCK CONTENTS[method] = found
    return found
end

"""Write one lowered statement without slot names or line numbers, and collect what it names."""
function write_statement!(io::IO, names::Vector{Any}, untracked::Vector{String}, code, @nospecialize(x))
    if x isa Expr
        if x.head === :call && !isempty(x.args) && haskey(DYNAMIC, x.args[1]) &&
                !(x.args[1].name === :getglobal && length(x.args) == 3 && literal(x.args[3]))
            push!(untracked, "calls $(DYNAMIC[x.args[1]])")
        end
        # `Module.name` lowers to `getproperty(Module, :name)`: it names `Module.name`.
        if x.head === :call && length(x.args) == 3 && x.args[1] == GlobalRef(Base, :getproperty) &&
                x.args[3] isa QuoteNode && x.args[3].value isa Symbol
            owner = x.args[2] isa Core.SSAValue ? code[x.args[2].id] : x.args[2]
            owner = owner isa GlobalRef && isdefined(owner.mod, owner.name) ? getglobal(owner.mod, owner.name) : owner
            owner isa Module && push!(names, GlobalRef(owner, x.args[3].value))
        end
        print(io, '(', x.head)
        for arg in x.args
            print(io, ' ')
            write_statement!(io, names, untracked, code, arg)
        end
        print(io, ')')
    elseif x isa GlobalRef
        print(io, nameof(x.mod), '.', normal(x.name))
        push!(names, x)
    elseif x isa Core.SSAValue
        print(io, '%', x.id)
    elseif x isa Core.SlotNumber
        print(io, '_', x.id)
    elseif x isa Core.Argument
        print(io, '_', x.n)
    elseif x isa Core.ReturnNode
        print(io, "return ")
        isdefined(x, :val) && write_statement!(io, names, untracked, code, x.val)
    elseif x isa Core.GotoNode
        print(io, "goto ", x.label)
    elseif x isa Core.GotoIfNot
        print(io, "gotoifnot ")
        write_statement!(io, names, untracked, code, x.cond)
        print(io, ' ', x.dest)
    elseif x isa QuoteNode
        print(io, "quote ")
        write_statement!(io, names, untracked, code, x.value)
    elseif x isa Function || x isa Type
        print(io, normal(x isa Type ? x : typeof(x)))
        push!(names, x)
    elseif x isa Core.NewvarNode
        print(io, "newvar ", x.slot.id)
    else
        print(io, string(typeof(x), ':', sprint(show, x; context=:limit => true)))
    end
end

literal(@nospecialize(x))::Bool = x isa QuoteNode || x isa Symbol

# ---------------------------------------------------------------------------
# Project methods on library functions
# ---------------------------------------------------------------------------

# The walk of the methods that changeable modules add to library functions, for one world.
const EXTENSIONS = Ref{Any}(nothing)

"""
The parts of the methods that changeable modules add to functions they do not own, such as
`Base.show` for a project type. Library code may call any of them, so each counts for every stage.
DataBrowser's own functions are left out: the stage roots name the methods of those that apply.
"""
function extensions(world::UInt)
    known = @lock LOCK EXTENSIONS[]
    known !== nothing && first(known) == world && return last(known)
    walk = Walk(world, IdDict{Any,Nothing}(), Pair{String,String}[], String[])
    Base.visit(Core.methodtable) do method
        changeable(method.module) || return
        library(method) || return
        # A replaced method stays in the table; keep only the methods of this world.
        live = Base._methods_by_ftype(method.sig, -1, world)
        live !== nothing && any(match -> match.method === method, live) && enter!(walk, method)
    end
    found = (walk.parts, walk.untracked)
    @lock LOCK EXTENSIONS[] = world => found
    return found
end

# Read once per session: libraries do not change during a session.
const ENVIRONMENT = Ref{Union{Nothing,String}}(nothing)

"""
A hash of the Julia version and the package versions of the active environment. Libraries change
only between sessions, when they are upgraded; their code is not walked.
"""
function environment()::String
    known = @lock LOCK ENVIRONMENT[]
    known === nothing || return known
    project = Base.active_project()
    manifest = project === nothing ? nothing : Base.project_file_manifest_path(project)
    text = string(VERSION, '\n', manifest === nothing || !isfile(manifest) ? "" : read(manifest, String))
    found = bytes2hex(sha1(text))
    @lock LOCK ENVIRONMENT[] = found
    return found
end

"""Whether `method` adds to a function of a library, other than a stage function of DataBrowser."""
function library(method::Method)::Bool
    parameters = Base.unwrap_unionall(method.sig).parameters
    F = parameters[1]
    # A keyword method belongs to the function after `kwcall`.
    if F === typeof(Core.kwcall) && length(parameters) >= 3
        F = parameters[3]
    end
    # `read` is `Base.read`; a `read` for a project or source is a stage method.
    F === typeof(Base.read) && length(parameters) >= 2 &&
        parameters[2] isa Type && parameters[2] <: Union{AbstractProject,AbstractDataSource} && return false
    # A constructor belongs to the module of its type.
    if F isa DataType && F <: Type && F.parameters[1] isa Type
        T = Base.unwrap_unionall(F.parameters[1])
        T isa DataType && return !changeable(parentmodule(T)) && !databrowser(parentmodule(T))
    end
    owner = F isa DataType ? parentmodule(F) : Main
    return !changeable(owner) && !databrowser(owner)
end

databrowser(mod::Module)::Bool = startswith(String(nameof(Base.moduleroot(mod))), "DataBrowser")

# ---------------------------------------------------------------------------
# The walk
# ---------------------------------------------------------------------------

struct Walk
    world::UInt
    seen::IdDict{Any,Nothing}
    parts::Vector{Pair{String,String}}
    untracked::Vector{String}
end

"""
    code_revision(roots) -> CodeRevision

The revision of the code reachable from `roots`: methods, functions and closures, and types.
A root method of a library, such as a default stage method that forwards to the project's method,
is left out: the roots also name the project's methods that it forwards to.

When the walk fails, the revision is `"not tracked"` and gives the reason.
"""
function code_revision(roots::AbstractVector)::CodeRevision
    walk = Walk(Base.get_world_counter(), IdDict{Any,Nothing}(), Pair{String,String}[], String[])
    try
        for root in roots
            root isa Method ? (changeable(root.module) && enter!(walk, root)) : visit!(walk, root)
        end
        parts, untracked = extensions(walk.world)
        append!(walk.parts, parts)
        append!(walk.untracked, untracked)
    catch error
        # The walk recurses deeply: its backtrace would be long and say nothing to the user.
        return CodeRevision("not tracked", [], ["the code could not be followed: $(sprint(showerror, error))"])
    end
    push!(walk.parts, "Julia and package versions" => environment())
    # Names are not unique: closures, for one, all have the same.
    unique!(sort!(walk.parts))
    return CodeRevision(bytes2hex(sha1(join(last.(walk.parts), '\n'))), walk.parts, sort!(unique!(walk.untracked)))
end

function enter!(walk::Walk, method::Method)::Nothing
    haskey(walk.seen, method) && return nothing
    walk.seen[method] = nothing
    found = content(method)
    push!(walk.parts, found.name => found.hash)
    append!(walk.untracked, found.untracked)
    foreach(name -> visit!(walk, name), found.names)
    return nothing
end

"""Follow one name or value: globals, functions with their methods, types, and constant data."""
function visit!(walk::Walk, @nospecialize(x))::Nothing
    if x isa GlobalRef
        haskey(walk.seen, x) && return nothing
        walk.seen[x] = nothing
        isdefined(x.mod, x.name) || return nothing
        value = getglobal(x.mod, x.name)
        # A name that a module imports, such as `stdout`, belongs to the module that defines it. A
        # name that two modules export with the same value has no single owner.
        owner = try
            Base.binding_module(x.mod, x.name)
        catch
            x.mod
        end
        if !(value isa Union{Function,Type,Module}) && changeable(owner)
            # TODO: a global that is reassigned, or constant data that is changed in place, changes
            # no method, so the check sees it only with the next definition.
            isconst(owner, x.name) || push!(walk.untracked, "reads the global $(owner).$(x.name)")
            hash = try
                value_hash(walk, value)
            catch error
                push!(walk.untracked, "could not read the value of $(owner).$(x.name): $(sprint(showerror, error))")
                "unknown"
            end
            push!(walk.parts, "$(owner).$(x.name)" => hash)
        else
            visit!(walk, value)
        end
    elseif x isa Type
        T = Base.unwrap_unionall(x)
        T isa DataType && visit_type!(walk, T)
    elseif x isa Function
        visit_methods!(walk, typeof(x))
        # A closure carries the values it captured.
        if !Base.issingletontype(typeof(x)) && !haskey(walk.seen, x)
            walk.seen[x] = nothing
            push!(walk.parts, "captured by $(normal(typeof(x)))" => value_hash(walk, x))
        end
    end
    return nothing
end

# The changeable methods of each callable type, for one world. Listing the methods of large library
# functions, such as `getindex`, is most of the cost of a walk.
const METHODS = Ref{Pair{UInt,IdDict{Any,Vector{Method}}}}(UInt(0) => IdDict{Any,Vector{Method}}())

"""Every method callable on objects of type `F`, also with keyword arguments, in changeable modules."""
function visit_methods!(walk::Walk, @nospecialize(F::Type))::Nothing
    haskey(walk.seen, (:call, F)) && return nothing
    walk.seen[(:call, F)] = nothing
    lists = @lock LOCK begin
        first(METHODS[]) == walk.world || (METHODS[] = walk.world => IdDict{Any,Vector{Method}}())
        last(METHODS[])
    end
    found = @lock LOCK get(lists, F, nothing)
    if found === nothing
        found = Method[]
        for signature in (Tuple{F,Vararg{Any}}, Tuple{typeof(Core.kwcall),Any,F,Vararg{Any}})
            matches = Base._methods_by_ftype(signature, -1, walk.world)
            matches === nothing && continue
            append!(found, (match.method for match in matches if changeable(match.method.module)))
        end
        @lock LOCK lists[F] = found
    end
    foreach(method -> enter!(walk, method), found)
    return nothing
end

# A type never changes: a redefinition makes a new type.
const TYPES = IdDict{DataType,Pair{String,String}}()

function visit_type!(walk::Walk, T::DataType)::Nothing
    haskey(walk.seen, T) && return nothing
    walk.seen[T] = nothing
    foreach(parameter -> visit!(walk, parameter), T.parameters)
    # Constructors, also those that extend `Base` functions for this type.
    visit_methods!(walk, Type{T})
    # The methods of one function or closure. An abstract type, such as a field `::Function`, would
    # bring in every function: the value in the field is followed instead.
    T <: Function && return isconcretetype(T) ? visit_methods!(walk, T) : nothing
    changeable(parentmodule(T)) || return nothing
    fields = isstructtype(T) && !isabstracttype(T) ? collect(zip(fieldnames(T), fieldtypes(T))) : []
    part = @lock LOCK get(TYPES, T, nothing)
    if part === nothing
        part = "type $(normal(T))" => bytes2hex(sha1(string(normal(T.name.wrapper), " <: ",
            normal(supertype(T)), ' ', join(("$name::$(normal(type))" for (name, type) in fields), ','))))
        @lock LOCK TYPES[T] = part
    end
    push!(walk.parts, part)
    visit!(walk, supertype(T))
    foreach(((_, type),) -> visit!(walk, type), fields)
    return nothing
end

# ---------------------------------------------------------------------------
# Values
# ---------------------------------------------------------------------------

"""A hash of a value by its structure. Functions and types found inside are walked."""
function value_hash(walk::Walk, @nospecialize(x))::String
    context = SHA1_CTX()
    value_hash!(walk, context, x, IdDict{Any,Nothing}(), 0)
    return bytes2hex(digest!(context))
end

# The hash of each mutable value when the walk first saw it, by object identity. The weak reference
# tells a live object from a new one at the same address.
const FIRST_SEEN = Dict{UInt,Tuple{WeakRef,String}}()

"""
Add `x` to `context`; a `context` of `nothing` only walks the functions and types inside `x`.

A mutable value keeps the hash it had when first seen, even when it changes in place: counters and
caches that stages fill would otherwise change the revision on every run. A new object, such as
the value of a constant defined again, is hashed again.
"""
function value_hash!(walk::Walk, context, @nospecialize(x), seen::IdDict{Any,Nothing}, depth::Int)::Nothing
    put(text) = context === nothing || update!(context, codeunits(string(text, '\x1f')))
    if depth > 30
        put("<deep>")
    elseif x isa Function || x isa Type
        put(normal(x isa Type ? x : typeof(x)))
        x isa Type ? visit!(walk, x) : visit_methods!(walk, typeof(x))
        if x isa Function && !Base.issingletontype(typeof(x))
            for i in 1:nfields(x)
                isdefined(x, i) && value_hash!(walk, context, getfield(x, i), seen, depth + 1)
            end
        end
    elseif x isa Module
        put(x)
    elseif x isa Union{Number,AbstractString,Symbol,Char,Nothing,Missing,Regex,Enum}
        put(string(typeof(x), ':', repr(x)))
    elseif !isbitstype(typeof(x)) && haskey(seen, x)
        put("<cycle>")
    elseif x isa Union{Task,IO,Base.AbstractLock,Ptr,Threads.Condition}
        put(string("<state ", typeof(x), ">"))
    elseif ismutable(x)
        seen[x] = nothing
        known = @lock LOCK get(FIRST_SEEN, objectid(x), nothing)
        known = known !== nothing && known[1].value === x ? known[2] : nothing
        inner = known === nothing ? SHA1_CTX() : nothing
        contents!(walk, inner, x, seen, depth)
        if known === nothing
            known = bytes2hex(digest!(inner))
            @lock LOCK FIRST_SEEN[objectid(x)] = (WeakRef(x), known)
        end
        put(known)
    else
        contents!(walk, context, x, seen, depth)
    end
    return nothing
end

"""Add the elements or fields of `x` to `context`, as [`value_hash!`](@ref) does."""
function contents!(walk::Walk, context, @nospecialize(x), seen::IdDict{Any,Nothing}, depth::Int)::Nothing
    put(text) = context === nothing || update!(context, codeunits(string(text, '\x1f')))
    if x isa Array && isbitstype(eltype(x))
        put(string(typeof(x), size(x)))
        context === nothing || update!(context, reinterpret(UInt8, vec(x)))
    elseif x isa AbstractDict
        put(typeof(x))
        foreach(put, sort!([value_hash(walk, key) * value_hash(walk, value) for (key, value) in x]))
    elseif x isa AbstractArray
        put(string(typeof(x), size(x)))
        for i in eachindex(x)
            isassigned(x, i) ? value_hash!(walk, context, x[i], seen, depth + 1) : put("<undef>")
        end
    elseif x isa Union{Tuple,AbstractSet}
        put(string(typeof(x), length(x)))
        foreach(element -> value_hash!(walk, context, element, seen, depth + 1), x)
    else
        # Structs, named tuples, `Ref` and the boxes of captured variables: field by field.
        put(normal(typeof(x)))
        for i in 1:nfields(x)
            isdefined(x, i) ? value_hash!(walk, context, getfield(x, i), seen, depth + 1) : put("<undef>")
        end
    end
    return nothing
end

end
