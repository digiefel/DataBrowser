using Test
using Grafico
using Makie

function _native_plots_of(fig, ::Type{T}) where {T}
    found = Any[]
    function visit(p)
        p isa T && push!(found, p)
        for child in p.plots
            visit(child)
        end
    end
    for p in fig.content[1].scene.plots
        visit(p)
    end
    return found
end

@testset "Inspector API" begin
    rows = [(x=Float64(i), y=Float64(i)^2, chip=iseven(i) ? "B" : "A") for i in 1:6]

    p_off = @plot data(rows) * mapping(:x, :y; color=:chip) begin
        visual(Scatter)
        inspector(false)
    end
    fig_off = figure(p_off)
    for plt in _native_plots_of(fig_off, Scatter)
        @test plt.inspectable[] == false
    end

    custom_cb(plt, idx, pos) = "custom:$idx"
    p_cb = @plot data(rows) * mapping(:x, :y; color=:chip) begin
        visual(Scatter)
        inspector(custom_cb)
    end
    fig_cb = figure(p_cb)
    for plt in _native_plots_of(fig_cb, Scatter)
        @test plt.inspector_label[] === custom_cb
    end

    p_dec = @plot data(rows) * mapping(:x => "Time (s)", :y => "Voltage (V)"; color=:chip) begin
        visual(Scatter)
        inspector(:color; title="Sweep 1", digits=3)
    end
    fig_dec = figure(p_dec)
    scatters = _native_plots_of(fig_dec, Scatter)
    @test length(scatters) == 2
    insp_fn = scatters[1].inspector_label[]
    @test insp_fn isa Grafico.DeclarativeInspector
    tip = insp_fn(scatters[1], 1, Point2f(1.2345, 2.0))
    @test occursin("Sweep 1", tip)
    @test occursin("Time (s): 1.23", tip)
    @test occursin("Voltage (V): 2", tip)

    p_nocoords = @plot data(rows) * mapping(:x, :y; color=:chip) begin
        visual(Scatter)
        inspector(:chip; show_coords=false)
    end
    fig_nc = figure(p_nocoords)
    s_nc = first(_native_plots_of(fig_nc, Scatter))
    tip_nc = s_nc.inspector_label[](s_nc, 1, Point2f(1.0, 2.0))
    @test !occursin("x:", tip_nc)
    @test occursin("chip:", tip_nc)

    # Modifier composition
    p_mod = data(rows) * mapping(:x, :y; color=:chip) * visual(Scatter) + inspector(:color; title="Composed")
    fig_mod = figure(p_mod)
    s_mod = first(_native_plots_of(fig_mod, Scatter))
    @test s_mod.inspector_label[] isa Grafico.DeclarativeInspector
    @test occursin("Composed", s_mod.inspector_label[](s_mod, 1, Point2f(1.0, 1.0)))
end

@testset "EditablePlot zero-recompile visual & coord updates" begin
    rows = [(x=Float64(i), y=2.0 * i + 1.0, chip="A") for i in 1:8]
    transform_calls = Ref(0)
    scale_y(v) = (transform_calls[] += 1; v)

    p = @plot data(rows) * mapping(:x, :y => scale_y) begin
        visual(Scatter; markersize=8, color=:steelblue)
        coord(x=(; scale=identity), aspect=AxisAspect(1))
    end
    ep = editable(p)
    fig = figure(ep)
    initial_calls = transform_calls[]
    @test initial_calls >= 1

    sc_before = only(_native_plots_of(fig, Scatter))
    @test all(==(8), sc_before.markersize[])

    # Mutate visual kwargs in place via Observable -> zero analysis recompile, same plot identity
    Grafico.set_visual!(ep, 1; markersize=18, color=:crimson)
    sc_after = only(_native_plots_of(fig, Scatter))
    @test sc_after === sc_before
    @test all(==(18), sc_after.markersize[])
    @test transform_calls[] == initial_calls
    @test ep.revision == 0

    # Mutate already-bound coord keys via _AxisBinding -> zero analysis recompile
    Grafico.set_coord!(ep; x=(; scale=log10), aspect=DataAspect())
    ax = fig.content[1]
    @test ax.xscale[] === log10
    @test ax.aspect[] == DataAspect()
    @test transform_calls[] == initial_calls
end

