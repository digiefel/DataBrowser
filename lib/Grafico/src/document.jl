using Tables: Tables

"""
    EntryValue

Parsed expression text and literal flag for an editable property in a [`PlotDocument`](@ref).
"""
struct EntryValue
    expr_text::String
    is_literal::Bool
end

"""
    MappingEntry

Single role binding inside a `mapping(...)` call of a [`PlotDocument`](@ref).
"""
struct MappingEntry
    role::Symbol
    value_expr::String
    label::Union{Nothing,String}
    transform_expr::Union{Nothing,String}
end

"""
    LayerSpec

Editable layer entry inside a [`PlotDocument`](@ref).
"""
mutable struct LayerSpec
    id::Int
    name::Union{Nothing,Symbol}
    visible::Bool
    data_expr::Union{Nothing,String}
    mapping::Vector{MappingEntry}
    analysis_expr::Union{Nothing,String}
    plottype_expr::String
    visual_kwargs::Dict{Symbol,EntryValue}
    is_statement_only::Bool
end

"""
    ThemeSpec

Theme selection and per-block overrides inside a [`PlotDocument`](@ref).
"""
mutable struct ThemeSpec
    base::Union{Nothing,Symbol}
    settings::Dict{Symbol,EntryValue}
end

"""
    PlotDocument

Structured editable representation of a `@plot` specification.
"""
mutable struct PlotDocument
    header_data_expr::Union{Nothing,String}
    header_mapping::Vector{MappingEntry}
    header_analysis_expr::Union{Nothing,String}
    header_plottype_expr::String
    header_visual_kwargs::Dict{Symbol,EntryValue}
    layers::Vector{LayerSpec}
    scales::Dict{Symbol,Dict{Symbol,EntryValue}}
    coords::Vector{Dict{Symbol,Any}}
    legend::Dict{Symbol,EntryValue}
    theme::Union{Nothing,ThemeSpec}
    inspector::Union{Nothing,InspectorSpec}
    has_block::Bool
    eval_module::Module
    next_layer_id::Int
end

function Base.deepcopy_internal(doc::PlotDocument, stackdict::IdDict)
    haskey(stackdict, doc) && return stackdict[doc]
    copy = PlotDocument(
        doc.header_data_expr,
        Base.deepcopy_internal(doc.header_mapping, stackdict),
        doc.header_analysis_expr,
        doc.header_plottype_expr,
        Base.deepcopy_internal(doc.header_visual_kwargs, stackdict),
        Base.deepcopy_internal(doc.layers, stackdict),
        Base.deepcopy_internal(doc.scales, stackdict),
        Base.deepcopy_internal(doc.coords, stackdict),
        Base.deepcopy_internal(doc.legend, stackdict),
        doc.theme === nothing ? nothing : Base.deepcopy_internal(doc.theme, stackdict),
        doc.inspector === nothing ? nothing : Base.deepcopy_internal(doc.inspector, stackdict),
        doc.has_block,
        doc.eval_module,
        doc.next_layer_id,
    )
    stackdict[doc] = copy
    return copy
end

_is_literal_expr(e) = e isa Number || e isa Bool || e isa AbstractString || e isa Symbol ||
    (e isa QuoteNode && e.value isa Symbol) || e === nothing ||
    (Meta.isexpr(e, :tuple) && all(_is_literal_expr, e.args)) ||
    (Meta.isexpr(e, :vect) && all(_is_literal_expr, e.args))

function _strip_lines(e)
    e isa Expr || return e
    if e.head === :block
        args = [_strip_lines(a) for a in e.args if !(a isa LineNumberNode)]
        return Expr(:block, args...)
    end
    return Expr(e.head, map(_strip_lines, e.args)...)
end

function _format_kw_pairs(items)
    parts = String[]
    for item in items
        if Meta.isexpr(item, :kw, 2)
            push!(parts, "$(item.args[1]) = $(_expr_to_string(item.args[2]))")
        elseif Meta.isexpr(item, :(=), 2)
            push!(parts, "$(item.args[1]) = $(_expr_to_string(item.args[2]))")
        end
    end
    return parts
end

function _expr_to_string(e)::String
    e === nothing && return "nothing"
    e isa Bool && return e ? "true" : "false"
    e isa QuoteNode && return e.value isa Symbol ? ":$(e.value)" : repr(e.value)
    e isa Symbol && return string(e)
    e isa AbstractString && return repr(String(e))
    e isa Number && return repr(e)
    e isa Expr || return repr(e)
    cleaned = _strip_lines(e)
    if Meta.isexpr(cleaned, :call)
        fn = cleaned.args[1]
        pos = String[]
        kws = String[]
        for a in cleaned.args[2:end]
            if Meta.isexpr(a, :parameters)
                append!(kws, _format_kw_pairs(a.args))
            elseif Meta.isexpr(a, :kw, 2)
                push!(kws, "$(a.args[1]) = $(_expr_to_string(a.args[2]))")
            else
                push!(pos, _expr_to_string(a))
            end
        end
        if fn === :(=>) && length(pos) == 2 && isempty(kws)
            return "$(pos[1]) => $(pos[2])"
        elseif isempty(kws)
            return "$(_expr_to_string(fn))($(join(pos, ", ")))"
        elseif isempty(pos)
            return "$(_expr_to_string(fn))($(join(kws, ", ")))"
        else
            return "$(_expr_to_string(fn))($(join(pos, ", ")); $(join(kws, ", ")))"
        end
    elseif Meta.isexpr(cleaned, :tuple)
        pos = String[]
        kws = String[]
        for a in cleaned.args
            if Meta.isexpr(a, :parameters)
                append!(kws, _format_kw_pairs(a.args))
            elseif Meta.isexpr(a, :kw, 2) || Meta.isexpr(a, :(=), 2)
                push!(kws, "$(a.args[1]) = $(_expr_to_string(a.args[2]))")
            else
                push!(pos, _expr_to_string(a))
            end
        end
        if !isempty(kws) && isempty(pos)
            return "(; $(join(kws, ", ")))"
        elseif length(pos) == 1 && isempty(kws)
            return "($(pos[1]),)"
        else
            return "($(join(pos, ", ")))"
        end
    elseif Meta.isexpr(cleaned, :vect)
        return "[$(join(_expr_to_string.(cleaned.args), ", "))]"
    elseif Meta.isexpr(cleaned, :., 2) && cleaned.args[2] isa QuoteNode
        return "$(_expr_to_string(cleaned.args[1])).$(cleaned.args[2].value)"
    elseif Meta.isexpr(cleaned, :macrocall) && cleaned.args[1] === Symbol("@invisible")
        inner = cleaned.args[end]
        return "@invisible $(_expr_to_string(inner))"
    end
    return string(cleaned)
end

const _MAKIE_PLOTTYPE_NAMES = IdDict{Type,String}()

function _plottype_name(T::Type)::String
    if isempty(_MAKIE_PLOTTYPE_NAMES)
        for nm in names(Makie)
            isdefined(Makie, nm) || continue
            val = getfield(Makie, nm)
            if val isa Type && val <: Makie.Plot && val !== Makie.Plot
                get!(_MAKIE_PLOTTYPE_NAMES, val, String(nm))
            end
        end
    end
    haskey(_MAKIE_PLOTTYPE_NAMES, T) && return _MAKIE_PLOTTYPE_NAMES[T]
    return T <: Makie.Plot ? string(T) : string(nameof(T))
end

_make_entry_value(e) = EntryValue(_expr_to_string(e), _is_literal_expr(e))
function _entry_value_from_runtime(v)::EntryValue
    if v === nothing
        return EntryValue("nothing", true)
    elseif v isa Symbol
        return EntryValue(":$v", true)
    elseif v isa AbstractString
        return EntryValue(repr(String(v)), true)
    elseif v isa Bool || v isa Number
        return EntryValue(repr(v), true)
    elseif v isa Tuple
        parts = [_entry_value_from_runtime(x).expr_text for x in v]
        text = length(parts) == 1 ? "($(parts[1]),)" : "($(join(parts, ", ")))"
        return EntryValue(text, all(x -> _entry_value_from_runtime(x).is_literal, v))
    elseif v isa AbstractVector
        parts = [_entry_value_from_runtime(x).expr_text for x in v]
        return EntryValue("[$(join(parts, ", "))]", true)
    elseif v isa NamedTuple
        parts = ["$k = $(_entry_value_from_runtime(val).expr_text)" for (k, val) in pairs(v)]
        return EntryValue("(; $(join(parts, ", ")))", false)
    elseif v isa Makie.Plot
        return EntryValue(_plottype_name(typeof(v)), false)
    elseif v isa Type
        return EntryValue(_plottype_name(v), false)
    elseif v isa Function
        return EntryValue(string(nameof(v)), false)
    else
        return EntryValue(repr(v), false)
    end
