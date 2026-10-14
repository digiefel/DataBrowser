# Prototype for approach C: a load-time transform that makes user code report what it ran.
#
# Two halves:
#   runtime   - `run_recorded(f)` runs one stage with a `Record`; `snapshot`/`changes` check it later.
#   transform - `TrackCode(mod)` is the `mapexpr` for `include`, `Revise.track` and REPL input.
#
# The mapexpr wraps each top-level statement in `@track`; at lowering time `@track` expands the
# statement's macros and inserts, into every user function body:
#   - `CodeTrack.enter(self, args...)` as the first statement: records the call signature
#     (function type + runtime argument types). Re-dispatching that signature later tells whether
#     the same method would still run. This catches calls from anywhere: static calls,
#     `g[1](x)`, `p.f(x)`, callbacks called inside `map`, package code calling user closures.
#   - `CodeTrack.gread(mod, :x, x)` around reads of non-const globals and of const globals that
#     hold mutable values (Vector, Dict, Ref, mutable struct): records a content hash once per run.
#   - optional (`sites=true`): `CodeTrack.note_call(f, args...)` before calls whose callee is not
#     a global name. Kept to answer the research question; `enter` makes it redundant (findings.md).
module CodeTrack

using Base.ScopedValues: ScopedValue, with

export TrackCode, run_recorded, snapshot, changes, UntrackableCode

# ---------------------------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------------------------

"What one stage run touched: call signatures of user methods, and global values."
mutable struct Record
    const lock::Threads.SpinLock
    const sigs::Set{Type}
    const globals::Dict{Tuple{Module,Symbol},UInt64}
end
Record() = Record(Threads.SpinLock(), Set{Type}(), Dict{Tuple{Module,Symbol},UInt64}())

# The record of the stage run in progress. A ScopedValue reaches tasks started with
# `Threads.@threads`, `@spawn` and `@async`, but a lookup costs ~50 ns and allocates once a value
# is set. So each task caches the value in its task-local storage (~5 ns), and a global counter
# lets code outside any recording skip both.
const CURRENT = ScopedValue{Union{Nothing,Record}}(nothing)
const ACTIVE = Threads.Atomic{Int}(0)
const KEY = :CodeTrack_record
const UNSET = :unset

# Only the counter check is inlined into user code; the rest is one shared compiled function,
# which keeps the instrumented methods small to compile.
@inline current() = ACTIVE[] == 0 ? nothing : current_slow()

@noinline function current_slow()
    d = task_local_storage()
    r = get(d, KEY, UNSET)
    r === UNSET || return r::Union{Nothing,Record}
    r = CURRENT[]                  # first lookup in a child task
    d[KEY] = r
    return r
end

"Run `f()` while recording. Returns `(value, record)`."
function run_recorded(f)
    r = Record()
    d = task_local_storage()
    old = get(d, KEY, UNSET)
    d[KEY] = r
    Threads.atomic_add!(ACTIVE, 1)
    try
        return with(f, CURRENT => r), r
    finally
        Threads.atomic_sub!(ACTIVE, 1)
        old === UNSET ? delete!(d, KEY) : (d[KEY] = old)
    end
end

# The dispatch signature of a call. Generated so that it folds to a constant.
@generated sigof(f, args...) = :($(Tuple{f, args...}))

# One cache cell per key (a signature type, or `Val{name}` for a global): the last record that
# already holds this key. A hot loop then pays one pointer comparison instead of a lock.
# A generator may run more than once for the same key; extra cells only cost extra lock trips.
mutable struct Cell
    @atomic last::Any
end
@generated cell(::Type{K}) where {K} = :($(Cell(nothing)))

@inline function note_sig!(r::Record, ::Type{S}) where {S}
    c = cell(S)
    (@atomic :monotonic c.last) === r && return nothing
    @lock r.lock push!(r.sigs, S)
    @atomic :monotonic c.last = r
    return nothing
end

"Inserted at the start of every user method body."
@inline function enter(self, args...)
    r = current()
    r === nothing || note_sig!(r, sigof(self, args...))
    return nothing
