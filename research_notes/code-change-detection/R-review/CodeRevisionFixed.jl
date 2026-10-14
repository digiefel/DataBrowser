# Review copy of A-static-walk/CodeRevision.jl with the fixes that design.md proposes, so the
# review can check whether they work. Changes from the prototype (search "REVIEW"):
#   - type rule (design "miss 4"): when a changeable type is reached, also enter every changeable
#     method whose signature mentions it. `type_rule = :none | :exact | :supertypes | :library`.
#   - deep values (design "miss 1"): consts, globals and captures are hashed by structure, and
#     function values found inside them are walked. `deep = true`.
#   - polling (design "misses 2, 3, 7"): `poll_hash(report)` re-hashes every listed global and
#     captured box without a world change.
#
# Approach A prototype: a static walk over lowered code.
#
# `code_revision(roots)` returns a hash of every method reachable *by name* from the roots,
# restricted to modules that can change during a session. The hash is built from lowered code with
# generated names (closures, keyword bodies) normalized away, so the same source gives the same hash
# in a new session: it can key a disk cache.
#
# Usage: include("CodeRevision.jl"); using .CodeRevision
module CodeRevisionFixed

using SHA: sha1, SHA1_CTX, update!, digest!

export code_revision, RevisionReport, is_changeable, LIBRARY_MODULES, poll_hash

"""DataBrowser's own packages and this prototype: treated as libraries when walking a project."""
const LIBRARY_MODULES = [:DataBrowser, :DataBrowserAPI, :DataBrowserCore, :DataBrowserGUI,
    :DataBrowserPlots, :DataBrowserRecipes, :DataBrowserSources, :DataBrowserCache,
    :DataBrowserAnnotations, :DataBrowserProfiling, :CodeRevision, :CodeRevisionFixed]

# ---------------------------------------------------------------------------------------------
# Which modules can change in a session
# ---------------------------------------------------------------------------------------------

const _FROZEN_ROOTS = [normpath(Sys.STDLIB); [normpath(joinpath(d, "packages")) for d in DEPOT_PATH]]

"""
    is_changeable(mod; exclude=Symbol[]) -> Bool

A module can change in a session when it is `Main` (or a module created inside it), or a package
loaded from a path outside the stdlib and outside `~/.julia/packages` (a `dev`/`path` package).
`Base`, `Core` and other non-package modules (`Compiler`) never change. A module whose own name, or
any parent's name, starts with a name in `exclude` is treated as frozen: callers use it to treat DataBrowser itself
as a library.
"""
function is_changeable(mod::Module; exclude::Vector{Symbol}=Symbol[])::Bool
    m = mod
    while true
        # Prefix match also covers package extensions, such as `DataBrowserCoreDataFramesExt`.
        any(e -> startswith(String(nameof(m)), String(e)), exclude) && return false
        parentmodule(m) === m && break
        m = parentmodule(m)
    end
    root = Base.moduleroot(mod)
    (root === Base || root === Core) && return false
    root === Main && return true
    dir = pkgdir(root)
    dir === nothing && return false
    dir = normpath(dir)
    return !any(startswith(dir, frozen) for frozen in _FROZEN_ROOTS)
end

# ---------------------------------------------------------------------------------------------
# The walk
# ---------------------------------------------------------------------------------------------

"""What one walk visited, for measurements and debugging."""
mutable struct RevisionReport
    hash::String
    methods::Int            # changeable methods hashed
    functions::Int          # functions whose method lists were scanned
    types::Int              # changeable types hashed
    values::Int             # global values hashed (const and non-const)
    nonconst_globals::Vector{String}  # non-const globals read by name: not covered by the world trigger
    unhashed::Vector{String}  # values that are not plain data (mutable state): not in the hash
    entries::Vector{Pair{String,String}}  # label => content hash, sorted
    polled::Vector{Pair{String,Any}}      # REVIEW: label => GlobalRef, Core.Box or value, re-hashed by `poll_hash`
    roots_seen::Vector{Method}            # REVIEW: every method entered, for over-inclusion counts
end