end

function _unpack_mapping_value(e)
    if Meta.isexpr(e, :call) && e.args[1] === :(=>) && length(e.args) >= 3
        lhs, rhs = e.args[2], e.args[3]
        if rhs isa AbstractString
            inner_val, _, inner_tf = _unpack_mapping_value(lhs)
            return inner_val, String(rhs), inner_tf
        elseif Meta.isexpr(rhs, :call) && rhs.args[1] === :(=>) && length(rhs.args) >= 3 && rhs.args[3] isa AbstractString
            return _expr_to_string(lhs), String(rhs.args[3]), _expr_to_string(rhs.args[2])
        else
            return _expr_to_string(lhs), nothing, _expr_to_string(rhs)
        end
    end
    return _expr_to_string(e), nothing, nothing
end

function _parse_mapping_call(call_expr)::Vector{MappingEntry}
    positional, named = call_arguments(call_expr)
    entries = MappingEntry[]
    pos_roles = (:x, :y, :z)
    for (idx, val) in enumerate(positional)
        role = idx <= length(pos_roles) ? pos_roles[idx] : Symbol("pos", idx)
        val_str, lbl, tf = _unpack_mapping_value(val)
        push!(entries, MappingEntry(role, val_str, lbl, tf))
    end
    for (role, val) in named
        val_str, lbl, tf = _unpack_mapping_value(val)
        push!(entries, MappingEntry(role, val_str, lbl, tf))
    end
    return entries
end

function _flatten_mul(e)
    if Meta.isexpr(e, :call) && e.args[1] === :(*)
        terms = Any[]
        for arg in e.args[2:end]
            append!(terms, _flatten_mul(arg))
        end
        return terms
    end
    return Any[e]
end

function _parse_layer_terms(expr)
    data_expr = nothing
    mapping_entries = MappingEntry[]
    analysis_terms = String[]
    plottype_expr = ""
    visual_kwargs = Dict{Symbol,EntryValue}()
    for term in _flatten_mul(_strip_lines(expr))
        if Meta.isexpr(term, :call) && term.args[1] === :data && length(term.args) >= 2
            data_expr = _expr_to_string(term.args[2])
        elseif Meta.isexpr(term, :call) && term.args[1] === :mapping
            append!(mapping_entries, _parse_mapping_call(term))
        elseif Meta.isexpr(term, :call) && term.args[1] === :visual
            pos, named = call_arguments(term)
            if !isempty(pos)
                plottype_expr = _expr_to_string(pos[1])
            end
            for (k, v) in named
                visual_kwargs[k] = _make_entry_value(v)
            end
        elseif term !== :nothing && term !== false
            push!(analysis_terms, _expr_to_string(term))
        end
    end
    analysis_expr = isempty(analysis_terms) ? nothing : join(analysis_terms, " * ")
    return data_expr, mapping_entries, analysis_expr, plottype_expr, visual_kwargs
end

function _qualify_expr(e, eval_module::Module)
    if e isa Symbol
        isdefined(eval_module, e) && return e
        isdefined(@__MODULE__, e) && return GlobalRef(@__MODULE__, e)
        isdefined(Makie, e) && return GlobalRef(Makie, e)
        return e
    elseif e isa Expr
        if e.head in (:quote, :inert)
            return e
        elseif e.head === :. && length(e.args) == 2 && e.args[2] isa QuoteNode
            return Expr(:., _qualify_expr(e.args[1], eval_module), e.args[2])
        elseif e.head === :kw && length(e.args) == 2
            return Expr(:kw, e.args[1], _qualify_expr(e.args[2], eval_module))
        elseif e.head === :(=) && length(e.args) == 2 && e.args[1] isa Symbol
            return Expr(:(=), e.args[1], _qualify_expr(e.args[2], eval_module))
        elseif e.head === :(->) && length(e.args) == 2
            return e
        else
            return Expr(e.head, map(a -> _qualify_expr(a, eval_module), e.args)...)
        end
    end
    return e
end

function _eval_in_module(eval_module::Module, expr)
    qualified = _qualify_expr(expr, eval_module)
    return Base.invokelatest(Core.eval, eval_module, qualified)
end

function _eval_text(eval_module::Module, text::AbstractString)
    parsed = Meta.parse(text)
    return _eval_in_module(eval_module, parsed)
end

_eval_entry_value(doc::PlotDocument, ev::EntryValue) = _eval_text(doc.eval_module, ev.expr_text)

function _parse_inspector_expr(expr, eval_module::Module)::InspectorSpec
    pos, named = call_arguments(expr)
    kw_pairs = Pair{Symbol,Any}[]
    for (k, v) in named
        push!(kw_pairs, k => _eval_in_module(eval_module, v))
    end
    if length(pos) == 1 && pos[1] isa Bool && isempty(kw_pairs)
        return inspector(pos[1])
    end
    pos_vals = [_eval_in_module(eval_module, p) for p in pos]
    if length(pos_vals) == 1 && pos_vals[1] isa Function && isempty(kw_pairs)
        return inspector(pos_vals[1])
    end
    return inspector(pos_vals...; kw_pairs...)
end

function _parse_scale_value(expr)
    cleaned = _strip_lines(expr)
    if Meta.isexpr(cleaned, :tuple)
        out = Dict{Symbol,EntryValue}()
        for item in cleaned.args
            if Meta.isexpr(item, :parameters)
                for p in item.args
                    (Meta.isexpr(p, :kw, 2) || Meta.isexpr(p, :(=), 2)) &&
                        (out[p.args[1]] = _make_entry_value(p.args[2]))
                end
            elseif Meta.isexpr(item, :kw, 2) || Meta.isexpr(item, :(=), 2)
                out[item.args[1]] = _make_entry_value(item.args[2])
            end
        end
        isempty(out) || return out
    end
    return Dict{Symbol,EntryValue}(:value => _make_entry_value(cleaned))
end

"""
    parse_plot_document(header_expr, block_expr=nothing; eval_module=Main) -> PlotDocument

Parse raw `@plot` AST expressions into a [`PlotDocument`](@ref).
"""
function parse_plot_document(
    header_expr,
    block_expr=nothing;
    eval_module::Module=Main,
    existing_inspector::Union{Nothing,InspectorSpec}=nothing,
)::PlotDocument
    data_expr, mapping_entries, analysis_expr, plottype_expr, visual_kwargs = _parse_layer_terms(header_expr)
    doc = PlotDocument(
        data_expr,
        mapping_entries,
        analysis_expr,
        plottype_expr,
        visual_kwargs,
        LayerSpec[],
        Dict{Symbol,Dict{Symbol,EntryValue}}(),
        Dict{Symbol,Any}[],
        Dict{Symbol,EntryValue}(),
        nothing,
        nothing,
        block_expr !== nothing,
        eval_module,
        1,
    )
    block_expr === nothing && return doc
    Meta.isexpr(block_expr, :block) || error("Expected a `begin ... end` block for @plot document")
    for raw_line in block_expr.args
        raw_line isa LineNumberNode && continue
        hidden = Meta.isexpr(raw_line, :macrocall) && raw_line.args[1] === Symbol("@invisible")
        line = hidden ? raw_line.args[end] : raw_line
        if Meta.isexpr(line, :(=), 2) && line.args[1] isa Symbol
            d, m, a, pt, vk = _parse_layer_terms(line.args[2])
            id = doc.next_layer_id
            doc.next_layer_id += 1
            push!(doc.layers, LayerSpec(id, line.args[1], !hidden, d, m, a, pt, vk, true))
        elseif Meta.isexpr(line, :call) && line.args[1] === :scales
            _, named = call_arguments(line)
            for (role, val) in named
                doc.scales[role] = _parse_scale_value(val)
            end
        elseif Meta.isexpr(line, :call) && line.args[1] === :coord
            pos, named = call_arguments(line)
            step = Dict{Symbol,Any}()
            isempty(pos) || (step[:points] = _make_entry_value(only(pos)))
            for (k, v) in named
                if k in (:x, :y)
                    step[k] = _parse_scale_value(v)
                else
                    step[k] = _make_entry_value(v)
                end
            end
            push!(doc.coords, step)
        elseif Meta.isexpr(line, :call) && line.args[1] === :legend
            _, named = call_arguments(line)
            for (k, v) in named
                doc.legend[k] = _make_entry_value(v)
            end
        elseif Meta.isexpr(line, :call) && line.args[1] in (:theme, :plot_theme)
            pos, named = call_arguments(line)
            base = isempty(pos) ? nothing : _eval_in_module(eval_module, only(pos))
            settings = Dict{Symbol,EntryValue}(k => _make_entry_value(v) for (k, v) in named)
            doc.theme = ThemeSpec(base, settings)
        elseif Meta.isexpr(line, :call) && line.args[1] === :inspector
            doc.inspector = existing_inspector !== nothing ? existing_inspector : _parse_inspector_expr(line, eval_module)
        else
            d, m, a, pt, vk = _parse_layer_terms(line)
            id = doc.next_layer_id
            doc.next_layer_id += 1
            visible = !hidden && line !== :nothing && line !== false
            push!(doc.layers, LayerSpec(id, nothing, visible, d, m, a, pt, vk, false))
        end
    end
    return doc