end

"Inserted before a call whose callee is a value (`sites=true` only)."
@inline function note_call(f, args...)
    r = current()
    r === nothing || note_sig!(r, sigof(f, args...))
    return nothing
end

"Inserted around a read of a global that can change without a method redefinition."
@inline function gread(mod::Module, ::Val{sym}, val) where {sym}
    r = current()
    r === nothing || note_global!(r, mod, Val(sym), val)
    return val
end

"Like `gread`, for names not defined when the code was transformed (forward references)."
@inline function gread_maybe(mod::Module, ::Val{sym}, val) where {sym}
    r = current()
    r === nothing || note_global!(r, mod, Val(sym), val; maybe=true)
    return val
end

"Replaces `getglobal(mod, sym)` in user code."
gread_dynamic(mod::Module, sym::Symbol) = gread(mod, Val(sym), getglobal(mod, sym))

@inline function note_global!(r::Record, mod::Module, ::Val{sym}, @nospecialize(val); maybe=false) where {sym}
    c = cell(Val{sym})
    last = @atomic :monotonic c.last
    last isa Tuple && last[1] === r && last[2] === mod && return nothing   # cell key is the name only
    note_global_slow!(r, mod, sym, val, maybe)
    @atomic :monotonic c.last = (r, mod)
    return nothing
end

@noinline function note_global_slow!(r::Record, mod::Module, sym::Symbol, @nospecialize(val), maybe::Bool)
    maybe && isconst(mod, sym) && !needs_content(val) && return nothing
    key = (mod, sym)
    @lock r.lock haskey(r.globals, key) && return nothing
    h = content_hash(val)
    @lock r.lock get!(r.globals, key, h)
    return nothing
end

# A const binding needs a recorded read only when its value can change in place.
needs_content(@nospecialize v) = !(v isa Function || v isa Type || v isa Module) && ismutable(v)

"Hash of a value's content (full, not sampled; follows fields and closure captures)."
function content_hash(@nospecialize(x), h::UInt=UInt(0), depth::Int=0)
    depth > 8 && return hash(objectid(x), h)   # TODO: deep structures hash by identity below 8 levels
    if x isa Union{Number,Symbol,AbstractString,Module,Type,Nothing,Missing,Char}
        return hash(x, h)
    elseif x isa AbstractArray
        h = hash(size(x), hash(typeof(x), h))
        for e in x
            h = isbits(e) ? hash(e, h) : content_hash(e, h, depth + 1)
        end
        return h
    elseif x isa Union{AbstractDict,AbstractSet}
        s = UInt(0)   # order-independent
        for e in x
            s += content_hash(e, UInt(0), depth + 1)
        end
        return hash(s, hash(typeof(x), h))
    else
        h = hash(typeof(x), h)
        for i in 1:nfields(x)
            h = isdefined(x, i) ? content_hash(getfield(x, i), h, depth + 1) : hash(:undef, h)
        end
        return h
    end
end

"What a later check compares against: the method each signature dispatched to, and global hashes."
struct Snapshot
    methods::Vector{Pair{Type,Any}}
    globals::Dict{Tuple{Module,Symbol},UInt64}
end

dispatch(@nospecialize sig) = (m = Base._which(sig; raise=false); m === nothing ? nothing : m.method)

snapshot(r::Record) = Snapshot([s => dispatch(s) for s in r.sigs], copy(r.globals))

"Reasons why the recorded run is out of date; empty when it is still valid."
function changes(s::Snapshot)
    out = String[]
    for (sig, m) in s.methods
        dispatch(sig) === m || push!(out, "method for $sig changed")
    end
    for ((mod, sym), h) in s.globals
        if !isdefinedglobal(mod, sym)
            push!(out, "global $mod.$sym removed")
        elseif content_hash(getglobal(mod, sym)) != h
            push!(out, "global $mod.$sym changed")
        end
    end
    return out
end

# ---------------------------------------------------------------------------------------------
# Transform
# ---------------------------------------------------------------------------------------------