mutable struct Walk
    exclude::Vector{Symbol}
    world::UInt
    seen::IdDict{Any,Nothing}
    entries::Vector{Pair{String,String}}
    functions::Int
    nonconst::Vector{String}
    unhashed::Vector{String}
    modules::IdDict{Module,Bool}
    type_rule::Symbol
    deep::Bool
    polled::Vector{Pair{String,Any}}
    methods_seen::Vector{Method}
end

changeable(w::Walk, mod::Module) = get!(() -> is_changeable(mod; exclude=w.exclude), w.modules, mod)

# Generated names (closure types, keyword bodies, gensyms) contain '#' and a counter that depends on
# definition order. They are replaced by a placeholder: their content is walked and hashed separately.
normname(s::Symbol) = occursin('#', String(s)) ? "#gen" : String(s)
normtype(@nospecialize(t)) = replace(string(t), r"var\"#[^\"]*\"" => "#gen", r"#[\w#]+" => "#gen")

"""Plain data: values whose printed text is their content, the same in every session."""
function isplain(@nospecialize(x))::Bool
    x isa Union{Number,AbstractString,Symbol,Char,Nothing,Missing,Regex} && return true
    x isa Union{Tuple,NamedTuple,AbstractArray,AbstractSet} && return length(x) <= 10_000 && all(isplain, x)
    x isa Pair && return isplain(x.first) && isplain(x.second)
    x isa AbstractDict && return length(x) <= 10_000 && all(isplain, keys(x)) && all(isplain, values(x))
    return false
end

value_text(@nospecialize(x))::String = string(typeof(x)) * ":" * sprint(show, x; context=(:limit => false))

"""Hash a plain value; record any other value (state such as caches, timers, handles) as unhashed."""
function hash_value!(w::Walk, label::String, @nospecialize(x))
    if w.deep
        # REVIEW: structural hash; walks functions found inside the value.
        push!(w.entries, label => deep_hash(w, x))
    else
        isplain(x) ? push!(w.entries, label => bytes2hex(sha1(value_text(x)))) : push!(w.unhashed, label)
    end
end

# REVIEW: structural content hash. Functions and types inside the value are walked (their code goes
# into the revision); bits arrays are hashed as raw bytes; structs field by field.
function deep_hash(w::Union{Walk,Nothing}, @nospecialize(x))::String
    ctx = SHA1_CTX()
    deep_hash!(w, ctx, x, IdDict{Any,Nothing}(), 0)
    return bytes2hex(digest!(ctx))
end

function deep_hash!(w, ctx, @nospecialize(x), seen, depth)
    put(s) = update!(ctx, codeunits(string(s, '\x1f')))
    depth > 30 && return put("<deep>")
    if x isa Function || x isa Type
        put(normtype(x isa Type ? x : typeof(x)))
        w === nothing || visit_value(w, x)
        # Captured values of a closure are part of the value.
        if x isa Function && !Base.issingletontype(typeof(x))
            for n in fieldnames(typeof(x))
                isdefined(x, n) && deep_hash!(w, ctx, getfield(x, n), seen, depth + 1)
            end
        end
    elseif x isa Module
        put(x)
    elseif x isa Union{Number,AbstractString,Symbol,Char,Nothing,Missing,Regex,Enum}
        put(value_text(x))
    elseif x isa Array && isbitstype(eltype(x))
        put(string(typeof(x), size(x)))
        update!(ctx, reinterpret(UInt8, vec(x)))
    elseif !isbitstype(typeof(x)) && haskey(seen, x)
        put("<cycle>")
    elseif x isa Union{Task,IO,Base.AbstractLock,Ptr,Threads.Condition}
        put(string("<state ", typeof(x), ">"))
    elseif x isa AbstractDict
        isbitstype(typeof(x)) || (seen[x] = nothing)
        put(typeof(x))
        hs = sort!([deep_hash(w, k) * deep_hash(w, v) for (k, v) in x])
        foreach(put, hs)
    elseif x isa Union{AbstractArray,Tuple,AbstractSet}
        isbitstype(typeof(x)) || (seen[x] = nothing)
        put(string(typeof(x), x isa AbstractArray ? size(x) : length(x)))
        for e in x
            deep_hash!(w, ctx, e, seen, depth + 1)
        end
    else
        # Structs, NamedTuples, Ref, Core.Box: field by field.
        ismutable(x) && (seen[x] = nothing)
        put(normtype(typeof(x)))
        for i in 1:nfields(x)
            isdefined(x, i) ? deep_hash!(w, ctx, getfield(x, i), seen, depth + 1) : put("<undef>")
        end
    end