@testset "EditablePlot structural edits and data update persistence" begin
    rows1 = [(x=Float64(i), y=Float64(i), grp=iseven(i) ? "B" : "A") for i in 1:6]
    rows2 = [(x=Float64(i), y=Float64(i) * 10.0, grp=iseven(i) ? "B" : "A") for i in 1:6]

    p = @plot data(rows1) * mapping(:x, :y; color=:grp) begin
        visual(Scatter; markersize=8)
    end
    ep = editable(p)
    fig = figure(ep)

    Grafico.set_visual!(ep, 1; markersize=20)
    id2 = Grafico.add_layer!(ep; plottype=Lines)
    @test length(_native_plots_of(fig, Scatter)) == 2
    @test length(_native_plots_of(fig, Lines)) == 2

    Grafico.set_legend!(ep; position=:bottom)
    Grafico.set_theme!(ep, :dark)
    Grafico.set_inspector!(ep, inspector(:grp; title="Persisted"))

    # Toggle visibility of line layer -> @invisible in document & hidden in plot
    Grafico.set_layer_visible!(ep, id2, false)
    @test isempty(_native_plots_of(fig, Lines))
    Grafico.set_layer_visible!(ep, id2, true)
    @test length(_native_plots_of(fig, Lines)) == 2

    # Updating ep.data[] keeps all prior edits applied
    ep.data[] = rows2
    scatters = _native_plots_of(fig, Scatter)
    @test all(s -> all(==(20), s.markersize[]), scatters)
    @test length(_native_plots_of(fig, Lines)) == 2
    @test occursin("Persisted", first(scatters).inspector_label[](first(scatters), 1, Point2f(1, 10)))
    ymax = maximum(pt[2] for s in scatters for pt in s[1][])
    @test ymax ≈ 60.0

    # Remove added layer
    Grafico.remove_layer!(ep, id2)
    @test isempty(_native_plots_of(fig, Lines))
end

@testset "Declaration editable updates" begin
    d1 = (V=[1.0, 2.0, 3.0], I=[2.0, 4.0, 6.0])
    d2 = (V=[1.0, 2.0, 3.0], I=[5.0, 10.0, 15.0])
    decl = @plot mapping(:V, :I) begin
        visual(Scatter; markersize=9)
    end
    ep = editable(decl, d1)
    fig = figure(ep)
    Grafico.set_visual!(ep, 1; markersize=15)
    ep.data[] = d2
    sc = only(_native_plots_of(fig, Scatter))
    @test all(==(15), sc.markersize[])
    @test maximum(pt[2] for pt in sc[1][]) ≈ 15.0
end

@testset "Code generation and round-trip fidelity" begin
    rows = [(x=Float64(i), y=Float64(i)^2, grp=i <= 2 ? "A" : "B") for i in 1:5]
    p = @plot data(rows) * mapping(:x, :y; color=:grp) begin
        visual(Scatter; markersize=10)
        @invisible visual(Lines)
        scales(x=(; scale=identity))
        coord(aspect=DataAspect())
        legend(position=:bottom)
        theme(:dark)
        inspector(:grp; title="Title")
    end
    ep = editable(p)
    Grafico.set_visual!(ep, 1; markersize=14)

    code = to_code(ep)
    for forbidden in ("PlotDocument", "LayerSpec", "MappingEntry", "EntryValue", "InspectorSpec", "EditablePlot")
        @test !occursin(forbidden, code)
    end
    @test occursin("@plot data(rows)", code)
    @test occursin("markersize = 14", code)
    @test occursin("@invisible visual(Lines)", code)
    @test occursin("scales(", code)
    @test occursin("coord(", code)
    @test occursin("legend(position = :bottom)", code)
    @test occursin("theme(:dark)", code)
    @test occursin("inspector(:grp; title = \"Title\")", code)

    # Round-trip parse
    reparsed = Grafico.parse_plot_code(code)
    @test length(reparsed.layers) == 2
    @test reparsed.layers[1].visual_kwargs[:markersize].expr_text == "14"
    @test reparsed.layers[2].visible == false
    @test reparsed.inspector !== nothing
    @test reparsed.inspector.title == "Title"

    # Script export mode + standalone round-trip eval in fresh module
    script = to_code(ep; include_imports=true, include_figure=true)
    @test startswith(script, "using Makie, Grafico\nplot = @plot ")
    @test endswith(script, "fig = figure(plot)")

    mod = Module(:RoundTripTest)
    Core.eval(mod, :(using Makie, Grafico))
    Core.eval(mod, :(rows = $rows))
    eval_plot = Base.invokelatest(Core.eval, mod, Meta.parse(code))
    eval_fig = Base.invokelatest(figure, eval_plot)
    @test eval_fig isa Makie.Figure

    # Figure-level code export
    fig = figure(ep)
    @test to_code(fig) == code
end
