module AnalysisMacroProposal

export @analyze, @canvas, Input, Follow, AnalysisDefinition, CanvasDefinition,
       evaluate, data, members, present, emit_canvas, graph, Evaluator

# Scratch protocol only. These are not replacements for DataBrowser's native item types.
abstract type Value end

"""A supplied input value, optionally retaining the items that contributed to it."""
struct Input <: Value
    id::String
    payload::Any
    inputs::Vector{Value}
    revision::Int
end
Input(id, payload; inputs=Value[], revision=1) = Input(string(id), payload, Value[inputs...], revision)

"""One recorded output; every analysis run uses this same fixed Julia type."""
struct Output <: Value
    id::String
    payload::Any
    inputs::Vector{Value}
    revision::Int
end

"""Read an input binding at the beginning of each explicitly requested evaluation."""
struct Follow
    resolve::Function
end

"""Ordinary data carried by a scratch input/output value."""
data(x::Value) = x.payload
data(x) = x
"""Direct contributing values, without recursive flattening."""
members(x::Value) = x.inputs

struct Node
    name::Symbol
    dependencies::Vector{Symbol}
    call::Function
    roots::Function
    expression::String
    line::Int
end

"""Named, parameterized analysis declaration; constructing it executes no numerical work."""
struct AnalysisDefinition
    name::Symbol
    inputs::Vector{Symbol}
    defaults::NamedTuple
    nodes::Vector{Node}
    file::String
    line::Int
    owner::Module
end

struct Run
    name::Symbol
    scope::String
    outputs::Dict{Symbol,Output}
end
Base.getindex(run::Run, name::Symbol) = run.outputs[name]

struct Instance
    name::Symbol
    definition::AnalysisDefinition
    bindings::NamedTuple
    owner::Module
end
struct OutputRef
    instance::Instance
    output::Symbol
end
function Base.getproperty(def::AnalysisDefinition, name::Symbol)
    name in fieldnames(AnalysisDefinition) && return getfield(def, name)
    error("$name belongs to an analysis instance; use @analyze coarse = $(getfield(def,:name))(inputs...)")
end
function Base.getproperty(instance::Instance, name::Symbol)
    name in fieldnames(Instance) && return getfield(instance, name)
    def = getfield(instance, :definition)
    any(n -> n.name == name, def.nodes) || error("No output named $name")
    return OutputRef(instance, name)
end
function _instance(name, definition, positional, keywords, owner)
    length(positional) == length(definition.inputs) || error("Bind all named analysis inputs")
    bindings = merge(NamedTuple{Tuple(definition.inputs)}(positional), keywords)
    return Instance(name, definition, bindings, owner)
end

struct CacheEntry
    signature::Any
    value::Output
end
"""Scratch demand evaluator with per-node reuse; not the production workspace scheduler."""
mutable struct Evaluator
    cache::Dict{String,CacheEntry}
    revision::Int
end
Evaluator() = Evaluator(Dict{String,CacheEntry}(), 0)

struct View
    name::Symbol
    source::OutputRef
    kind::Symbol
    settings::NamedTuple
end

"""Canvas declaration over analysis outputs. This scratch model does not render a GUI."""
struct CanvasDefinition
    name::Symbol
    views::Vector{View}
end

function _references!(out, ex, known)
    if ex isa Symbol
        ex in known && !(ex in out) && push!(out, ex)
    elseif ex isa Expr
        ex.head in (:quote, :inert) && return out
        ex.head in (:block, :let, :for, :while, :function, :->, :generator, :comprehension) &&
            error("Put control flow/local definitions in an ordinary helper; the analysis block names calls and values")
        if ex.head == :.
            _references!(out, first(ex.args), known) # A field name is not a variable read.
        elseif ex.head in (:kw, :(=))
            _references!(out, last(ex.args), known) # A keyword/named-tuple label is not a read.
        else
            foreach(arg -> _references!(out, arg, known), ex.args)
        end
    end
    return out
end

function _roots!(roots, expression, known)
    expression isa Expr || return roots
    if expression.head == :call
        callee = first(expression.args)
        if callee isa Symbol && !(callee in known) && Base.isidentifier(callee)
            callee in roots || push!(roots, callee)
        elseif Meta.isexpr(callee, :.)
            callee in roots || push!(roots, callee)
        end
    end
    expression.head in (:quote, :inert) || foreach(x -> _roots!(roots, x, known), expression.args)
    return roots
end

function _order(def)
    available = Set([def.inputs; collect(keys(def.defaults))])
    pending = copy(def.nodes)
    ordered = Node[]
    while !isempty(pending)
        index = findfirst(n -> all(in(available), n.dependencies), pending)
        index === nothing && error("Cyclic dependencies between outputs: $(join(getfield.(pending, :name), ", "))")
        node = popat!(pending, index)
        push!(ordered, node)
        push!(available, node.name)
    end
    return ordered
end