"""
    TrackCode(mod; sites=false)

The `mapexpr` to pass to `include`, `Revise.track` and the REPL. Immutable, so two instances
for the same module compare `===`, which Revise uses to decide that the transform did not change.
"""
struct TrackCode <: Function
    mod::Module
    sites::Bool
end
TrackCode(mod::Module; sites::Bool=false) = TrackCode(mod, sites)

struct UntrackableCode <: Exception
    msg::String
    where::Any
end
Base.showerror(io::IO, e::UntrackableCode) =
    print(io, "UntrackableCode: ", e.msg, e.where === nothing ? "" : "\n  at $(e.where.file):$(e.where.line)")

# Walk state. `locals` are the names that are local at this point; `infunc` is true inside a
# function body (the only code that runs during a stage).
struct Scope
    t::TrackCode
    locals::Set{Symbol}
    infunc::Bool
    line::Base.RefValue{Any}
end
inner(sc::Scope, names; infunc=sc.infunc) = Scope(sc.t, union(sc.locals, names), infunc, sc.line)
untrackable(sc::Scope, msg) = throw(UntrackableCode(msg, sc.line[]))

const CT = @__MODULE__
ref(name::Symbol) = GlobalRef(CT, name)

# The mapexpr only wraps each statement in `@track`. Expansion then happens when Julia lowers
# the statement, in order, in the right module. Two reasons:
#   - Revise compares the expressions the mapexpr returns to decide what changed. Expanded code
#     holds objects that never compare equal (`@sprintf` embeds a `Printf.Format`) and fresh
#     gensyms, so Revise would redefine those methods on every save.
#   - `includet(mapexpr, file)` maps the whole file before running any of it; expanding eagerly
#     fails on macros from a `using` earlier in the same file.
function (t::TrackCode)(@nospecialize ex)
    ex isa Expr || return ex
    ex.head === :toplevel && return Expr(:toplevel, map(t, ex.args)...)
    ex.head === :module && throw(UntrackableCode(
        "`module` blocks in project files are not tracked; put the module in a package or remove it", nothing))
    lnn = firstline(ex)
    return Expr(:macrocall, GlobalRef(CT, Symbol("@track")), something(lnn, LineNumberNode(0)), t.sites, ex)
end

macro track(sites::Bool, ex)
    return esc(transform(__module__, ex; sites))
end

"Expand macros in `ex` and rewrite it. Used by `@track`; call it directly to see the result."
function transform(mod::Module, @nospecialize(ex); sites::Bool=false)
    lnn = firstline(ex)
    ex = macroexpand(mod, ex)
    return tx(ex, Scope(TrackCode(mod, sites), Set{Symbol}(), false, Ref{Any}(lnn)))
end

"Runtime entry for `Core.eval(m, ex)` at top level: transform the evaluated code too."
transform_runtime(m::Module, @nospecialize ex) = TrackCode(m)(ex)

firstline(ex) = ex isa LineNumberNode ? ex :
    ex isa Expr ? (for a in ex.args; l = firstline(a); l === nothing || return l; end; nothing) : nothing

const SKIP_HEADS = (:quote, :inert, :meta, :line, :using, :import, :export, :public, :macro,
    :loopinfo, :inbounds, :boundscheck, :isdefined, :foreigncall, :cfunction, :symbolicgoto,
    :symboliclabel, :static_parameter, :inline, :noinline, :aliasscope, :popaliasscope, :curly,
    :where, :<:, :>:, :var"hygienic-scope")
const SKIP_CALLEES = (:ccall, :cglobal, :llvmcall, :new, :splatnew)
const FORBIDDEN_IN_FUNCTIONS = (:eval, :include, :include_string, :evalfile)

isopassign(h::Symbol) = h !== :(=) && h !== :(.=) && h !== :(==) && endswith(String(h), "=") &&
    !(h in (:(<=), :(>=), :(!=), :(===), :(!==)))
isdotop(s::Symbol) = (str = String(s); length(str) > 1 && str[1] == '.')

