# Scratch proof: let-bound statistics, visible AoG algebra and deferred expressions.
# Deliberately incomplete: no general adapters, scales, GUI editing or interval statistics.
module FitCaptureProbe
import AlgebraOfGraphics as AoG
import Makie
import GLM
import Tables

node(kind, args=(), kwargs=Pair{Symbol,Any}[]) = (; kind, args, kwargs)
isnode(x, kind) = x isa NamedTuple && haskey(x, :kind) && x.kind == kind
function referenced(ex, names)
    found = Symbol[]
    function visit(x)
        x isa Symbol && x in names && push!(found, x)
        x isa Expr && x.head != :quote && foreach(visit, x.args)
    end
    visit(ex)
    unique(found)
end
function valuecode(ex, names)
    refs = referenced(ex, names)
    isempty(refs) && return ex
    context = gensym(:context)
    binds = [:(local $name = $context[$(QuoteNode(name))]) for name in refs]
    closure = :($context -> begin $(binds...); $ex end)
    :($(GlobalRef(@__MODULE__, :node))(:deferred, ($closure, $(QuoteNode(refs)))))
end
function capture(ex, names)
    ex isa Symbol && ex in names && return :($(GlobalRef(@__MODULE__, :node))(:ref, ($(QuoteNode(ex)),)))
    ex isa Expr && ex.head == :call || error("Expected a plot expression in this probe")
    constructor = first(ex.args)
    if constructor in (:+, :*)
        parts = [capture(x, names) for x in ex.args[2:end]]
        return :($(GlobalRef(@__MODULE__, :node))($(QuoteNode(constructor)), ($(parts...),)))
    end
    constructor in (:data, :mapping, :visual, :subvisual, :linear) ||
        error("Unsupported constructor in this probe: $constructor")
    positional = Any[]
    keywords = Any[]
    for arg in ex.args[2:end]
        if arg isa Expr && arg.head == :parameters
            for kw in arg.args
                kw.head == :kw || error("Keyword splats are not supported in this probe")
                push!(keywords, :($(QuoteNode(kw.args[1])) => $(valuecode(kw.args[2], names))))
            end
        else
            push!(positional, constructor == :data && arg isa Symbol && arg in names ?
                capture(arg, names) : valuecode(arg, names))
        end
    end
    :($(GlobalRef(@__MODULE__, :node))($(QuoteNode(constructor)), ($(positional...),), Pair{Symbol,Any}[$(keywords...)]))
end
function captureblock(ex)
    statements = filter(x -> !(x isa LineNumberNode), ex.args)
    bindings = filter(x -> x isa Expr && x.head == :(=), statements)
    all(b -> b.args[1] isa Symbol, bindings) || error("Expected named plot fragments")
    names = [b.args[1] for b in bindings]
    length(unique(names)) == length(names) || error("Duplicate definition")
    definitions = [:($(QuoteNode(b.args[1])) => $(capture(b.args[2], names))) for b in bindings]
    layers = [capture(x, names) for x in statements if !(x isa Expr && x.head == :(=))]
    isempty(layers) && error("Name definitions draw nothing; add at least one layer expression")
    :($(GlobalRef(@__MODULE__, :prepareblock))(Dict{Symbol,Any}($(definitions...)), Any[$(layers...)]))
end

"""Scratch capture of addition-only blocks; the old let probe remains for comparison."""
macro plot(ex)
    ex isa Expr && ex.head == :block && return esc(captureblock(ex))
    ex isa Expr && ex.head == :let || error("This probe requires @plot let … end")
    raw = ex.args[1]
    bindings = raw isa Expr && raw.head == :block ? filter(x -> !(x isa LineNumberNode), raw.args) : [raw]
    all(b -> b isa Expr && b.head == :(=) && b.args[1] isa Symbol, bindings) || error("Expected named constructors")
    names = [b.args[1] for b in bindings]
    length(unique(names)) == length(names) || error("Duplicate statistic name")
    definitions = [:($(QuoteNode(b.args[1])) => $(capture(b.args[2], Symbol[]))) for b in bindings]
    body = filter(x -> !(x isa LineNumberNode), ex.args[2].args)
    length(body) == 1 || error("The body must be one algebraic expression")
    esc(:($(GlobalRef(@__MODULE__, :prepare))(Dict{Symbol,Any}($(definitions...)), $(capture(only(body), names)))))