"""
    @analyze name(input; parameter=literal) begin
        output = ordinary_helper(input; parameter)
        next_output = another_helper(output)
    end

Candidate A: top-level assignments name independently inspectable computations. Helpers contain
arbitrary numerical code. Forward references are allowed; cycles and duplicate names are rejected.
This creates a declaration value, not a Julia type or a running task.
"""
macro analyze(header, body)
    Meta.isexpr(header, :call) && header.args[1] isa Symbol ||
        error("Use @analyze name(inputs...; parameters...) begin ... end")
    Meta.isexpr(body, :block) || error("@analyze requires a begin/end block")
    name = header.args[1]
    inputs = Symbol[]
    defaults = Expr[]
    for arg in header.args[2:end]
        if Meta.isexpr(arg, :parameters)
            for kw in arg.args
                Meta.isexpr(kw, :kw) && kw.args[1] isa Symbol || error("Parameters need named defaults")
                push!(defaults, kw)
            end
        else
            arg isa Symbol || error("Inputs are names; native data types are not required in this declaration")
            push!(inputs, arg)
        end
    end
    statements = Tuple{Symbol,Any,Int}[]
    line = __source__.line
    for statement in body.args
        if statement isa LineNumberNode
            line = statement.line
            continue
        end
        Meta.isexpr(statement, :(=)) && statement.args[1] isa Symbol ||
            error("Each top-level statement must be a named assignment; put loops/branches in a helper")
        push!(statements, (statement.args[1], statement.args[2], line))
    end
    isempty(statements) && error("An analysis needs at least one named output")
    names = [inputs; [kw.args[1] for kw in defaults]; [s[1] for s in statements]]
    length(unique(names)) == length(names) || error("Input, parameter and output names must be distinct")
    known = Set(names)
    nodes = map(statements) do (output, rhs, source_line)
        dependencies = _references!(Symbol[], rhs, known)
        closure = Expr(:->, Expr(:tuple, dependencies...), rhs)
        root_names = _roots!(Any[], rhs, known)
        roots = Expr(:->, Expr(:tuple), Expr(:tuple, root_names...))
        :($(GlobalRef(@__MODULE__, :Node))($(QuoteNode(output)),
            $(Expr(:vect, QuoteNode.(dependencies)...)), $closure, $roots, $(string(rhs)), $source_line))
    end
    declaration = :($(GlobalRef(@__MODULE__, :AnalysisDefinition))(
        $(QuoteNode(name)), $(Expr(:vect, QuoteNode.(inputs)...)),
        $(Expr(:tuple, Expr(:parameters, defaults...))), $(Expr(:vect, nodes...)),
        $(string(__source__.file)), $(__source__.line), $(QuoteNode(__module__))))
    return esc(:($name = $declaration))
end

"""Bind a named saved analysis instance without executing it."""
macro analyze(binding)
    Meta.isexpr(binding, :(=)) && binding.args[1] isa Symbol || error("Use @analyze instance = definition(inputs...; settings...)")
    name, call = binding.args
    Meta.isexpr(call, :call) || error("Bind an analysis definition call")
    positional = [a for a in call.args[2:end] if !Meta.isexpr(a, :parameters)]
    keywords = [kw for a in call.args[2:end] if Meta.isexpr(a, :parameters) for kw in a.args]
    return esc(:($name = $(GlobalRef(@__MODULE__, :_instance))($(QuoteNode(name)),
        $(call.args[1]), $(Expr(:tuple, positional...)), $(Expr(:tuple, Expr(:parameters, keywords...))), $(QuoteNode(__module__)))))
end

_stamp(value::Value) = (value.id, value.revision)
_stamp(value) = deepcopy(value) # Only explicit parameters; scientific data use versioned Input.
_code(node) = Tuple((f, Tuple(methods(f))) for f in node.roots() if f isa Function || f isa Type)

"""
    evaluate(evaluator, instance; scope="analysis", targets=nothing) -> Run

Request named outputs, reusing unchanged dependencies. Direct named-helper method replacement
is detected; transitive code tracking, watchers and asynchronous publication are NOT implemented.
"""
function evaluate(engine::Evaluator, instance::Instance; scope=string(instance.owner), targets=nothing)
    return Base.invokelatest(_evaluate_instance, engine, instance, scope, targets)
end
function _evaluate_instance(engine, instance, scope, targets)
    old = instance.definition
    current = isdefined(old.owner, old.name) ? getglobal(old.owner, old.name) : old
    current isa AnalysisDefinition || error("Analysis definition $(old.name) is unavailable")
    result = evaluate(engine, current, "$scope/$(instance.name)"; targets, instance.bindings...)
    return Run(instance.name, result.scope, result.outputs)
end
function evaluate(engine::Evaluator, def::AnalysisDefinition, scope=def.name; targets=nothing, kwargs...)
    return Base.invokelatest(_evaluate, engine, def, string(scope), targets, Dict{Symbol,Any}(kwargs))