end

"""
    parse_plot_code(code::AbstractString; eval_module=Main) -> PlotDocument

Parse a `@plot ...` source string into a [`PlotDocument`](@ref).
"""
function parse_plot_code(code::AbstractString; eval_module::Module=Main)::PlotDocument
    parsed = _strip_lines(Meta.parse(code))
    if Meta.isexpr(parsed, :block)
        non_empty = [a for a in parsed.args if !(a isa LineNumberNode)]
        length(non_empty) == 1 || error("Expected a single @plot expression")
        parsed = non_empty[1]
    end
    Meta.isexpr(parsed, :macrocall) || error("Expected a @plot macro call")
    mname = parsed.args[1]
    ok = mname === Symbol("@plot") || (mname isa GlobalRef && mname.name === Symbol("@plot")) ||
         (Meta.isexpr(mname, :., 2) && mname.args[2] == QuoteNode(Symbol("@plot")))
    ok || error("Expected @plot, got $mname")
    args = [a for a in parsed.args[2:end] if !(a isa LineNumberNode)]
    if length(args) == 1
        return parse_plot_document(args[1], nothing; eval_module)
    elseif length(args) == 2
        return parse_plot_document(args[1], args[2]; eval_module)
    else
        error("Expected `@plot header` or `@plot header begin ... end`")
    end
end

_build_plot_document(header_expr, block_expr, eval_module::Module, existing_inspector=nothing) =
    parse_plot_document(header_expr, block_expr; eval_module, existing_inspector)

"""
    EditablePlot

Mutable, `Observable`-backed plot wrapper created by [`editable`](@ref). Visual and coordinate
edits update existing Makie objects in place without recompiling data or analyses.
"""
mutable struct EditablePlot <: AbstractEditablePlot
    doc::PlotDocument
    data::Makie.Observable{Any}
    compiled::Makie.Observable{Any}
    visual_obs::Dict{Int,Dict{Symbol,Makie.Observable{Any}}}
    coord_obs::Dict{Symbol,Makie.Observable{Any}}
    base_plot::Any
    initial_data::Any
    structure_dirty::Bool
    revision::Int
    updating::Bool
end

function _document_from_runtime(plot::Layer)::PlotDocument
    vk = Dict{Symbol,EntryValue}()
    pt = ""
    if plot.transformation isa Visual
        pt = _plottype_name(plot.transformation.plottype)
        for (k, v) in pairs(plot.transformation.attributes)
            vk[k] = _entry_value_from_runtime(v)
        end
    end
    mappings = MappingEntry[]
    pos_roles = (:x, :y, :z)
    for (idx, v) in enumerate(plot.positional)
        idx <= 3 && push!(mappings, MappingEntry(pos_roles[idx], _entry_value_from_runtime(v).expr_text, nothing, nothing))
    end
    for (k, v) in pairs(plot.named)
        push!(mappings, MappingEntry(k, _entry_value_from_runtime(v).expr_text, nothing, nothing))
    end
    return PlotDocument(
        plot.data === nothing ? nothing : "data",
        mappings,
        nothing,
        pt,
        vk,
        LayerSpec[],
        Dict{Symbol,Dict{Symbol,EntryValue}}(),
        Dict{Symbol,Any}[],
        Dict{Symbol,EntryValue}(),
        nothing,
        nothing,
        false,
        Main,
        1,
    )
end

function _document_from_runtime(plot::Scaled)::PlotDocument
    base_doc = plot.layers isa Layer ? _document_from_runtime(plot.layers) :
               PlotDocument(nothing, MappingEntry[], nothing, "", Dict{Symbol,EntryValue}(),
                   LayerSpec[], Dict{Symbol,Dict{Symbol,EntryValue}}(), Dict{Symbol,Any}[],
                   Dict{Symbol,EntryValue}(), nothing, plot.inspector, plot.layers isa PlotLines, Main, 1)
    base_doc.inspector = plot.inspector
    if plot.theme !== nothing
        settings = Dict{Symbol,EntryValue}(k => _entry_value_from_runtime(v) for (k, v) in pairs(plot.theme.settings))
        base_doc.theme = ThemeSpec(plot.theme.base, settings)
    end
    for (k, v) in pairs(plot.legend)
        base_doc.legend[k] = _entry_value_from_runtime(v)
    end
    return base_doc
end

"""
    document(x) -> PlotDocument

Return the [`PlotDocument`](@ref) associated with `x` (a plot, [`EditablePlot`](@ref),
or `Figure`).
"""
document(doc::PlotDocument) = doc
document(ep::EditablePlot) = ep.doc
document(x::Makie.Observable) = document(x[])

function document(x::Union{Declaration,PlotLines,Scaled})
    x.document !== nothing && return x.document
    x isa Scaled && return _document_from_runtime(x)
    error("No editable PlotDocument is attached to this $(typeof(x)); construct it with `@plot`")
end

document(x::Layer) = _document_from_runtime(x)
function document(x::Layers)
    doc = PlotDocument(nothing, MappingEntry[], nothing, "", Dict{Symbol,EntryValue}(),
        LayerSpec[], Dict{Symbol,Dict{Symbol,EntryValue}}(), Dict{Symbol,Any}[],
        Dict{Symbol,EntryValue}(), nothing, nothing, true, Main, 1)
    for (idx, layer) in enumerate(x.layers)
        ldoc = _document_from_runtime(layer)
        push!(doc.layers, LayerSpec(idx, nothing, true, ldoc.header_data_expr, ldoc.header_mapping,
            ldoc.header_analysis_expr, ldoc.header_plottype_expr, ldoc.header_visual_kwargs, false))
        doc.next_layer_id = idx + 1
    end
    return doc
end

function document(fig::Makie.Figure)
    if haskey(fig.attributes, :_grafico_editable)
        ep = fig.attributes[:_grafico_editable][]
        ep isa EditablePlot && return ep.doc
    end
    if haskey(fig.attributes, :_grafico_compilation)
        compiled = fig.attributes[:_grafico_compilation][]
        decl = compiled.declaration
        src = decl isa Makie.Observable ? decl[] : decl
        return document(src)
    end
    error("Figure was not created from a Grafico `@plot` or `EditablePlot`")
end

"""
    editable_plot(fig::Makie.Figure) -> Union{Nothing,EditablePlot}

Return the [`EditablePlot`](@ref) attached to `fig`, or `nothing`.
"""
function editable_plot(fig::Makie.Figure)
    haskey(fig.attributes, :_grafico_editable) || return nothing
    ep = fig.attributes[:_grafico_editable][]
    return ep isa EditablePlot ? ep : nothing
end

const _SEMANTIC_VISUAL_KEYS = (:direction, :orientation)

function _ensure_visual_obs!(ep::EditablePlot, layer_id::Int, kwargs_dict::Dict{Symbol,EntryValue})
    obs_map = get!(Dict{Symbol,Makie.Observable{Any}}, ep.visual_obs, layer_id)
    pairs_out = Pair{Symbol,Any}[]
    for k in sort!(collect(keys(kwargs_dict)))
        ev = kwargs_dict[k]
        val = _eval_entry_value(ep.doc, ev)
        if k in _SEMANTIC_VISUAL_KEYS
            push!(pairs_out, k => val)
        else
            obs = get!(obs_map, k) do
                Makie.Observable{Any}(val)
            end
            obs.val = val
            push!(pairs_out, k => obs)
        end
    end
    return pairs_out
end