end

function branches(tree)
    isnode(tree, :+) && return reduce(vcat, branches.(tree.args))
    if isnode(tree, :*)
        result = [Any[]]
        for child in tree.args
            result = [vcat(a, b) for a in result for b in branches(child)]
        end
        return result
    end
    [Any[tree]]
end
function source(branch)
    entries = filter(x -> isnode(x, :data), branch)
    isempty(entries) ? nothing : only(last(entries).args)
end
function mappings(branch)
    positions, named = Any[], Dict{Symbol,Any}()
    for part in branch
        isnode(part, :mapping) || continue
        append!(positions, part.args)
        merge!(named, Dict(part.kwargs))
    end
    positions, named
end
function attributes(branch)
    attrs = Dict{Symbol,Any}()
    type = nothing
    for part in branch
        if isnode(part, :visual)
            type = only(part.args)
            merge!(attrs, Dict(part.kwargs))
        elseif isnode(part, :subvisual)
            only(part.args) == :prediction || error("Only :prediction is supported in this probe")
            merge!(attrs, Dict(part.kwargs))
        end
    end
    type, attrs
end
function rawgroups(branch)
    src = source(branch)
    isnode(src, :ref) && error("Derived statistics are not supported in this probe")
    columns = src !== nothing && Tables.istable(typeof(src)) ? Tables.columns(src) : nothing
    function selector(value)
        if value isa Symbol && src !== nothing
            return columns === nothing ? getproperty(src, value) : Tables.getcolumn(columns, value)
        elseif value isa Pair
            base, transformation = value
            values = selector(base)
            transformation isa AbstractString && return values
            transformation isa Function && return map(transformation, values)
            error("Unsupported selector in this probe")
        end
        value
    end
    positions, named = mappings(branch)
    length(positions) == 2 || error("This probe requires two input coordinates")
    x, y = selector.(positions)
    x isa AbstractVector && y isa AbstractVector || error("Expected vector coordinates")
    length(x) == length(y) || error("Unaligned coordinates")
    labels = Tuple(v isa Pair && last(v) isa AbstractString ? last(v) : v isa Symbol ? String(v) : "" for v in positions)
    roles = Dict(k => selector(v) for (k, v) in named if k == :group || v !== nothing)
    overridden = haskey(roles, :group)
    override = pop!(roles, :group, nothing)
    all(v -> v isa AbstractVector && length(v) == length(x), values(roles)) || error("Expected aligned categorical vectors")
    facetkeys = sort!(filter(k -> k in (:col,:row,:layout), collect(keys(roles))))
    all(k -> k in facetkeys || eltype(roles[k]) <: Union{AbstractString,Symbol}, keys(roles)) ||
        error("Continuous mapped attributes are outside this probe")
    if overridden && override !== nothing
        override isa AbstractVector && length(override) == length(x) || error("Unaligned explicit group")
        roles[:group] = override
    end
    grouping = !overridden ? sort!(collect(keys(roles))) : override === nothing ? facetkeys : vcat(facetkeys, [:group])
    categories = [Tuple(roles[k][i] for k in grouping) for i in eachindex(x)]
    _, direct = attributes(branch)
    map(unique(categories)) do category
        indices = findall(==(category), categories)
        group = Dict(k => v for (k,v) in zip(grouping, category))
        for (key, values) in roles
            key in grouping && continue
            same = unique(values[indices])
            if length(same) == 1
                group[key] = only(same)
            elseif !haskey(direct, key)
                error("Mapped $key varies within the explicit group; clear it or supply a direct attribute")
            end
        end
        ordered = sort!(collect(keys(group)))
        titles = Tuple(begin
            selection = get(named,k,nothing)
            selection isa Symbol ? String(selection) : selection isa Pair && last(selection) isa AbstractString ? last(selection) : ""
        end for k in ordered)
        (; x=x[indices], y=y[indices], group=NamedTuple{Tuple(ordered)}(Tuple(group[k] for k in ordered)),
            labels, grouplabels=NamedTuple{Tuple(ordered)}(titles))
    end