end

"""REVIEW: re-hash every polled global and captured box (no world change needed)."""
function poll_hash(r::RevisionReport)::String
    parts = String[]
    for (label, src) in r.polled
        v = src isa GlobalRef ? (isdefined(src.mod, src.name) ? getglobal(src.mod, src.name) : nothing) :
            src isa Core.Box ? (isdefined(src, :contents) ? src.contents : nothing) : src
        push!(parts, label * "=" * deep_hash(nothing, v))
    end
    return bytes2hex(sha1(join(sort!(parts), '\n')))
end

"""Lowered statement as text, with slot names, line numbers and generated names left out."""
function stmt_text(w::Walk, io::IO, @nospecialize(x))
    if x isa Expr
        print(io, '(', x.head)
        for a in x.args
            print(io, ' ')
            stmt_text(w, io, a)
        end
        print(io, ')')
    elseif x isa GlobalRef
        print(io, nameof(x.mod), '.', normname(x.name))
        visit_globalref(w, x)
    elseif x isa Core.SSAValue
        print(io, '%', x.id)
    elseif x isa Core.SlotNumber
        print(io, '_', x.id)
    elseif x isa Core.Argument
        print(io, '_', x.n)
    elseif x isa Core.ReturnNode
        print(io, "return ")
        isdefined(x, :val) && stmt_text(w, io, x.val)
    elseif x isa Core.GotoNode
        print(io, "goto ", x.label)
    elseif x isa Core.GotoIfNot
        print(io, "gotoifnot ")
        stmt_text(w, io, x.cond)
        print(io, ' ', x.dest)
    elseif x isa QuoteNode
        print(io, "quote ")
        stmt_text(w, io, x.value)
    elseif x isa Function || x isa Type
        # A function or type embedded as a literal value.
        print(io, normtype(x isa Type ? x : typeof(x)))
        visit_value(w, x)
    elseif x isa Core.NewvarNode
        print(io, "newvar ", x.slot.id)
    else
        print(io, isplain(x) ? value_text(x) : string("<", typeof(x), ">"))
    end
end

function visit_globalref(w::Walk, g::GlobalRef)
    isdefined(g.mod, g.name) || return
    value = getglobal(g.mod, g.name)
    if isconst(g.mod, g.name)
        visit_value(w, value)
        # Const plain data in a changeable module: its value is part of the code's meaning.
        if !(value isa Union{Function,Type,Module}) && changeable(w, g.mod) && !haskey(w.seen, g)
            w.seen[g] = nothing
            hash_value!(w, "const $(g.mod).$(g.name)", value)
            # REVIEW: a const holding mutable data can change without a world change.
            w.deep && !isbits(value) && push!(w.polled, "const $(g.mod).$(g.name)" => g)
        end
    elseif changeable(w, g.mod) && !haskey(w.seen, g)
        # Non-const global: hash the value it holds now. Reassigning it does NOT bump the world
        # counter, so a world-triggered recheck will not see the change (listed as a miss).
        w.seen[g] = nothing
        push!(w.nonconst, "$(g.mod).$(g.name)")
        w.deep && push!(w.polled, "global $(g.mod).$(g.name)" => g)
        value isa Union{Function,Type} ? visit_value(w, value) :
            hash_value!(w, "global $(g.mod).$(g.name)", value)
    end
end