function _ensure_coord_obs!(ep::EditablePlot)
    obs = ep.coord_obs
    for step in ep.doc.coords
        for (k, v) in step
            k === :points && continue
            if k in (:x, :y) && v isa Dict{Symbol,EntryValue}
                for (subk, ev) in v
                    ckey = Symbol(k, subk)
                    val = _eval_entry_value(ep.doc, ev)
                    if haskey(obs, ckey)
                        obs[ckey].val = val
                    else
                        obs[ckey] = Makie.Observable{Any}(val)
                    end
                end
            elseif v isa EntryValue
                val = _eval_entry_value(ep.doc, v)
                if haskey(obs, k)
                    obs[k].val = val
                else
                    obs[k] = Makie.Observable{Any}(val)
                end
            end
        end
    end
    return obs
end

function _resolve_plottype(doc::PlotDocument, pt_expr::AbstractString)
    isempty(pt_expr) && return nothing
    return _eval_text(doc.eval_module, pt_expr)
end

function _patch_transform(t, pt, attrs)
    if t isa Visual
        new_pt = pt === nothing ? t.plottype : pt
        return Visual(new_pt, attrs, t.target)
    elseif t isa ComposedFunction
        if t.outer isa Visual || t.outer isa ComposedFunction
            new_outer = _patch_transform(t.outer, pt, attrs)
            new_outer !== t.outer && return ComposedFunction(new_outer, t.inner)
        end
        new_inner = _patch_transform(t.inner, pt, attrs)
        new_inner !== t.inner && return ComposedFunction(t.outer, new_inner)
        return t
    else
        return t
    end
end

function _patch_layer_visual(layer::Layer, pt, obs_pairs)
    t = layer.transformation
    attrs = Dictionary{Symbol,Any}()
    for (k, v) in obs_pairs
        insert!(attrs, k, v)
    end
    patched_t = _patch_transform(t, pt, attrs)
    new_t = if patched_t !== t
        patched_t
    elseif pt !== nothing || !isempty(attrs)
        new_pt = pt === nothing ? Makie.Plot{Makie.plot} : pt
        v = Visual(new_pt, attrs, nothing)
        t === identity ? v : (v ∘ t)
    else
        t
    end
    return Layer(; transformation=new_t, data=layer.data, positional=layer.positional, named=layer.named)
end

function _patch_layer_visual(layers::Layers, pt, obs_pairs)
    isempty(layers.layers) && return layers
    patched = [_patch_layer_visual(l, pt, obs_pairs) for l in layers.layers]
    return Layers(patched)
end

function _patch_layer_visual(ys::YScaleLayers, pt, obs_pairs)
    return YScaleLayers([role => _patch_layer_visual(l, pt, obs_pairs) for (role, l) in ys.layers])
end

function _patch_layer_visual(x, pt, obs_pairs)
    if pt === nothing && isempty(obs_pairs)
        return x
    end
    resolved = resolve(x, nothing, (;))
    if resolved isa Layer || resolved isa Layers
        return _patch_layer_visual(resolved, pt, obs_pairs)
    end
    return x
end

function _replace_data(x::Layer, df)
    new_data = x.data === nothing ? nothing : Columns(columns(df))
    return Layer(; transformation=x.transformation, data=new_data, positional=x.positional, named=x.named)
end
_replace_data(x::Layers, df) = Layers([_replace_data(l, df) for l in x.layers])
_replace_data(x::YScaleLayers, df) = YScaleLayers([r => _replace_data(l, df) for (r, l) in x.layers])
_replace_data(x::PlotLine, df) = PlotLine(_replace_data(x.layers, df), x.shared, x.drawn)
_replace_data(x::PlotLines, df) = PlotLines([_replace_data(l, df) for l in x.lines], x.document)
_replace_data(x::Scaled, df) = Scaled(_replace_data(x.layers, df), x.scales, x.texts, x.legend, x.theme, x.coords, x.inspector, x.document)
_replace_data(x, _) = x

function _eval_scales_from_doc(doc::PlotDocument)
    out = Pair{Symbol,Any}[]
    for role in sort!(collect(keys(doc.scales)))
        inner = doc.scales[role]
        if length(inner) == 1 && haskey(inner, :value)
            push!(out, role => _eval_entry_value(doc, inner[:value]))
        else
            nt_pairs = Pair{Symbol,Any}[k => _eval_entry_value(doc, ev) for (k, ev) in pairs(inner)]
            push!(out, role => (; nt_pairs...))
        end
    end
    return out
end

function _eval_coords_from_doc(doc::PlotDocument, coord_obs::Dict{Symbol,Makie.Observable{Any}}, base_coords=NamedTuple[])
    out = NamedTuple[]
    for (idx, step) in enumerate(doc.coords)
        pairs_list = Pair{Symbol,Any}[]
        if haskey(step, :points)
            # Keep base points closure when available so local bindings survive data updates.
            if idx <= length(base_coords) && haskey(base_coords[idx], :points)
                push!(pairs_list, :points => base_coords[idx].points)
            else
                push!(pairs_list, :points => _eval_entry_value(doc, step[:points]))
            end
        end
        for axis_key in (:x, :y)
            haskey(step, axis_key) || continue
            sub = step[axis_key]
            sub isa Dict{Symbol,EntryValue} || continue
            sub_pairs = Pair{Symbol,Any}[]
            for subk in sort!(collect(keys(sub)))
                ckey = Symbol(axis_key, subk)
                val = haskey(coord_obs, ckey) ? coord_obs[ckey] : _eval_entry_value(doc, sub[subk])
                push!(sub_pairs, subk => val)
            end
            push!(pairs_list, axis_key => (; sub_pairs...))
        end
        if haskey(step, :aspect)
            val = haskey(coord_obs, :aspect) ? coord_obs[:aspect] : _eval_entry_value(doc, step[:aspect])
            push!(pairs_list, :aspect => val)
        end
        push!(out, (; pairs_list...))
    end
    return out
end

function _eval_legend_from_doc(doc::PlotDocument)
    pairs_list = Pair{Symbol,Any}[]
    for k in sort!(collect(keys(doc.legend)))
        k in LEGEND_ROLES && continue
        push!(pairs_list, k => _eval_entry_value(doc, doc.legend[k]))
    end
    return (; pairs_list...)
end

function _eval_theme_from_doc(doc::PlotDocument)
    doc.theme === nothing && return nothing
    pairs_list = Pair{Symbol,Any}[k => _eval_entry_value(doc, ev) for (k, ev) in pairs(doc.theme.settings)]
    return PlotTheme(doc.theme.base, (; pairs_list...))
end

function _rebuild_from_base(ep::EditablePlot)
    doc = ep.doc
    base = ep.data[] === nothing ? ep.base_plot : _replace_data(ep.base_plot, ep.data[])
    coord_obs = _ensure_coord_obs!(ep)
    if base isa Scaled
        layers = base.layers
        if layers isa PlotLines
            drawn_specs = [l for l in doc.layers if !l.is_statement_only]
            new_lines = PlotLine[]
            for (idx, line) in enumerate(layers.lines)
                if idx <= length(drawn_specs)
                    ls = drawn_specs[idx]
                    obs_pairs = _ensure_visual_obs!(ep, ls.id, ls.visual_kwargs)
                    pt = _resolve_plottype(doc, ls.plottype_expr)
                    patched_inner = _patch_layer_visual(line.layers, pt, obs_pairs)
                    push!(new_lines, PlotLine(patched_inner, line.shared, ls.visible))
                else
                    push!(new_lines, line)
                end
            end
            layers = PlotLines(new_lines, doc)
        else
            obs_pairs = _ensure_visual_obs!(ep, 0, doc.header_visual_kwargs)
            pt = _resolve_plottype(doc, doc.header_plottype_expr)
            layers = _patch_layer_visual(layers, pt, obs_pairs)
        end
        scales_vec = _eval_scales_from_doc(doc)
        coords_vec = _eval_coords_from_doc(doc, coord_obs, base.coords)
        legend_nt = _eval_legend_from_doc(doc)
        theme_obj = _eval_theme_from_doc(doc)
        return Scaled(layers, scales_vec, base.texts, legend_nt, theme_obj, coords_vec, doc.inspector, doc)
    elseif base isa PlotLines
        drawn_specs = [l for l in doc.layers if !l.is_statement_only]
        new_lines = PlotLine[]
        for (idx, line) in enumerate(base.lines)
            if idx <= length(drawn_specs)
                ls = drawn_specs[idx]
                obs_pairs = _ensure_visual_obs!(ep, ls.id, ls.visual_kwargs)
                pt = _resolve_plottype(doc, ls.plottype_expr)
                patched_inner = _patch_layer_visual(line.layers, pt, obs_pairs)
                push!(new_lines, PlotLine(patched_inner, line.shared, ls.visible))
            else
                push!(new_lines, line)
            end
        end
        pl = PlotLines(new_lines, doc)
        scales_vec = _eval_scales_from_doc(doc)
        coords_vec = _eval_coords_from_doc(doc, coord_obs)
        legend_nt = _eval_legend_from_doc(doc)
        theme_obj = _eval_theme_from_doc(doc)
        if !isempty(scales_vec) || !isempty(coords_vec) || !isempty(legend_nt) || theme_obj !== nothing || doc.inspector !== nothing
            return Scaled(pl, scales_vec, Pair{Symbol,Function}[], legend_nt, theme_obj, coords_vec, doc.inspector, doc)
        end
        return pl
    else
        obs_pairs = _ensure_visual_obs!(ep, 0, doc.header_visual_kwargs)
        pt = _resolve_plottype(doc, doc.header_plottype_expr)
        return _patch_layer_visual(base, pt, obs_pairs)
    end