function isfuncdef(ex)
    ex isa Expr || return false
    ex.head in (:function, :->) && return true
    if ex.head === :(=)
        lhs = ex.args[1]
        while lhs isa Expr && lhs.head in (:where, :(::))
            lhs.head === :(::) && length(lhs.args) == 1 && return false
            lhs = lhs.args[1]
        end
        return lhs isa Expr && lhs.head === :call
    end
    return false
end

# --- scope analysis -------------------------------------------------------------------------

lhsnames!(acc, ex) =
    if ex isa Symbol
        push!(acc, ex)
    elseif ex isa Expr && ex.head in (:tuple, :parameters)
        foreach(a -> lhsnames!(acc, a), ex.args)
    elseif ex isa Expr && ex.head in (:(::), :..., :kw)
        lhsnames!(acc, ex.args[1])
    end

# Names assigned directly in this scope (not inside nested scopes): those are locals here.
function assigned!(acc::Set{Symbol}, ex)
    ex isa Expr || return acc
    h = ex.head
    if isfuncdef(ex)
        name = funcname(ex)
        name isa Symbol && push!(acc, name)
    elseif h === :(=) || (isopassign(h) && !startswith(String(h), "."))
        lhsnames!(acc, ex.args[1])
        assigned!(acc, ex.args[2])
    elseif h === :local
        for a in ex.args
            a isa Expr && a.head === :(=) ? (lhsnames!(acc, a.args[1]); assigned!(acc, a.args[2])) : lhsnames!(acc, a)
        end
    elseif h in (:for, :while, :let, :try, :generator, :comprehension, :typed_comprehension,
                 :struct, :quote, :global, :macro) || h in SKIP_HEADS
        # nested scope or declaration: handled when the walk enters it
    else
        foreach(a -> assigned!(acc, a), ex.args)
    end
    return acc
end

function declared_globals!(acc::Set{Symbol}, ex)
    ex isa Expr || return acc
    if ex.head === :global
        for a in ex.args
            lhsnames!(acc, a isa Expr && a.head === :(=) ? a.args[1] : a)
        end
    elseif !(ex.head in (:for, :while, :let, :try, :function, :->, :generator, :struct, :quote))
        foreach(a -> declared_globals!(acc, a), ex.args)
    end
    return acc
end

function scope_for(sc::Scope, newnames, body; infunc=sc.infunc)
    names = union!(Set{Symbol}(newnames), assigned!(Set{Symbol}(), body))
    s = inner(sc, names; infunc)
    setdiff!(s.locals, declared_globals!(Set{Symbol}(), body))
    return s
end

# Resolve `x`, `M.x` or a GlobalRef to (module, name) when it names a global; else nothing.
function globalname(ex, sc::Scope)
    if ex isa Symbol
        ex in sc.locals && return nothing
        return (sc.t.mod, ex)
    elseif ex isa GlobalRef
        return (ex.mod, ex.name)
    elseif ex isa Expr && ex.head === :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode
        g = globalname(ex.args[1], sc)
        g === nothing && return nothing
        isdefinedglobal(g...) && isconst(g...) || return nothing
        m = getglobal(g...)
        m isa Module || return nothing
        return (m, ex.args[2].value::Symbol)
    end
    return nothing
end

# --- the walk -------------------------------------------------------------------------------

txall(args, sc) = Any[tx(a, sc) for a in args]