end
function fitrecords(branch, definition, calls)
    isnode(definition, :linear) || error("Only a native linear statistic is supported in this probe")
    options = Dict(definition.kwargs)
    get(options, :interval, nothing) === nothing || error("Intervals are outside this probe")
    all(k -> k in (:interval, :npoints), keys(options)) || error("Unsupported fit option")
    map(rawgroups(branch)) do row
        calls[] += 1
        model = GLM.lm(hcat(ones(length(row.x)), row.x), row.y)
        intercept, slope = GLM.coef(model)
        x = collect(range(extrema(row.x)...; length=get(options, :npoints, 31)))
        y = GLM.predict(model, hcat(ones(length(x)), x))
        (; model, x, y, slope, intercept, r2=GLM.r2(model), row.group, row.labels, row.grouplabels)
    end
end
function resolved(value, row, name)
    if isnode(value, :deferred)
        fn, refs = value.args
        all(==(name), refs) || error("Multiple result producers require an explicit alignment")
        return fn(Dict(name => row))
    elseif value isa Symbol
        return getproperty(row, value)
    elseif value isa Pair
        left, right = value
        right isa Function || error("Only column transforms are supported in this probe")
        return right(resolved(left, row, name))
    end
    value
end
asvector(x::AbstractVector) = x
asvector(x) = [x]
function drawbranch(branch, rows, name; producer=false, observations=false)
    positions, named = mappings(branch)
    type, attrs = attributes(branch)
    type === nothing && !producer && error("This probe requires an explicit visual outside a statistic")
    type === nothing && (type = Makie.Lines)
    layers = AoG.Layer[]
    for row in rows
        coordinates = producer || observations ? (row.x, row.y) : Tuple(resolved(v, row, name) for v in positions)
        group = Dict(pairs(row.group))
        # Result sources preserve categorical/facet roles, not the input positions.
        if !(producer || observations)
            for (key, value) in named
                value === nothing ? pop!(group, key, nothing) : (group[key] = resolved(value, row, name))
            end
        end
        converted = Dict(k => isnode(v, :deferred) ? resolved(v, row, name) : v for (k, v) in attrs)
        for key in keys(converted)
            pop!(group, key, nothing)  # Direct attributes override inherited aesthetic mappings.
        end
        labels = hasproperty(row, :labels) ? row.labels : ()
        arguments = [i <= length(labels) && !isempty(labels[i]) ? [asvector(v)] => labels[i] : [asvector(v)] for (i,v) in enumerate(coordinates)]
        titles = hasproperty(row,:grouplabels) ? Dict(pairs(row.grouplabels)) : Dict{Symbol,String}()
        groups = [k => (haskey(titles,k) && !isempty(titles[k]) ? [v] => titles[k] : [v]) for (k,v) in group]
        push!(layers, AoG.pregrouped(arguments...;groups...) * AoG.visual(type; converted...))
    end
    layers