end

function _mapping_entry_to_expr(m::MappingEntry)
    base = Meta.parse(m.value_expr)
    if m.transform_expr !== nothing && m.label !== nothing
        tf = Meta.parse(m.transform_expr)
        return Expr(:call, :(=>), base, Expr(:call, :(=>), tf, m.label))
    elseif m.transform_expr !== nothing
        return Expr(:call, :(=>), base, Meta.parse(m.transform_expr))
    elseif m.label !== nothing
        return Expr(:call, :(=>), base, m.label)
    else
        return base
    end
end

function _layer_terms_to_expr(
    data_expr::Union{Nothing,String},
    mapping_entries::Vector{MappingEntry},
    analysis_expr::Union{Nothing,String},
    plottype_expr::String,
    visual_pairs::Vector{Pair{Symbol,Any}};
    data_override=nothing,
)
    terms = Any[]
    if data_override !== nothing
        push!(terms, Expr(:call, :data, data_override))
    elseif data_expr !== nothing
        push!(terms, Expr(:call, :data, Meta.parse(data_expr)))
    end
    if !isempty(mapping_entries)
        kws = [Expr(:kw, m.role, _mapping_entry_to_expr(m)) for m in mapping_entries]
        push!(terms, Expr(:call, :mapping, kws...))
    end
    if analysis_expr !== nothing && !isempty(strip(analysis_expr))
        push!(terms, Meta.parse(analysis_expr))
    end
    if !isempty(plottype_expr) || !isempty(visual_pairs)
        vargs = Any[]
        isempty(plottype_expr) || push!(vargs, Meta.parse(plottype_expr))
        kws = [Expr(:kw, k, v) for (k, v) in visual_pairs]
        isempty(kws) || pushfirst!(vargs, Expr(:parameters, kws...))
        push!(terms, Expr(:call, :visual, vargs...))
    end
    isempty(terms) && return :nothing
    return foldl((a, b) -> Expr(:call, :(*), a, b), terms)
end

function _collect_lhs_names!(names::Set{Symbol}, e)
    if e isa Symbol
        push!(names, e)
    elseif e isa Expr
        if e.head in (:tuple, :parameters, :...)
            foreach(a -> _collect_lhs_names!(names, a), e.args)
        elseif e.head in (:(::), :kw) && !isempty(e.args)
            _collect_lhs_names!(names, e.args[1])
        end
    end
    return names
end

function _qualify_expanded_ast(e, eval_module::Module, locals::Set{Symbol}=Set{Symbol}())
    if e isa Makie.Observable || e isa Columns || e isa Declaration || e isa Scaled || e isa Layer ||
       e isa PlotLines || e isa PlotLine || e isa PlotTheme || e isa InspectorSpec || e isa PlotDocument
        return e
    elseif e isa Symbol
        (startswith(String(e), "#") || e in locals) && return e
        isdefined(eval_module, e) && return e
        isdefined(@__MODULE__, e) && return GlobalRef(@__MODULE__, e)
        isdefined(Makie, e) && return GlobalRef(Makie, e)
        return e
    elseif e isa GlobalRef
        return e
    elseif e isa Expr
        if e.head in (:quote, :inert)
            return e
        elseif e.head === :. && length(e.args) == 2 && e.args[2] isa QuoteNode
            return Expr(:., _qualify_expanded_ast(e.args[1], eval_module, locals), e.args[2])
        elseif e.head === :kw && length(e.args) == 2
            return Expr(:kw, e.args[1], _qualify_expanded_ast(e.args[2], eval_module, locals))
        elseif e.head === :(=) && length(e.args) == 2 && e.args[1] isa Symbol
            rhs = _qualify_expanded_ast(e.args[2], eval_module, locals)
            push!(locals, e.args[1])
            return Expr(:(=), e.args[1], rhs)
        elseif e.head === :local
            for a in e.args
                _collect_lhs_names!(locals, a isa Expr && a.head === :(=) ? a.args[1] : a)
            end
            return Expr(:local, [_qualify_expanded_ast(a, eval_module, locals) for a in e.args]...)
        elseif e.head === :let && length(e.args) == 2
            new_locals = copy(locals)
            binds = e.args[1]
            new_binds = if Meta.isexpr(binds, :block)
                Expr(:block, map(binds.args) do b
                    if Meta.isexpr(b, :(=), 2)
                        rhs = _qualify_expanded_ast(b.args[2], eval_module, new_locals)
                        _collect_lhs_names!(new_locals, b.args[1])
                        Expr(:(=), b.args[1], rhs)
                    else
                        _qualify_expanded_ast(b, eval_module, new_locals)
                    end
                end...)
            elseif Meta.isexpr(binds, :(=), 2)
                rhs = _qualify_expanded_ast(binds.args[2], eval_module, new_locals)
                _collect_lhs_names!(new_locals, binds.args[1])
                Expr(:(=), binds.args[1], rhs)
            else
                binds
            end
            return Expr(:let, new_binds, _qualify_expanded_ast(e.args[2], eval_module, new_locals))
        elseif e.head in (:(->), :function) && length(e.args) == 2
            new_locals = copy(locals)
            if Meta.isexpr(e.args[1], :call)
                for p in e.args[1].args[2:end]
                    _collect_lhs_names!(new_locals, p)
                end
            else
                _collect_lhs_names!(new_locals, e.args[1])
            end
            return Expr(e.head, e.args[1], _qualify_expanded_ast(e.args[2], eval_module, new_locals))
        else
            return Expr(e.head, map(a -> _qualify_expanded_ast(a, eval_module, locals), e.args)...)
        end
    end
    return e
end

function _eval_plot_macro_ast(macro_expr::Expr, eval_module::Module)
    expanded = macroexpand(eval_module, macro_expr)
    qualified = _qualify_expanded_ast(expanded, eval_module)
    prev = _SKIP_DOCUMENT_ATTACH[]
    _SKIP_DOCUMENT_ATTACH[] = true
    try
        return Base.invokelatest(Core.eval, eval_module, qualified)
    finally
        _SKIP_DOCUMENT_ATTACH[] = prev
    end
end