function tx(@nospecialize(ex), sc::Scope)
    if ex isa LineNumberNode
        sc.line[] = ex
        return ex
    elseif ex isa Symbol || ex isa GlobalRef
        return sc.infunc ? read_global(ex, sc) : ex
    elseif !(ex isa Expr)
        return ex
    end
    h = ex.head
    h in SKIP_HEADS && return ex
    h === :module && untrackable(sc, "`module` blocks in project files are not tracked; put the module in a package or remove it")
    h in (:generated, :generated_only) &&
        untrackable(sc, "`@generated` functions build their body from types at compile time; the transform cannot see that code")
    h === :copyast && sc.infunc &&
        untrackable(sc, "`@eval` inside a function defines code while a stage runs")
    isfuncdef(ex) && return tx_function(ex, sc)
    h === :do && return tx(undo(ex), sc)
    h === :call && return tx_call(ex, sc)
    h === :. && return tx_dot(ex, sc)
    (h === :(=) || isopassign(h)) && return Expr(h, tx_lhs(ex.args[1], sc), tx(ex.args[2], sc))
    if h in (:local, :global, :const)
        return Expr(h, Any[a isa Expr && a.head === :(=) ? Expr(:(=), tx_lhs(a.args[1], sc), tx(a.args[2], sc)) : a
                          for a in ex.args]...)
    end
    h === :let && return tx_let(ex, sc)
    if h === :for
        spec, body = ex.args
        specs = spec isa Expr && spec.head === :block ? spec.args : Any[spec]
        vars = Set{Symbol}()
        newspecs = Any[]
        for s in specs
            s isa LineNumberNode && (push!(newspecs, s); continue)
            push!(newspecs, Expr(s.head, s.args[1], tx(s.args[2], inner(sc, vars))))
            lhsnames!(vars, s.args[1])
        end
        spec2 = spec isa Expr && spec.head === :block ? Expr(:block, newspecs...) : newspecs[1]
        return Expr(:for, spec2, tx(body, scope_for(sc, vars, body)))
    end
    h === :while && return Expr(:while, tx(ex.args[1], sc), tx(ex.args[2], scope_for(sc, (), ex.args[2])))
    if h === :try
        args = copy(ex.args)
        args[1] = tx(args[1], scope_for(sc, (), args[1]))
        var = args[2]
        length(args) >= 3 && (args[3] = tx(args[3], scope_for(sc, var isa Symbol ? (var,) : (), args[3])))
        for i in 4:length(args)
            args[i] = tx(args[i], scope_for(sc, (), args[i]))
        end
        return Expr(:try, args...)
    end
    h === :generator && return tx_generator(ex, sc)
    h === :struct && return Expr(:struct, ex.args[1], ex.args[2],
        Expr(:block, Any[isfuncdef(a) ? tx_function(a, sc) : a for a in ex.args[3].args]...))
    if h === :(::)
        return length(ex.args) == 2 ? Expr(:(::), tx(ex.args[1], sc), ex.args[2]) : ex
    end
    h === :kw && return Expr(:kw, ex.args[1], tx(ex.args[2], sc))
    if h === :parameters   # `f(; x)` is `f(; x = x)`: a read of `x`
        return Expr(:parameters, Any[a isa Symbol ? Expr(:kw, a, tx(a, sc)) : tx(a, sc) for a in ex.args]...)
    end
    return Expr(h, txall(ex.args, sc)...)
end

# `f(args) do x ... end` -> `f(x -> ..., args)` so a wrapped callee gets the right arguments.
function undo(ex::Expr)
    call, lambda = ex.args
    args = copy(call.args)
    i = length(args) >= 2 && args[2] isa Expr && args[2].head === :parameters ? 3 : 2
    insert!(args, i, lambda)
    return Expr(:call, args...)
end

function tx_lhs(lhs, sc::Scope)
    lhs isa Symbol && return lhs
    lhs isa Expr || return lhs
    lhs.head in (:tuple, :parameters) && return Expr(lhs.head, Any[tx_lhs(a, sc) for a in lhs.args]...)
    lhs.head === :(::) && return Expr(:(::), tx_lhs(lhs.args[1], sc), lhs.args[2:end]...)
    lhs.head === :... && return Expr(:..., tx_lhs(lhs.args[1], sc))
    return tx(lhs, sc)   # `a[i] = ...`, `p.x = ...`: reads of `a` and `p`
end