"""Walk a value found by name: functions and types; closure instances also bring their captures."""
function visit_value(w::Walk, @nospecialize(x))
    if x isa Type
        x isa DataType || x isa UnionAll || return
        visit_type(w, Base.unwrap_unionall(x))
    elseif x isa Function
        visit_callable(w, typeof(x))
        # A closure instance carries captured values: walk captured functions, hash captured data.
        # Captures are walked even for library closures: a library wrapper may hold a user callback.
        T = typeof(x)
        if !Base.issingletontype(T) && !haskey(w.seen, x)
            w.seen[x] = nothing
            for name in fieldnames(T)
                isdefined(x, name) || continue
                v = getfield(x, name)
                if v isa Core.Box
                    w.deep && push!(w.polled, "box $(name)" => v)
                    v = isdefined(v, :contents) ? v.contents : nothing
                end
                w.deep && !(v isa Union{Function,Type}) && !isbits(v) && push!(w.polled, "capture $(name)" => v)
                v isa Union{Function,Type} ? visit_value(w, v) : hash_value!(w, "capture $(name)", v)
            end
        end
    end
end

# Method lists per callable type, shared by all walks in the same world with the same `exclude`.
# Scanning the method lists of large `Base` functions (`getindex`, `show`) dominates the cost.
const _METHOD_LISTS = IdDict{Any,Vector{Method}}()
const _METHOD_LISTS_KEY = Ref{Any}(nothing)

"""All methods callable on objects of type `F`, plus keyword-call methods, in changeable modules."""
function visit_callable(w::Walk, @nospecialize(F::Type))
    haskey(w.seen, (:call, F)) && return
    w.seen[(:call, F)] = nothing
    w.functions += 1
    key = (w.world, w.exclude)
    _METHOD_LISTS_KEY[] == key || (empty!(_METHOD_LISTS); _METHOD_LISTS_KEY[] = key)
    found = get!(_METHOD_LISTS, F) do
        list = Method[]
        for sig in (Tuple{F,Vararg{Any}}, Tuple{typeof(Core.kwcall),Any,F,Vararg{Any}})
            matches = Base._methods_by_ftype(sig, -1, w.world)
            matches === nothing && continue
            for match in matches
                changeable(w, match.method.module) && push!(list, match.method)
            end
        end
        list
    end
    foreach(m -> visit_method(w, m), found)
end

function visit_type(w::Walk, @nospecialize(T::DataType))
    haskey(w.seen, T) && return
    w.seen[T] = nothing
    # Constructors, including those that extend `Base` functions on this type.
    visit_callable(w, Type{T})
    changeable(w, parentmodule(T)) || return
    # REVIEW: type rule. Enter every changeable method whose signature mentions T (or, with
    # :supertypes, a changeable supertype of T): catches `Base.iterate(::T)` reached through Base.
    if w.type_rule !== :none
        S = T
        while true
            for m in get(type_index(w), S.name, Method[])
                # :library limits the rule to methods of library functions (Base, packages), not
                # DataBrowser's API and not user functions (those are already reached by name).
                if w.type_rule === :library
                    F = Base.unwrap_unionall(m.sig).parameters[1]
                    fmod = F isa DataType ? parentmodule(F) : Main
                    (is_changeable(fmod) || !is_changeable(fmod; exclude=w.exclude) &&
                        any(e -> startswith(String(nameof(Base.moduleroot(fmod))), String(e)), w.exclude)) && continue
                end
                visit_method(w, m)
            end
            w.type_rule === :exact && break
            S = supertype(S)
            (S === Any || !changeable(w, parentmodule(S))) && break
        end
    end
    # Closure and function types: their call methods are the content.
    T <: Function && return visit_callable(w, T)
    text = string(normtype(T.name.wrapper), " <: ", normtype(supertype(T)), " ",
        isstructtype(T) && !isabstracttype(T) ?
            join(("$n::$(normtype(t))" for (n, t) in zip(fieldnames(T), fieldtypes(T))), ",") : "")
    push!(w.entries, "type $(T.name.name)" => bytes2hex(sha1(text)))
    for t in (isstructtype(T) && !isabstracttype(T) ? fieldtypes(T) : ())
        t isa DataType && visit_type(w, t)
    end
end

# REVIEW: index of changeable methods by every type name their signature mentions, per world.
const _TYPE_INDEX = Dict{Core.TypeName,Vector{Method}}()
const _TYPE_INDEX_KEY = Ref{Any}(nothing)