function _compile_from_doc_ast(ep::EditablePlot)
    doc = ep.doc
    coord_obs = _ensure_coord_obs!(ep)
    header_vpairs = _ensure_visual_obs!(ep, 0, doc.header_visual_kwargs)
    data_override = doc.header_data_expr !== nothing ? (ep.data[] !== nothing ? ep.data[] : ep.initial_data) : nothing
    header_expr = _layer_terms_to_expr(
        doc.header_data_expr,
        doc.header_mapping,
        doc.header_analysis_expr,
        doc.has_block ? "" : doc.header_plottype_expr,
        doc.has_block ? Pair{Symbol,Any}[] : header_vpairs;
        data_override,
    )
    need_block = doc.has_block || !isempty(doc.layers) || !isempty(doc.scales) ||
        !isempty(doc.coords) || !isempty(doc.legend) || doc.theme !== nothing || doc.inspector !== nothing

    if !need_block
        macro_expr = Expr(:macrocall, GlobalRef(@__MODULE__, Symbol("@plot")), LineNumberNode(0, :editable), header_expr)
        res = _eval_plot_macro_ast(macro_expr, doc.eval_module)
        return _finalize_compiled_result(ep, res)
    end

    block_stmts = Any[]
    for layer in doc.layers
        vpairs = _ensure_visual_obs!(ep, layer.id, layer.visual_kwargs)
        lexpr = _layer_terms_to_expr(layer.data_expr, layer.mapping, layer.analysis_expr, layer.plottype_expr, vpairs)
        stmt = if layer.name !== nothing
            Expr(:(=), layer.name, lexpr)
        else
            lexpr
        end
        if !layer.visible && !layer.is_statement_only
            stmt = Expr(:macrocall, Symbol("@invisible"), LineNumberNode(0, :editable), stmt)
        end
        push!(block_stmts, stmt)
    end
    if !isempty(doc.scales)
        skws = Expr[]
        for role in sort!(collect(keys(doc.scales)))
            inner = doc.scales[role]
            if length(inner) == 1 && haskey(inner, :value)
                push!(skws, Expr(:kw, role, Meta.parse(inner[:value].expr_text)))
            else
                nt_kws = [Expr(:kw, k, Meta.parse(ev.expr_text)) for (k, ev) in pairs(inner)]
                push!(skws, Expr(:kw, role, Expr(:tuple, Expr(:parameters, nt_kws...))))
            end
        end
        push!(block_stmts, Expr(:call, :scales, Expr(:parameters, skws...)))
    end
    for step in doc.coords
        cargs = Any[]
        haskey(step, :points) && push!(cargs, Meta.parse(step[:points].expr_text))
        ckws = Expr[]
        for axis_key in (:x, :y)
            haskey(step, axis_key) || continue
            sub = step[axis_key]
            sub isa Dict{Symbol,EntryValue} || continue
            sub_kws = [Expr(:kw, subk, get(coord_obs, Symbol(axis_key, subk), Meta.parse(ev.expr_text)))
                for (subk, ev) in pairs(sub)]
            push!(ckws, Expr(:kw, axis_key, Expr(:tuple, Expr(:parameters, sub_kws...))))
        end
        if haskey(step, :aspect)
            push!(ckws, Expr(:kw, :aspect, get(coord_obs, :aspect, Meta.parse(step[:aspect].expr_text))))
        end
        isempty(ckws) || pushfirst!(cargs, Expr(:parameters, ckws...))
        push!(block_stmts, Expr(:call, :coord, cargs...))
    end
    if !isempty(doc.legend)
        lkws = [Expr(:kw, k, Meta.parse(doc.legend[k].expr_text)) for k in sort!(collect(keys(doc.legend)))]
        push!(block_stmts, Expr(:call, :legend, Expr(:parameters, lkws...)))
    end
    if doc.theme !== nothing
        targs = Any[]
        doc.theme.base === nothing || push!(targs, QuoteNode(doc.theme.base))
        tkws = [Expr(:kw, k, Meta.parse(doc.theme.settings[k].expr_text)) for k in sort!(collect(keys(doc.theme.settings)))]
        isempty(tkws) || pushfirst!(targs, Expr(:parameters, tkws...))
        push!(block_stmts, Expr(:call, :theme, targs...))
    end

    macro_expr = Expr(:macrocall, GlobalRef(@__MODULE__, Symbol("@plot")), LineNumberNode(0, :editable),
        header_expr, Expr(:block, block_stmts...))
    res = _eval_plot_macro_ast(macro_expr, doc.eval_module)
    return _finalize_compiled_result(ep, res)
end

function _finalize_compiled_result(ep::EditablePlot, res)
    doc = ep.doc
    if res isa Declaration
        ep.base_plot = res
        if ep.data[] !== nothing
            instantiated = Base.invokelatest(res.layers, ep.data[])
            return _finalize_compiled_result(ep, instantiated)
        end
        return Declaration(res.layers, res.types, doc)
    elseif res isa Scaled
        return Scaled(res.layers, res.scales, res.texts, res.legend, res.theme, res.coords, doc.inspector, doc)
    elseif res isa PlotLines
        pl = PlotLines(res.lines, doc)
        if doc.inspector !== nothing
            return Scaled(pl, Pair{Symbol,Any}[], Pair{Symbol,Function}[], (;), nothing, NamedTuple[], doc.inspector, doc)
        end
        return pl
    elseif doc.inspector !== nothing
        resolved = res isa Union{Layer,Layers} ? resolve(res, nothing, (;)) : res
        return Scaled(resolved, Pair{Symbol,Any}[], Pair{Symbol,Function}[], (;), nothing, NamedTuple[], doc.inspector, doc)
    else
        return res
    end
end

"""
    compile_document(ep::EditablePlot)

Compile the current [`PlotDocument`](@ref) state of `ep`, returning a reactive plot object
bound to `ep.visual_obs` and `ep.coord_obs`.
"""
function compile_document(ep::EditablePlot)
    if !ep.structure_dirty && ep.base_plot !== nothing && !(ep.base_plot isa Declaration)
        return _rebuild_from_base(ep)
    elseif ep.base_plot isa Declaration && !ep.structure_dirty && ep.data[] !== nothing
        instantiated = Base.invokelatest(ep.base_plot.layers, ep.data[])
        saved_base = ep.base_plot
        ep.base_plot = instantiated
        built = _rebuild_from_base(ep)
        ep.base_plot = saved_base
        return built
    end
    return _compile_from_doc_ast(ep)
end

function _recompile!(ep::EditablePlot)
    ep.revision += 1
    ep.updating = true
    try
        ep.compiled[] = compile_document(ep)
    finally
        ep.updating = false
    end
    return ep
end

"""
    editable(plot, [input]) -> EditablePlot

Wrap `plot` in an [`EditablePlot`](@ref) whose visual attributes and coordinate settings update
through `Observable`s without recompiling analyses, and whose [`PlotDocument`](@ref) tracks
every edit for [`to_code`](@ref).
"""
editable(ep::EditablePlot) = ep

function _extract_initial_data(x::Layer)
    return x.data
end
function _extract_initial_data(x::Layers)
    for l in x.layers
        d = _extract_initial_data(l)
        d !== nothing && return d
    end
    return nothing
end
function _extract_initial_data(x::YScaleLayers)
    for (_, l) in x.layers
        d = _extract_initial_data(l)
        d !== nothing && return d
    end
    return nothing
end
function _extract_initial_data(x::PlotLines)
    for line in x.lines
        d = _extract_initial_data(line.layers)
        d !== nothing && return d
    end
    return nothing
end
_extract_initial_data(x::Scaled) = _extract_initial_data(x.layers)
_extract_initial_data(x::Declaration) = nothing
_extract_initial_data(_) = nothing

function editable(plot, input=nothing)
    doc = deepcopy(document(plot))
    data_obs = Makie.Observable{Any}(input)
    compiled_obs = Makie.Observable{Any}(nothing)
    init_data = input !== nothing ? input : _extract_initial_data(plot)
    ep = EditablePlot(
        doc,
        data_obs,
        compiled_obs,
        Dict{Int,Dict{Symbol,Makie.Observable{Any}}}(),
        Dict{Symbol,Makie.Observable{Any}}(),
        plot,
        init_data,
        false,
        0,
        false,
    )
    compiled_obs[] = compile_document(ep)
    Makie.on(data_obs) do _
        _recompile!(ep)
    end
    return ep
end

function _find_layer_target(ep::EditablePlot, layer_id::Int)
    if layer_id == 0 || (!ep.doc.has_block && isempty(ep.doc.layers))
        return 0, ep.doc.header_visual_kwargs, nothing
    end
    for layer in ep.doc.layers
        layer.id == layer_id && return layer.id, layer.visual_kwargs, layer
    end
    error("Layer id $layer_id not found in EditablePlot")
end

"""
    set_visual!(ep::EditablePlot, layer_id::Int; kwargs...) -> EditablePlot

Set `visual` keyword arguments on `layer_id` in `ep`. Existing non-semantic `Observable`
visual keys update in place without recompiling analyses.
"""
function set_visual!(ep::EditablePlot, layer_id::Int; kwargs...)
    tid, vk, _ = _find_layer_target(ep, layer_id)
    needs_recompile = false
    obs_map = get!(Dict{Symbol,Makie.Observable{Any}}, ep.visual_obs, tid)
    for (k, val) in kwargs
        vk[k] = _entry_value_from_runtime(val)
        if k in _SEMANTIC_VISUAL_KEYS || !haskey(obs_map, k)
            needs_recompile = true
        else
            obs_map[k][] = val
        end
    end
    needs_recompile && _recompile!(ep)
    return ep
end

"""
    remove_visual!(ep::EditablePlot, layer_id::Int, key::Symbol) -> EditablePlot

Remove a `visual` keyword argument from `layer_id` in `ep`.
"""
function remove_visual!(ep::EditablePlot, layer_id::Int, key::Symbol)
    tid, vk, _ = _find_layer_target(ep, layer_id)
    delete!(vk, key)
    haskey(ep.visual_obs, tid) && delete!(ep.visual_obs[tid], key)
    return _recompile!(ep)
end