function read_global(ex, sc::Scope)
    ex isa Symbol && (ex in sc.locals || ex in (:end, :begin, Symbol("#self#")) || isdotop(ex)) && return ex
    mod, sym = ex isa GlobalRef ? (ex.mod, ex.name) : (sc.t.mod, ex)
    isdotop(sym) && return ex   # `Base.:(.-)` from macro hygiene: syntax, not a binding
    if isdefinedglobal(mod, sym)
        isconst(mod, sym) && !needs_content(getglobal(mod, sym)) && return ex
        return Expr(:call, ref(:gread), mod, Val(sym), ex)
    end
    return Expr(:call, ref(:gread_maybe), mod, Val(sym), ex)
end

function tx_dot(ex::Expr, sc::Scope)
    a, b = ex.args
    if b isa QuoteNode   # field access, or `Module.name`
        g = globalname(ex, sc)
        g !== nothing && sc.infunc && return read_global(GlobalRef(g...), sc) == GlobalRef(g...) ? ex :
            Expr(:call, ref(:gread), g[1], Val(g[2]), ex)
        return Expr(:., tx(a, sc), b)
    end
    # dot call `f.(args)`
    if sc.t.sites && sc.infunc && isdynamic(a, sc)   # `f.(xs)`: record per element
        rec = Expr(:->, Expr(:tuple, Expr(:..., :args)),
                   Expr(:block, Expr(:call, ref(:note_call), Symbol("#ct_f"), Expr(:..., :args)),
                        Expr(:call, Symbol("#ct_f"), Expr(:..., :args))))
        return Expr(:let, Expr(:(=), Symbol("#ct_f"), tx(a, sc)), Expr(:., rec, Expr(:tuple, txall(b.args, sc)...)))
    end
    return Expr(:., tx(a, sc), Expr(b.head, txall(b.args, sc)...))
end

# A callee is dynamic when it is not a name: a local, a field, an index result, a call result.
function isdynamic(f, sc::Scope)
    f isa Symbol && isdotop(f) && return false
    f isa Expr && f.head === :curly && return false
    return globalname(f, sc) === nothing
end

function tx_call(ex::Expr, sc::Scope)
    f = ex.args[1]
    f in SKIP_CALLEES && return f in (:new, :splatnew) ? Expr(:call, f, txall(ex.args[2:end], sc)...) : ex
    g = globalname(f, sc)
    if g !== nothing && g[2] in FORBIDDEN_IN_FUNCTIONS && g[1] in (sc.t.mod, Core, Base, Base.MainInclude)
        if sc.infunc
            untrackable(sc, "`$(g[2])` inside a function defines code while a stage runs; move it to top level")
        elseif g[2] === :include && length(ex.args) == 2       # top-level include: transform that file too
            return Expr(:call, f, sc.t, ex.args[2])
        elseif g[2] === :eval
            args = copy(ex.args)
            m = length(args) == 3 ? args[2] : sc.t.mod
            args[end] = Expr(:call, ref(:transform_runtime), m, args[end])
            return Expr(:call, args...)
        end
    end
    if g !== nothing && g[2] === :getglobal && g[1] in (Core, Base) && sc.infunc
        return Expr(:call, ref(:gread_dynamic), txall(ex.args[2:end], sc)...)
    end
    args = txall(ex.args[2:end], sc)
    if sc.t.sites && sc.infunc && isdynamic(f, sc)
        # `let f = ..., a1 = ...; note_call(f, a1); f(a1) end`: the callee stays a direct call.
        # Passing it into a wrapper instead (`call(f, a1)`) made Julia stop specializing the
        # enclosing method on `f` (a function argument only passed along is not specialized):
        # 25x slower on the fit benchmark.
        params = filter(a -> a isa Expr && a.head === :parameters, args)
        rest = filter(a -> !(a isa Expr && a.head === :parameters), args)
        # A local callee is used by name: Julia only specializes a method on a function argument
        # that the body calls directly, and `#ct_f = cb; #ct_f(x)` does not count.
        fname = f isa Symbol ? f : Symbol("#ct_f")
        binds = f isa Symbol ? Any[] : Any[Expr(:(=), fname, tx(f, sc))]
        uses = Any[]
        for (i, a) in enumerate(rest)
            n = Symbol("#ct_a", i)
            splat = a isa Expr && a.head === :...
            push!(binds, Expr(:(=), n, splat ? a.args[1] : a))
            push!(uses, splat ? Expr(:..., n) : n)
        end
        return Expr(:let, Expr(:block, binds...),
            Expr(:block, Expr(:call, ref(:note_call), fname, uses...),
                         Expr(:call, fname, params..., uses...)))
    end
    return Expr(:call, tx(f, sc), args...)