end
evaluate(def::AnalysisDefinition, scope=def.name; kwargs...) = evaluate(Evaluator(), def, scope; kwargs...)
function _evaluate(engine, def, scope, targets, supplied)
    allowed = Set([def.inputs; collect(keys(def.defaults))])
    unknown = setdiff(Set(keys(supplied)), allowed)
    isempty(unknown) || error("Unknown inputs/parameters: $(join(unknown, ", "))")
    environment = Dict{Symbol,Any}(pairs(def.defaults))
    merge!(environment, supplied)
    for name in def.inputs
        haskey(environment, name) || error("Missing analysis input: $name")
        value = environment[name]
        environment[name] = value isa Follow ? value.resolve() : value
        environment[name] isa Value || error("Input $name must identify a tracked value; use Input(id, data)")
    end
    _order(def) # Validate the ENTIRE graph before executing any user callback.
    nodes = Dict(n.name => n for n in def.nodes)
    outputs = Dict{Symbol,Output}()
    function request(name)
        haskey(outputs, name) && return outputs[name]
        haskey(nodes, name) || error("No output named $name")
        node = nodes[name]
        for dep in node.dependencies
            haskey(environment, dep) || (environment[dep] = request(dep))
        end
        bindings = [environment[d] for d in node.dependencies]
        signature = (node.expression, _code(node), [(d, _stamp(environment[d])) for d in node.dependencies])
        identity = "$scope/$(def.name)/$name"
        cached = get(engine.cache, identity, nothing)
        if cached !== nothing && isequal(cached.signature, signature)
            output = cached.value
        else
            payload = node.call(data.(bindings)...)
            engine.revision += 1
            output = Output(identity, payload, Value[x for x in bindings if x isa Value], engine.revision)
            engine.cache[identity] = CacheEntry(signature, output)
        end
        outputs[name] = output
        environment[name] = output
        return output
    end
    for name in (targets === nothing ? getfield.(def.nodes, :name) : targets)
        request(name)
    end
    return Run(def.name, scope, outputs)
end

"""Describe named node dependencies without executing analysis."""
graph(def::AnalysisDefinition) = [(name=n.name, inputs=copy(n.dependencies), expression=n.expression) for n in def.nodes]

"""
    @canvas name begin
        panel = heatmap(analysis.grid; colormap=:viridis)
        other = table(analysis.comparison)
    end

Candidate canvas grammar: named views reference named analysis outputs. It creates only view
specifications; no calculation or plotting backend runs at declaration time.
"""
macro canvas(name, body)
    name isa Symbol && Meta.isexpr(body, :block) || error("Use @canvas name begin ... end")
    views = Any[]
    names = Symbol[]
    for statement in body.args
        statement isa LineNumberNode && continue
        Meta.isexpr(statement, :(=)) && statement.args[1] isa Symbol || error("A canvas view needs a name")
        view_name, call = statement.args
        view_name in names && error("Duplicate canvas view: $view_name")
        push!(names, view_name)
        Meta.isexpr(call, :call) && call.args[1] isa Symbol || error("Use view_kind(analysis.output; settings...)")
        kind = call.args[1]
        args = [a for a in call.args[2:end] if !Meta.isexpr(a, :parameters)]
        length(args) == 1 && Meta.isexpr(only(args), :.) || error("A view references one analysis.output")
        keywords = [kw for a in call.args[2:end] if Meta.isexpr(a, :parameters) for kw in a.args]
        push!(views, :($(GlobalRef(@__MODULE__, :View))($(QuoteNode(view_name)), $(only(args)),
            $(QuoteNode(kind)), $(Expr(:tuple, Expr(:parameters, keywords...))))))
    end
    return esc(:($name = $(GlobalRef(@__MODULE__, :CanvasDefinition))($(QuoteNode(name)), $(Expr(:vect, views...)))))
end

"""Resolve views through the same evaluator, requesting only their actual analysis outputs."""
function present(canvas::CanvasDefinition, engine::Evaluator)
    instances = Dict{Symbol,Instance}()
    for view in canvas.views
        instance = view.source.instance
        if haskey(instances, instance.name) && instances[instance.name] !== instance
            error("Two different instances share the name $(instance.name)")
        end
        instances[instance.name] = instance
    end
    runs = Dict(name => evaluate(engine, instance;
        targets=unique([v.source.output for v in canvas.views if v.source.instance.name == name]))
        for (name,instance) in instances)
    return map(canvas.views) do view
        output = runs[view.source.instance.name][view.source.output]
        (; view=view.name, kind=view.kind, output, settings=view.settings)
    end
end

"""Emit executable canvas source from the same view definition a GUI could construct."""
function emit_canvas(canvas::CanvasDefinition)
    io = IOBuffer()
    println(io, "@canvas ", canvas.name, " begin")
    for view in canvas.views
        ref = view.source
        print(io, "    ", view.name, " = ", view.kind, "(", ref.instance.name, ".", ref.output)
        if !isempty(view.settings)
            print(io, "; ")
            print(io, join(("$k=$(repr(v))" for (k,v) in pairs(view.settings)), ", "))
        end
        println(io, ")")
    end
    println(io, "end")
    return String(take!(io))
end

end