end
function prepare(definitions, expression)
    parts = branches(expression)
    models = Dict{Symbol,Any}()
    producers = Dict{Symbol,Int}()
    # Find all producers before preparing any consumer. Consumer order is irrelevant.
    for (name, definition) in definitions
        occurrences = findall(branch -> any(part -> isnode(part, :ref) && only(part.args) == name, branch), parts)
        length(occurrences) == 1 || error("Statistic $name requires one producer; found $(length(occurrences))")
        producers[name] = only(occurrences)
    end
    calls = Ref(0)
    for (name, definition) in definitions
        models[name] = fitrecords(parts[producers[name]], definition, calls)
    end
    layers = AoG.Layer[]
    for (index, branch) in enumerate(parts)
        producer = findfirst(==(index), producers)
        src = source(branch)
        if producer !== nothing
            append!(layers, drawbranch(branch, models[producer], producer; producer=true))
        elseif isnode(src, :ref)
            name = only(src.args)
            append!(layers, drawbranch(branch, models[name], name))
        else
            append!(layers, drawbranch(branch, rawgroups(branch), nothing; observations=true))
        end
    end
    (; specification=reduce(+, layers), models, fit_calls=calls[])
end

struct MeasurementPayload{X,Y,G}
    x::X
    y::Y
    series::G
end

function run()
    x = repeat(collect(1.0:6.0), 2)
    y = [3.2, 4.7, 7.1, 9.1, 10.7, 13.2, 3.38, 3.16, 2.46, 1.96, 1.66, .88]
    categories = repeat(["A", "B"]; inner=6)
    # The consumer intentionally appears before the fit's producer.
    result = @plot let fit = linear(; interval=nothing)
        data(fit) * mapping(:x => last, :y => last) *
            visual(Makie.Text; text="Gain = $(round(fit.slope; digits=2))") +
        mapping(x, y; color=categories) * (visual(Makie.Scatter; markersize=6) +
            fit * subvisual(:prediction; linewidth=1 + abs(fit.slope),
                linestyle=fit.slope > 0 ? :solid : :dash))
    end
    @assert result.fit_calls == 2
    figure = AoG.draw(result.specification)
    plots = figure.grid[1, 1].axis.scene.plots
    texts = filter(p -> p isa Makie.Text, plots)
    lines = filter(p -> p isa Makie.Lines, plots)
    @assert length(texts) == length(lines) == 2
    @assert sort([only(p.text[]) for p in texts]) == ["Gain = -0.5", "Gain = 2.0"]
    @assert all(isapprox(a,b) for (a,b) in zip(sort([p.linewidth[] for p in lines]), [1.5,3.0]))
    table = (; x, y, series=categories)
    tabular = @plot let fit = linear(; interval=nothing)
        data(table) * (mapping(:x, :y; color=:series) * fit +
            data(fit) * mapping(:x => last, :y => last) * visual(Makie.Text;
                text="Gain = $(round(fit.slope; digits=2))"))
    end
    @assert tabular.fit_calls == 2
    AoG.draw(tabular.specification)
    payload = MeasurementPayload(x, y, categories)
    @assert !Tables.istable(typeof(payload))
    custom = @plot let fit = linear(; interval=nothing)
        data(payload) * (mapping(:x, :y; color=:series) * fit +
            data(fit) * mapping(:x => last, :y => last) * visual(Makie.Text;
                text="Gain = $(round(fit.slope; digits=2))"))
    end
    @assert custom.fit_calls == 2
    @assert eltype(first(custom.models[:fit]).x) == Float64
    AoG.draw(custom.specification)
    refused = false
    try
        @plot let fit = linear(; interval=nothing)
            mapping(x, y; color=categories) * (fit + fit)
        end
    catch error
        occursin("requires one producer", sprint(showerror, error)) || rethrow()
        refused = true
    end
    @assert refused
    println("let capture: forward consumer, direct width/style/text, 2 native models, vector/table/custom-property inputs passed.")
    println("Duplicate producer rejected. Result source preserved group roles without repeating color mapping.")
    println("NOT covered: full AoG syntax, missing/cyclic statistic inputs, pooling, intervals, arbitrary payload adapters or GUI source editing.")
    result