end

function tx_let(ex::Expr, sc::Scope)
    binds, body = ex.args
    list = binds isa Expr && binds.head === :block ? binds.args : Any[binds]
    names = Set{Symbol}()
    newbinds = Any[]
    for b in list
        if b isa Expr && b.head === :(=) && !isfuncdef(b)
            push!(newbinds, Expr(:(=), b.args[1], tx(b.args[2], inner(sc, names))))
            lhsnames!(names, b.args[1])
        else
            b isa Symbol || b isa Expr && b.head === :(::) ? lhsnames!(names, b) : nothing
            push!(newbinds, isfuncdef(b) ? tx_function(b, inner(sc, names)) : b)
        end
    end
    binds2 = binds isa Expr && binds.head === :block ? Expr(:block, newbinds...) : (isempty(newbinds) ? binds : newbinds[1])
    return Expr(:let, binds2, tx(body, scope_for(sc, names, body)))
end

function tx_generator(ex::Expr, sc::Scope)
    body, specs = ex.args[1], ex.args[2:end]
    vars = Set{Symbol}()
    function spec!(s)
        if s isa Expr && s.head === :filter
            newspecs = Any[spec!(x) for x in s.args[2:end]]
            return Expr(:filter, tx(s.args[1], inner(sc, vars)), newspecs...)
        end
        out = Expr(:(=), s.args[1], tx(s.args[2], inner(sc, vars)))
        lhsnames!(vars, s.args[1])
        return out
    end
    newspecs = Any[spec!(s) for s in specs]
    return Expr(:generator, tx(body, scope_for(sc, vars, body)), newspecs...)
end

# --- functions ------------------------------------------------------------------------------

function funcname(ex::Expr)
    sig = ex.head === :-> ? nothing : ex.args[1]
    while sig isa Expr && sig.head in (:where, :(::))
        sig = sig.args[1]
    end
    sig isa Expr && sig.head === :call || return nothing
    return sig.args[1]
end

# Split a signature into (call-or-tuple, static parameter names).
function unwrap_sig(sig)
    sparams = Set{Symbol}()
    while sig isa Expr && sig.head in (:where, :(::))
        if sig.head === :where
            for p in sig.args[2:end]
                p isa Symbol && push!(sparams, p)
                p isa Expr && p.head in (:<:, :>:) && p.args[1] isa Symbol && push!(sparams, p.args[1])
                p isa Expr && p.head === :comparison && push!(sparams, p.args[3])
            end
        elseif length(sig.args) == 1
            break
        end
        sig = sig.args[1]
    end
    return sig, sparams
end

# Rebuild `sig` with `newcall` in place of the innermost call/tuple.
rewrap(sig, newcall) = sig isa Expr && sig.head in (:where, :(::)) && !(sig.head === :(::) && length(sig.args) == 1) ?
    Expr(sig.head, rewrap(sig.args[1], newcall), sig.args[2:end]...) : newcall