function type_index(w::Walk)
    key = (w.world, w.exclude)
    _TYPE_INDEX_KEY[] == key && return _TYPE_INDEX
    empty!(_TYPE_INDEX)
    Base.visit(Core.methodtable) do m
        changeable(w, m.module) || return
        # Replaced methods stay in the table; keep only those still visible in this world.
        live = Base._methods_by_ftype(m.sig, -1, w.world)
        (live === nothing || !any(x -> x.method === m, live)) && return
        names = Set{Core.TypeName}()
        collect_typenames!(names, m.sig, 0)
        for n in names
            push!(get!(Vector{Method}, _TYPE_INDEX, n), m)
        end
    end
    _TYPE_INDEX_KEY[] = key
    return _TYPE_INDEX
end

function collect_typenames!(names, @nospecialize(t), depth)
    depth > 10 && return
    if t isa UnionAll
        collect_typenames!(names, t.var.ub, depth + 1); collect_typenames!(names, t.body, depth + 1)
    elseif t isa Union
        collect_typenames!(names, t.a, depth + 1); collect_typenames!(names, t.b, depth + 1)
    elseif t isa TypeVar
        collect_typenames!(names, t.ub, depth + 1)
    elseif t isa DataType
        push!(names, t.name)
        foreach(p -> collect_typenames!(names, p, depth + 1), t.parameters)
    elseif t isa Function
        push!(names, typeof(t).name)
    end
end

function visit_method(w::Walk, m::Method; root::Bool=false)
    haskey(w.seen, m) && return
    w.seen[m] = nothing
    # A root is entered even in a library module: e.g. the default `process(project, item)`
    # forwards to the project's `process(item)`.
    root || changeable(w, m.module) || return
    io = IOBuffer()
    print(io, normtype(m.sig), '\n')
    # Walk the types named in the signature: a method on `MyType` depends on `MyType`'s layout.
    for p in Base.unwrap_unionall(m.sig).parameters
        p isa DataType && !(p <: Function) && visit_type(w, p)
    end
    ci = try
        Base.uncompressed_ast(m)
    catch
        nothing
    end
    if ci === nothing
        print(io, "<no source>")         # e.g. builtins or stripped IR
    else
        for stmt in ci.code
            stmt_text(w, io, stmt)
            print(io, '\n')
        end
    end
    label = string(m.module, '.', normname(m.name))
    push!(w.methods_seen, m)
    push!(w.entries, label => bytes2hex(sha1(take!(io))))
end

"""
    code_revision(roots; exclude=Symbol[]) -> RevisionReport

Hash the code reachable by name from `roots`. A root is a `Method`, a function or closure value,
or a type. Methods in modules that cannot change in a session (Base, Core, stdlib, registry
packages, and the module roots named in `exclude`) are not entered.

The hash is order independent: it is the hash of the sorted content hashes of every reached
method, type, const value and captured value.
"""
function code_revision(roots; exclude::Vector{Symbol}=Symbol[], type_rule::Symbol=:exact,
        deep::Bool=true)::RevisionReport
    w = Walk(exclude, Base.get_world_counter(), IdDict{Any,Nothing}(), Pair{String,String}[], 0,
        String[], String[], IdDict{Module,Bool}(), type_rule, deep, Pair{String,Any}[], Method[])
    for root in roots
        root isa Method ? visit_method(w, root; root=true) : visit_value(w, root)
    end
    sort!(w.entries; by=last)
    h = bytes2hex(sha1(join(last.(w.entries), '\n')))
    count_prefix(p) = count(e -> !startswith(first(e), "type ") && !startswith(first(e), "const ") &&
        !startswith(first(e), "global ") && !startswith(first(e), "capture "), w.entries)
    return RevisionReport(h, count_prefix(""), w.functions,
        count(e -> startswith(first(e), "type "), w.entries),
        count(e -> startswith(first(e), "const ") || startswith(first(e), "global ") ||
            startswith(first(e), "capture "), w.entries),
        sort!(unique(w.nonconst)), sort!(unique(w.unhashed)), w.entries, w.polled, w.methods_seen)
end

Base.show(io::IO, r::RevisionReport) = print(io, "RevisionReport(", r.hash[1:10], ", ", r.methods,
    " methods, ", r.types, " types, ", r.values, " values, ", r.functions, " functions scanned)")

end