end
# Addition-only frontend. A named applied statistic retains its input context;
# named views reuse it instead of creating another producer.
function viewnames(tree)
    isnode(tree, :view) && return Symbol[only(tree.args)]
    (isnode(tree, :*) || isnode(tree, :+)) || return Symbol[]
    unique(reduce(vcat, viewnames.(tree.args); init=Symbol[]))
end
function prepareblock(definitions, layerexpressions)
    cache = Dict{Symbol,Any}()
    modeldefinitions = Dict{Symbol,Any}()
    contexts = Dict{Symbol,Any}()
    visiting = Set{Symbol}()
    function definition(name)
        haskey(cache, name) && return cache[name]
        name in visiting && error("Definition cycle at $name")
        push!(visiting, name)
        expanded = expand(definitions[name])
        alternatives = branches(expanded)
        statistics = [(branch, index) for branch in alternatives for (index, part) in enumerate(branch) if isnode(part, :linear)]
        if !isempty(statistics)
            length(statistics) == length(alternatives) == 1 || error("Name each applied statistic separately")
            branch, index = only(statistics)
            positions, _ = mappings(branch)
            # A constructor without inputs remains a reusable fragment.
            if !isempty(positions)
                modeldefinitions[name] = branch[index]
                contexts[name] = branch
                styles = filter(p -> isnode(p, :visual) || isnode(p, :subvisual), branch)
                expanded = node(:*, (node(:view, (name,)), styles...))
            end
        end
        delete!(visiting, name)
        cache[name] = expanded
        expanded
    end
    function expand(tree)
        isnode(tree, :ref) && return definition(only(tree.args))
        if isnode(tree, :data)
            argument = only(tree.args)
            if isnode(argument, :ref)
                name = only(argument.args)
                origins = viewnames(definition(name))
                length(origins) == 1 || error("data($name) needs one named applied statistic")
                return node(:data, (node(:ref, (only(origins),)),))
            end
        elseif isnode(tree, :*) || isnode(tree, :+)
            return node(tree.kind, Tuple(expand.(tree.args)))
        end
        tree
    end
    rendered = reduce(vcat, branches.(expand.(layerexpressions)))
    anonymous = Set{Symbol}()
    # Anonymous complete fit layers work too; naming is needed only for reuse/results.
    for branch in rendered
        for (index, part) in enumerate(branch)
            isnode(part, :linear) || continue
            name = gensym(:anonymous_fit)
            push!(anonymous, name)
            modeldefinitions[name] = part
            contexts[name] = copy(branch)
            branch[index] = node(:view, (name,))
        end
    end
    calls = Ref(0)
    models = Dict(name => fitrecords(contexts[name], spec, calls) for (name, spec) in modeldefinitions)
    layers = AoG.Layer[]
    for branch in rendered
        origins = unique([only(p.args) for p in branch if isnode(p, :view)])
        src = source(branch)
        if length(origins) == 1
            (only(origins) in anonymous || (src === nothing && isempty(first(mappings(branch))))) ||
                error("A bound fit keeps its inputs; use data(fit) to remap its output")
            name = only(origins)
            append!(layers, drawbranch(branch, models[name], name; producer=true))
        elseif !isempty(origins)
            error("Multiple bound statistics need an explicit alignment")
        elseif isnode(src, :ref)
            name = only(src.args)
            append!(layers, drawbranch(branch, models[name], name))
        else
            append!(layers, drawbranch(branch, rawgroups(branch), nothing; observations=true))
        end
    end
    (; specification=reduce(+, layers), models, fit_calls=calls[])
end