function _promote_header_to_block!(ep::EditablePlot)
    ep.doc.has_block && return nothing
    if !isempty(ep.doc.header_plottype_expr) || !isempty(ep.doc.header_visual_kwargs) ||
       ep.doc.header_analysis_expr !== nothing
        id = ep.doc.next_layer_id
        ep.doc.next_layer_id += 1
        push!(ep.doc.layers, LayerSpec(
            id,
            nothing,
            true,
            nothing,
            MappingEntry[],
            ep.doc.header_analysis_expr,
            ep.doc.header_plottype_expr,
            copy(ep.doc.header_visual_kwargs),
            false,
        ))
        if haskey(ep.visual_obs, 0)
            ep.visual_obs[id] = ep.visual_obs[0]
            delete!(ep.visual_obs, 0)
        end
        ep.doc.header_analysis_expr = nothing
        ep.doc.header_plottype_expr = ""
        empty!(ep.doc.header_visual_kwargs)
    end
    ep.doc.has_block = true
    return nothing
end

"""
    set_layer_visible!(ep::EditablePlot, layer_id::Int, visible::Bool) -> EditablePlot

Show or hide `layer_id` in `ep` (corresponding to `@invisible` in code export).
"""
function set_layer_visible!(ep::EditablePlot, layer_id::Int, visible::Bool)
    _promote_header_to_block!(ep)
    _, _, layer = _find_layer_target(ep, layer_id)
    layer === nothing && error("Cannot toggle visibility of layer $layer_id")
    layer.visible = visible
    return _recompile!(ep)
end

"""
    set_layer_plottype!(ep::EditablePlot, layer_id::Int, plottype) -> EditablePlot

Change the Makie plot type (`Scatter`, `Lines`, or a string expression) of `layer_id`.
"""
function set_layer_plottype!(ep::EditablePlot, layer_id::Int, plottype::Union{AbstractString,Type})
    pt_str = plottype isa Type ? _plottype_name(plottype) : String(plottype)
    if layer_id == 0 || (!ep.doc.has_block && isempty(ep.doc.layers))
        ep.doc.header_plottype_expr = pt_str
    else
        _, _, layer = _find_layer_target(ep, layer_id)
        layer.plottype_expr = pt_str
    end
    return _recompile!(ep)
end

"""
    add_layer!(ep::EditablePlot; plottype="Scatter", visible=true, mapping=MappingEntry[], analysis=nothing, visual=Dict{Symbol,EntryValue}(), data=nothing) -> Int

Append a new layer to `ep` and return its assigned layer id.
"""
function add_layer!(
    ep::EditablePlot;
    plottype::Union{AbstractString,Type}="Scatter",
    visible::Bool=true,
    mapping::Vector{MappingEntry}=MappingEntry[],
    analysis::Union{Nothing,AbstractString}=nothing,
    visual::Dict{Symbol,EntryValue}=Dict{Symbol,EntryValue}(),
    data::Union{Nothing,AbstractString}=nothing,
)::Int
    _promote_header_to_block!(ep)
    ep.structure_dirty = true
    id = ep.doc.next_layer_id
    ep.doc.next_layer_id += 1
    pt_str = plottype isa Type ? _plottype_name(plottype) : String(plottype)
    push!(ep.doc.layers, LayerSpec(
        id,
        nothing,
        visible,
        data === nothing ? nothing : String(data),
        copy(mapping),
        analysis === nothing ? nothing : String(analysis),
        pt_str,
        copy(visual),
        false,
    ))
    _recompile!(ep)
    return id
end

"""
    remove_layer!(ep::EditablePlot, layer_id::Int) -> EditablePlot

Remove `layer_id` from `ep`.
"""
function remove_layer!(ep::EditablePlot, layer_id::Int)
    idx = findfirst(l -> l.id == layer_id, ep.doc.layers)
    idx === nothing && error("Layer id $layer_id not found")
    ep.structure_dirty = true
    deleteat!(ep.doc.layers, idx)
    delete!(ep.visual_obs, layer_id)
    return _recompile!(ep)
end

"""
    set_mapping!(ep::EditablePlot, layer_id::Union{Nothing,Int}, role::Symbol, value_expr::AbstractString; label=nothing, transform=nothing) -> EditablePlot

Set or replace mapping `role` on the header (`layer_id === nothing`) or on a layer.
"""
function set_mapping!(
    ep::EditablePlot,
    layer_id::Union{Nothing,Int},
    role::Symbol,
    value_expr::AbstractString;
    label::Union{Nothing,AbstractString}=nothing,
    transform::Union{Nothing,AbstractString}=nothing,
)
    ep.structure_dirty = true
    target = if layer_id === nothing || layer_id == 0
        ep.doc.header_mapping
    else
        _, _, layer = _find_layer_target(ep, layer_id)
        layer.mapping
    end
    entry = MappingEntry(
        role,
        String(value_expr),
        label === nothing ? nothing : String(label),
        transform === nothing ? nothing : String(transform),
    )
    idx = findfirst(m -> m.role === role, target)
    if idx === nothing
        push!(target, entry)
    else
        target[idx] = entry
    end
    return _recompile!(ep)
end

"""
    remove_mapping!(ep::EditablePlot, layer_id::Union{Nothing,Int}, role::Symbol) -> EditablePlot

Remove mapping `role` from the header (`layer_id === nothing`) or from a layer.
"""
function remove_mapping!(ep::EditablePlot, layer_id::Union{Nothing,Int}, role::Symbol)
    ep.structure_dirty = true
    target = if layer_id === nothing || layer_id == 0
        ep.doc.header_mapping
    else
        _, _, layer = _find_layer_target(ep, layer_id)
        layer.mapping
    end
    filter!(m -> m.role !== role, target)
    return _recompile!(ep)
end

"""
    set_analysis!(ep::EditablePlot, layer_id::Int, analysis_expr::Union{Nothing,AbstractString}) -> EditablePlot

Set or clear the analysis expression on `layer_id`.
"""
function set_analysis!(ep::EditablePlot, layer_id::Int, analysis_expr::Union{Nothing,AbstractString})
    ep.structure_dirty = true
    val = analysis_expr === nothing ? nothing : String(analysis_expr)
    if layer_id == 0 || (!ep.doc.has_block && isempty(ep.doc.layers))
        ep.doc.header_analysis_expr = val
    else
        _, _, layer = _find_layer_target(ep, layer_id)
        layer.analysis_expr = val
    end
    return _recompile!(ep)
end

"""
    set_scale!(ep::EditablePlot, role::Symbol; kwargs...) -> EditablePlot

Set scale attributes for `role` in `ep`.
"""
function set_scale!(ep::EditablePlot, role::Symbol; kwargs...)
    inner = get!(Dict{Symbol,EntryValue}, ep.doc.scales, role)
    for (k, v) in kwargs
        inner[k] = _entry_value_from_runtime(v)
    end
    return _recompile!(ep)
end

"""
    remove_scale!(ep::EditablePlot, role::Symbol, [key::Symbol]) -> EditablePlot

Remove a scale attribute or the entire scale entry for `role` in `ep`.
"""
function remove_scale!(ep::EditablePlot, role::Symbol, key::Union{Nothing,Symbol}=nothing)
    if key === nothing
        delete!(ep.doc.scales, role)
    elseif haskey(ep.doc.scales, role)
        delete!(ep.doc.scales[role], key)
        isempty(ep.doc.scales[role]) && delete!(ep.doc.scales, role)
    end
    return _recompile!(ep)
end

"""
    set_coord!(ep::EditablePlot; kwargs...) -> EditablePlot

Update coordinate settings (`x`, `y`, `aspect`) on `ep`. Attributes already bound as
`Observable`s update the axis in place without recompiling analyses.
"""
function set_coord!(ep::EditablePlot; kwargs...)
    isempty(ep.doc.coords) && push!(ep.doc.coords, Dict{Symbol,Any}())
    step = ep.doc.coords[end]
    needs_recompile = false
    for (k, v) in kwargs
        if k in (:x, :y) && v isa NamedTuple
            sub = get!(Dict{Symbol,EntryValue}, step, k)
            for (subk, subv) in pairs(v)
                sub[subk] = _entry_value_from_runtime(subv)
                ckey = Symbol(k, subk)
                if haskey(ep.coord_obs, ckey)
                    ep.coord_obs[ckey][] = subv
                else
                    needs_recompile = true
                end
            end
        else
            step[k] = _entry_value_from_runtime(v)
            if haskey(ep.coord_obs, k)
                ep.coord_obs[k][] = v
            else
                needs_recompile = true
            end
        end
    end
    needs_recompile && _recompile!(ep)
    return ep
end

"""
    set_legend!(ep::EditablePlot; kwargs...) -> EditablePlot

Update legend settings on `ep`.
"""
function set_legend!(ep::EditablePlot; kwargs...)
    for (k, v) in kwargs
        ep.doc.legend[k] = _entry_value_from_runtime(v)
    end
    return _recompile!(ep)