function tx_function(ex::Expr, sc::Scope)
    ex.head === :function && length(ex.args) == 1 && return ex   # `function f end`
    sig, body = ex.args
    if ex.head === :->
        call = sig isa Expr && sig.head === :tuple ? sig :
               sig isa Expr && sig.head === :block ? Expr(:tuple, filter(a -> !(a isa LineNumberNode), sig.args)...) :
               Expr(:tuple, sig)
        inner_sig, sparams = call, Set{Symbol}()
    else
        inner_sig, sparams = unwrap_sig(sig)
    end
    anon = inner_sig isa Expr && inner_sig.head === :tuple
    head = anon ? nothing : inner_sig.args[1]
    rawargs = anon ? inner_sig.args : inner_sig.args[2:end]

    # Name every positional argument so `enter` can see its runtime type.
    names = Set{Symbol}(sparams)
    unpack = Any[]
    entryargs = Any[]
    newargs = Any[]
    k = 0
    for a in rawargs
        if a isa Expr && a.head === :parameters
            ps = Any[]
            for p in a.args
                lhsnames!(names, p)
                push!(ps, p isa Expr && p.head === :kw ? Expr(:kw, p.args[1], p.args[2]) : p)
            end
            push!(newargs, Expr(:parameters, ps...))
            continue
        end
        a2, entry = name_arg(a, () -> (k += 1; Symbol("#ct_arg", k)), unpack)
        lhsnames!(names, a2)
        push!(newargs, a2)
        push!(entryargs, entry)
    end
    for u in unpack
        lhsnames!(names, u.args[1])
    end
    # The callable itself: `#self#`, or the name given in `(p::P)(x)`.
    self = Symbol("#self#")
    if head isa Expr && head.head === :(::)
        if length(head.args) == 1
            head = Expr(:(::), Symbol("#ct_self"), head.args[1])
        end
        self = head.args[1]
        push!(names, self)
    end
    fsc = scope_for(sc, names, body; infunc=true)
    fsc = Scope(fsc.t, fsc.locals, true, sc.line)
    # Default values are evaluated inside the function.
    newargs = Any[tx_default(a, fsc) for a in newargs]
    newcall = anon ? Expr(:tuple, newargs...) : Expr(:call, head, newargs...)
    newsig = ex.head === :-> ? newcall : rewrap(sig, newcall)

    entry = Expr(:call, ref(:enter), self, entryargs...)
    stmts = body isa Expr && body.head === :block ? copy(body.args) : Any[body]
    pos = !isempty(stmts) && stmts[1] isa LineNumberNode ? 2 : 1
    for (i, s) in enumerate(Any[unpack..., entry])
        insert!(stmts, pos + i - 1, s)
    end
    newbody = Expr(:block, Any[tx(s, fsc) for s in stmts]...)
    return Expr(ex.head, newsig, newbody)
end

# Returns (argument expression to keep in the signature, expression passed to `enter`).
function name_arg(a, fresh, unpack)
    if a isa Symbol
        return a, a
    elseif a isa Expr && a.head === :(::) && length(a.args) == 1          # `::T`
        n = fresh()
        return Expr(:(::), n, a.args[1]), n
    elseif a isa Expr && a.head === :(::) && a.args[1] isa Expr          # `(x, y)::T`
        n = fresh()
        push!(unpack, Expr(:(=), a.args[1], n))
        return Expr(:(::), n, a.args[2]), n
    elseif a isa Expr && a.head === :(::)
        return a, a.args[1]
    elseif a isa Expr && a.head === :tuple                               # `(x, y)`
        n = fresh()
        push!(unpack, Expr(:(=), a, n))
        return n, n
    elseif a isa Expr && a.head === :kw
        inner, entry = name_arg(a.args[1], fresh, unpack)
        return Expr(:kw, inner, a.args[2]), entry
    elseif a isa Expr && a.head === :...
        inner, entry = name_arg(a.args[1], fresh, unpack)
        return Expr(:..., inner), Expr(:..., entry)
    elseif a isa Expr && a.head === :meta                                # `@nospecialize x`
        inner, entry = name_arg(a.args[end], fresh, unpack)
        return Expr(:meta, a.args[1:end-1]..., inner), entry
    end
    error("CodeTrack: unsupported argument form $a")   # FIXME: report as UntrackableCode with location
end

tx_default(a, sc) = a isa Expr && a.head === :kw ? Expr(:kw, a.args[1], tx(a.args[2], sc)) :
    a isa Expr && a.head === :parameters ? Expr(:parameters, Any[tx_default(p, sc) for p in a.args]...) : a

end # module