function runaddition()
    x = repeat(collect(1.0:6.0), 2)
    y = [3.2, 4.7, 7.1, 9.1, 10.7, 13.2, 3.38, 3.16, 2.46, 1.96, 1.66, .88]
    categories = repeat(["A", "B"]; inner=6)
    payload = MeasurementPayload(x, y, categories)
    result = @plot begin
        # Definitions and consumers deliberately precede the shared input definition.
        fit = xy * linear(; interval=nothing)
        data(fit) * mapping(:x => last, :y => last) *
            visual(Makie.Text; text="Gain = $(round(fit.slope; digits=2))")
        xy * visual(Makie.Scatter; markersize=6)
        fit * subvisual(:prediction; linewidth=1 + abs(fit.slope))
        fit * subvisual(:prediction; linewidth=1, linestyle=:dash)
        xy = data(payload) * mapping(:x, :y; color=:series)
    end
    @assert result.fit_calls == 2
    figure = AoG.draw(result.specification)
    @assert count(p -> p isa Makie.Lines, figure.grid[1,1].axis.scene.plots) == 4
    resultonly = @plot begin
        data(fit) * mapping(:x => last, :y => last) *
            visual(Makie.Text; text="Gain = $(round(fit.slope; digits=2))")
        fit = data(payload) * mapping(:x, :y; color=:series) * linear(; interval=nothing)
    end
    @assert resultonly.fit_calls == 2
    output = AoG.draw(resultonly.specification)
    @assert all(p -> !(p isa Makie.Lines), output.grid[1,1].axis.scene.plots)
    anonymous = @plot begin
        data(payload) * mapping(:x, :y; color=:series) * linear(; interval=nothing)
    end
    @assert anonymous.fit_calls == 2
    AoG.draw(anonymous.specification)
    rejected = false
    try
        @plot begin
            a = b
            b = a
            a
        end
    catch error
        occursin("Definition cycle", sprint(showerror,error)) || rethrow()
        rejected = true
    end
    @assert rejected
    println("Addition-only capture passed: forward fragment definitions, non-table payload, two styled views sharing two models.")
    println("Result-only plot draws no fitted line; anonymous fit needs no name; cyclic definitions rejected.")
    println("NOT a full grammar: pooling, intervals, custom statistics, source editing and general AoG syntax remain outside this probe.")
    result
end

function captureheader(shared, block)
    block isa Expr && block.head == :block || error("Expected a layer block")
    lines = filter(x -> !(x isa LineNumberNode), block.args)
    bindings = filter(x -> x isa Expr && x.head == :(=), lines)
    names = [b.args[1] for b in bindings]
    all(x -> x isa Symbol, names) || error("Expected layer names")
    length(unique(names)) == length(names) || error("Duplicate layer name")
    definitions = [:($(QuoteNode(b.args[1])) => $(capture(b.args[2], names))) for b in bindings]
    layers = [x isa Expr && x.head == :(=) ? :($(GlobalRef(@__MODULE__, :node))(:ref, ($(QuoteNode(x.args[1])),))) : capture(x, names) for x in lines]
    :($(GlobalRef(@__MODULE__, :prepareheader))($(capture(shared, names)), Dict{Symbol,Any}($(definitions...)), Any[$(layers...)]))
end
"""Probe the accepted single-panel header and per-line layer syntax."""
macro plot(shared, block)
    esc(captureheader(shared, block))
end
function prepareheader(shared, definitions, lines)
    defaults = only(branches(shared))
    all(p -> isnode(p,:data) || isnode(p,:mapping), defaults) || error("Shared defaults support data and mapping in this probe")
    defaultsource = source(defaults)
    defaultpositions, defaultnamed = mappings(defaults)
    function inherit(tree)
        alternatives = map(branches(tree)) do branch
            # A named line already owns its resolved input context.
            any(p -> isnode(p,:ref), branch) && return node(:*,Tuple(branch))
            localpositions, localnamed = mappings(branch)
            localsource = source(branch)
            resultnames = unique(reduce(vcat, [p.args[2] for p in localpositions if isnode(p,:deferred)]; init=Symbol[]))
            length(resultnames) <= 1 || error("Multiple result domains need explicit alignment")
            if !isempty(resultnames)
                localsource = node(:ref,(only(resultnames),))
            end
            resultdomain = isnode(localsource,:ref)
            positions = isempty(localpositions) ? (resultdomain ? Any[] : defaultpositions) : localpositions
            resultdomain && isempty(positions) && error("Set result coordinates explicitly in this probe")
            named = resultdomain ? copy(localnamed) : merge(defaultnamed,localnamed)
            selectedsource = localsource === nothing ? defaultsource : localsource
            parts = Any[]
            selectedsource === nothing || push!(parts,node(:data,(selectedsource,)))
            push!(parts,node(:mapping,Tuple(positions),collect(pairs(named))))
            append!(parts,filter(p -> !isnode(p,:data) && !isnode(p,:mapping),branch))
            node(:*,Tuple(parts))
        end
        length(alternatives) == 1 ? only(alternatives) : node(:+,Tuple(alternatives))
    end
    prepared = prepareblock(Dict(name=>inherit(tree) for (name,tree) in definitions),inherit.(lines))
    prepared