end

"""
    remove_legend!(ep::EditablePlot, key::Symbol) -> EditablePlot

Remove legend setting `key` from `ep`.
"""
function remove_legend!(ep::EditablePlot, key::Symbol)
    delete!(ep.doc.legend, key)
    return _recompile!(ep)
end

"""
    set_theme!(ep::EditablePlot, base=nothing; kwargs...) -> EditablePlot

Set the base theme symbol (such as `:dark` or `:default`) and theme settings on `ep`.
"""
function set_theme!(ep::EditablePlot, base::Union{Nothing,Symbol}=nothing; kwargs...)
    settings = ep.doc.theme === nothing ? Dict{Symbol,EntryValue}() : copy(ep.doc.theme.settings)
    for (k, v) in kwargs
        settings[k] = _entry_value_from_runtime(v)
    end
    ep.doc.theme = ThemeSpec(base, settings)
    return _recompile!(ep)
end

"""
    move_layer!(ep::EditablePlot, layer_id::Int, delta::Int) -> EditablePlot

Move `layer_id` earlier (`delta < 0`) or later (`delta > 0`) in `ep`'s layer list.
"""
function move_layer!(ep::EditablePlot, layer_id::Int, delta::Int)
    idx = findfirst(l -> l.id == layer_id, ep.doc.layers)
    idx === nothing && error("Layer id $layer_id not found")
    target = clamp(idx + delta, 1, length(ep.doc.layers))
    target == idx && return ep
    ep.structure_dirty = true
    layer = popat!(ep.doc.layers, idx)
    insert!(ep.doc.layers, target, layer)
    return _recompile!(ep)
end

function _validate_and_parse_expr(doc::PlotDocument, expr_text::AbstractString)
    parsed = Meta.parse(expr_text)
    val = _eval_in_module(doc.eval_module, parsed)
    ev = EntryValue(String(strip(expr_text)), _is_literal_expr(parsed))
    return val, ev
end

"""
    set_visual_expr!(ep::EditablePlot, layer_id::Int, key::Symbol, expr_text::AbstractString) -> EditablePlot

Evaluate `expr_text` and assign visual attribute `key` on `layer_id` while keeping `expr_text`
verbatim for [`to_code`](@ref). Updates existing bound attributes in place without recompiling.
"""
function set_visual_expr!(ep::EditablePlot, layer_id::Int, key::Symbol, expr_text::AbstractString)
    val, ev = _validate_and_parse_expr(ep.doc, expr_text)
    tid, vk, _ = _find_layer_target(ep, layer_id)
    vk[key] = ev
    obs_map = get!(Dict{Symbol,Makie.Observable{Any}}, ep.visual_obs, tid)
    if key in _SEMANTIC_VISUAL_KEYS || !haskey(obs_map, key)
        return _recompile!(ep)
    else
        obs_map[key][] = val
        return ep
    end
end

"""
    set_coord_expr!(ep::EditablePlot, key::Symbol, expr_text::AbstractString) -> EditablePlot

Evaluate `expr_text` and assign coordinate setting `key` (`:xscale`, `:yscale`, `:xreversed`,
`:yreversed`, `:xlimits`, `:ylimits`, `:aspect`, or `:points`) while keeping `expr_text`
verbatim for [`to_code`](@ref).
"""
function set_coord_expr!(ep::EditablePlot, key::Symbol, expr_text::AbstractString)
    val, ev = _validate_and_parse_expr(ep.doc, expr_text)
    isempty(ep.doc.coords) && push!(ep.doc.coords, Dict{Symbol,Any}())
    step = ep.doc.coords[end]
    axis_split = Dict{Symbol,Tuple{Symbol,Symbol}}(
        :xscale => (:x, :scale),
        :xreversed => (:x, :reversed),
        :xlimits => (:x, :limits),
        :yscale => (:y, :scale),
        :yreversed => (:y, :reversed),
        :ylimits => (:y, :limits),
    )
    if haskey(axis_split, key)
        axis_key, sub_key = axis_split[key]
        sub = get!(Dict{Symbol,EntryValue}, step, axis_key)
        sub[sub_key] = ev
        if haskey(ep.coord_obs, key)
            ep.coord_obs[key][] = val
            return ep
        end
        return _recompile!(ep)
    elseif key in (:aspect, :points)
        step[key] = ev
        if key === :aspect && haskey(ep.coord_obs, :aspect)
            ep.coord_obs[:aspect][] = val
            return ep
        end
        return _recompile!(ep)
    else
        throw(ArgumentError("Unsupported coordinate setting: $key"))
    end
end

"""
    set_scale_expr!(ep::EditablePlot, role::Symbol, key::Symbol, expr_text::AbstractString) -> EditablePlot

Evaluate `expr_text` and assign scale attribute `key` for `role` while keeping `expr_text`
verbatim for [`to_code`](@ref).
"""
function set_scale_expr!(ep::EditablePlot, role::Symbol, key::Symbol, expr_text::AbstractString)
    _, ev = _validate_and_parse_expr(ep.doc, expr_text)
    inner = get!(Dict{Symbol,EntryValue}, ep.doc.scales, role)
    inner[key] = ev
    return _recompile!(ep)
end

"""
    set_legend_expr!(ep::EditablePlot, key::Symbol, expr_text::AbstractString) -> EditablePlot

Assign legend setting `key` using `expr_text` while keeping `expr_text` verbatim for
[`to_code`](@ref).
"""
function set_legend_expr!(ep::EditablePlot, key::Symbol, expr_text::AbstractString)
    parsed = Meta.parse(expr_text)
    if !(key in LEGEND_ROLES)
        _eval_in_module(ep.doc.eval_module, parsed)
    end
    ep.doc.legend[key] = EntryValue(String(strip(expr_text)), _is_literal_expr(parsed))
    return _recompile!(ep)
end

"""
    set_theme_expr!(ep::EditablePlot; base=:keep, key=nothing, expr_text=nothing) -> EditablePlot

Update theme base or theme setting `key` with `expr_text` while preserving expression text for
[`to_code`](@ref).
"""
function set_theme_expr!(
    ep::EditablePlot;
    base::Union{Nothing,Symbol}=:keep,
    key::Union{Nothing,Symbol}=nothing,
    expr_text::Union{Nothing,AbstractString}=nothing,
)
    new_base = base === :keep ? (ep.doc.theme === nothing ? nothing : ep.doc.theme.base) : base
    settings = ep.doc.theme === nothing ? Dict{Symbol,EntryValue}() : copy(ep.doc.theme.settings)
    if key !== nothing
        if expr_text === nothing || isempty(strip(expr_text))
            delete!(settings, key)
        else
            _, ev = _validate_and_parse_expr(ep.doc, expr_text)
            settings[key] = ev
        end
    end
    if new_base === nothing && isempty(settings)
        ep.doc.theme = nothing
    else
        ep.doc.theme = ThemeSpec(new_base, settings)
    end
    return _recompile!(ep)
end

"""
    available_columns(ep::EditablePlot) -> Vector{String}

Return sorted column names from `ep`'s active dataset, or an empty vector when no table
columns are attached.
"""
function available_columns(ep::EditablePlot)::Vector{String}
    src = ep.data[] !== nothing ? ep.data[] : ep.initial_data
    src === nothing && return String[]
    try
        if src isa Columns
            return sort!(unique(String[string(c) for c in Tables.columnnames(src.columns)]))
        end
        cols = Tables.columns(src)
        return sort!(unique(String[string(c) for c in Tables.columnnames(cols)]))
    catch
        if src isa AbstractVector && !isempty(src) && first(src) isa NamedTuple
            return sort!(unique(String[string(c) for c in keys(first(src))]))
        end
        return String[]
    end
end

"""
    set_inspector!(ep::EditablePlot, spec::Union{Nothing,InspectorSpec}) -> EditablePlot

Set or clear the [`InspectorSpec`](@ref) on `ep`.
"""
function set_inspector!(ep::EditablePlot, spec::Union{Nothing,InspectorSpec})
    ep.doc.inspector = spec
    return _recompile!(ep)
end

function spec(ep::EditablePlot, args...; options...)
    current = ep.compiled[]
    if current isa Declaration && isempty(args) && ep.data[] !== nothing
        return spec(current, ep.data[]; options...)
    end
    return spec(current, args...; options...)
end

function figure(ep::EditablePlot, args...; options...)
    fig = _reactive_figure(ep.compiled, args...; options...)
    fig.attributes[:_grafico_editable] = ep
    return fig
end
