using Makie: Makie, Figure, GridLayout, Label
import Makie.SpecApi as S

# Interactive figures with Makie widgets and SpecApi observables: `manipulate` and `@manipulate`.

to_grid_spec(x::Makie.GridLayoutSpec) = x
to_grid_spec(x) = spec(x)

function make_control!(grid::GridLayout, row::Int, name::Symbol, domain)
    Label(grid[row, 1], string(name); halign=:right)
    if domain isa AbstractRange
        slider = Makie.Slider(grid[row, 2]; range=domain, startvalue=first(domain))
        Label(grid[row, 3], Makie.lift(v -> string(round(v; sigdigits=4)), slider.value); halign=:left)
        return slider.value
    elseif domain isa Bool
        toggle = Makie.Toggle(grid[row, 2]; active=domain, halign=:left)
        return toggle.active
    elseif (domain isa Tuple || domain isa AbstractVector) && length(domain) == 2 && Set(domain) == Set((true, false))
        toggle = Makie.Toggle(grid[row, 2]; active=first(domain), halign=:left)
        return toggle.active
    elseif domain isa NamedTuple
        opts = zip([string(k) for k in keys(domain)], values(domain))
        menu = Makie.Menu(grid[row, 2]; options=opts)
        return menu.selection
    else
        vals = collect(domain)
        labels = [v isa Pair ? string(first(v)) : string(v) for v in vals]
        values = [v isa Pair ? last(v) : v for v in vals]
        menu = Makie.Menu(grid[row, 2]; options=zip(labels, values))
        return menu.selection
    end
end

"""
    manipulate(f; controls...) -> Figure

Build an interactive `Makie.Figure` with a control widget (`Slider` for ranges, `Toggle` for
booleans, `Menu` for collections or named tuples) for each keyword in `controls`, and render
`f(values...)` (a `Grafico` plot, `ComposedFigure`, `AbstractMark`, or `Makie.SpecApi.GridLayout`)
reactively below the controls.
"""
function manipulate(f::Function; figure_kw=(;), controls...)
    fig = Figure(; figure_kw...)
    ctrl_grid = GridLayout(fig[1, 1]; tellwidth=false, halign=:left)
    observables = Makie.Observable[]
    for (row, (name, domain)) in enumerate(pairs(controls))
        push!(observables, make_control!(ctrl_grid, row, name, domain))
    end
    spec_obs = if isempty(observables)
        Makie.Observable(to_grid_spec(f()))
    else
        Makie.lift((vals...) -> to_grid_spec(f(vals...)), observables...)
    end
    Makie.plot(fig[2, 1], spec_obs)
    return fig
end

"""
    @manipulate for var1 = domain1, var2 = domain2, ...
        plot_or_spec
    end

Create an interactive `Makie.Figure` with widgets for each loop variable (`Slider` for ranges,
`Toggle` for `(true, false)`, `Menu` for vectors, tuples, or named tuples) that updates the body's
`Grafico` plot or `Makie.SpecApi.GridLayout` in place via `Observable`s.
"""
macro manipulate(loop)
    Meta.isexpr(loop, :for, 2) || error("@manipulate takes a `for var = domain, ...` loop")
    bindings_expr, body = loop.args
    raw_bindings = Meta.isexpr(bindings_expr, :block) ? bindings_expr.args : [bindings_expr]
    vars = Symbol[]
    kws = Expr[]
    for b in raw_bindings
        b isa LineNumberNode && continue
        Meta.isexpr(b, :(=), 2) || Meta.isexpr(b, :in, 2) ||
            error("@manipulate binding must be `var = domain`, got `$b`")
        var, dom = b.args
        var isa Symbol || error("@manipulate variable must be a symbol, got `$var`")
        push!(vars, var)
        push!(kws, Expr(:kw, var, esc(dom)))
    end
    fn = Expr(:->, Expr(:tuple, esc.(vars)...), esc(body))
    return :($manipulate($fn; $(kws...)))
end