end
function runheader()
    x = repeat(collect(1.0:6.0), 2)
    y = [3.2,4.7,7.1,9.1,10.7,13.2,3.38,3.16,2.46,1.96,1.66,.88]
    categories = repeat(["A","B"];inner=6)
    payload = MeasurementPayload(x,y,categories)
    generic = @plot data(payload) * mapping(:x,:y;color=:series) begin
        visual(Makie.Scatter;markersize=6)
        fit = linear(;interval=nothing) * subvisual(:prediction;linewidth=1+abs(fit.slope))
        mapping(fit.x[end],fit.y[end]) * visual(Makie.Text;
            text="Gain = $(round(fit.slope;digits=2))",offset=(8,0),align=(:left,:center))
    end
    @assert generic.fit_calls == 2
    genericfigure = AoG.draw(generic.specification)
    @assert count(p -> p isa Makie.Lines,genericfigure.grid[1,1].axis.scene.plots) == 2
    @assert count(p -> p isa Makie.Text,genericfigure.grid[1,1].axis.scene.plots) == 2
    tlm_y = [8.2,9.7,12.1,14.1,15.7,18.2,13.8,14.8,19.4,22.4,23.8,28.8]
    table = (; gap_um=vcat(x,x),R_ohm=vcat(tlm_y,tlm_y.+2),chip=vcat(categories,categories),site=repeat(["site 1","site 2"];inner=12))
    tlm = @plot data(table) * mapping(:gap_um=>"gap (µm)",:R_ohm=>"R (Ω)";color=:chip,col=:site) begin
        visual(Makie.Scatter;markersize=6)
        fit = linear(;interval=nothing) * subvisual(:prediction;linewidth=2,linestyle=fit.r2<.99 ? :dash : :solid)
        mapping(fit.x[end],fit.y[end]) * visual(Makie.Text;
            text="R_c = $(round(fit.intercept/2;digits=1)) Ω",offset=(8,0),align=(:left,:center))
        mapping(0,fit.intercept) * visual(Makie.Scatter;marker=:xcross,markersize=12)
        mapping(;group=nothing,color=nothing) * linear(;interval=nothing) *
            subvisual(:prediction;color=:gray,linestyle=:dot)
    end
    @assert tlm.fit_calls == 6  # four chip/site fits and two pooled/site fits
    tlmfigure = AoG.draw(tlm.specification)
    @assert size(tlmfigure.grid) == (1,2)
    for panel in tlmfigure.grid
        @assert count(p -> p isa Makie.Lines,panel.axis.scene.plots) == 3
        @assert count(p -> p isa Makie.Text,panel.axis.scene.plots) == 2
    end
    println("Accepted header capture passed: custom payload, named fit draws, direct result attributes and endpoint annotations.")
    println("Synthetic two-facet case: 4 chip fits + 2 pooled fits, with result labels and intercept markers; facet identity preserved.")
    println("NOT covered: full AoG schemas, custom statistics, intervals, cross-fit joins, live invalidation or GUI/source roundtrip.")
    (;generic,tlm,genericfigure,tlmfigure)
end

end
