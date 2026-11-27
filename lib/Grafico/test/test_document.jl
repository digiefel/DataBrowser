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

@testset "Expression-preserving editor helpers" begin
    rows = [(time=Float64(i), signal=Float64(i)^2, series=iseven(i) ? "B" : "A") for i in 1:6]
    p = @plot data(rows) * mapping(:time, :signal; color=:series) begin
        visual(Scatter; markersize=8, color=:steelblue)
        visual(Lines; linewidth=2)
        coord(x=(; scale=identity))
    end
    ep = editable(p)
    fig = figure(ep)

    cols = Grafico.available_columns(ep)
    @test cols == ["series", "signal", "time"]

    # Zero-recompile expression edit preserves exact expression text
    Grafico.set_visual_expr!(ep, 1, :markersize, "6 * 4")
    @test ep.revision == 0
    sc = first(_native_plots_of(fig, Scatter))
    @test all(==(24), sc.markersize[])
    @test occursin("markersize = 6 * 4", to_code(ep))

    # Invalid expression throws without corrupting document
    @test_throws Exception Grafico.set_visual_expr!(ep, 1, :markersize, "6 * )")
    @test occursin("markersize = 6 * 4", to_code(ep))

    # Coordinate, scale, legend, theme expression helpers + layer reorder
    Grafico.set_coord_expr!(ep, :xscale, "log10")
    @test fig.content[1].xscale[] === log10
    @test occursin("scale = log10", to_code(ep))

    Grafico.set_scale_expr!(ep, :x, :label, "\"Time (s)\"")
    @test occursin("label = \"Time (s)\"", to_code(ep))

    Grafico.set_legend_expr!(ep, :position, ":bottom")
    @test occursin("legend(position = :bottom)", to_code(ep))

    Grafico.set_theme_expr!(ep; base=:dark, key=:fontsize, expr_text="14")
    @test occursin("theme(:dark; fontsize = 14)", to_code(ep))

    @test [l.plottype_expr for l in ep.doc.layers] == ["Scatter", "Lines"]
    Grafico.move_layer!(ep, 2, -1)
    @test [l.plottype_expr for l in ep.doc.layers] == ["Lines", "Scatter"]
    Grafico.move_layer!(ep, 2, 1)
    @test [l.plottype_expr for l in ep.doc.layers] == ["Scatter", "Lines"]
end

@testset "Legend entry toggle, ensure_editable!, live theme, and structure_dirty reset" begin
    rows = [
        (x = Float64(i), y = Float64(i) + off, series = lbl)
        for (lbl, off) in (("alpha", 0.0), ("beta", 2.0))
        for i in 1:6
    ]
    p = @plot data(rows) * mapping(:x, :y; color = :series) begin
        visual(Lines; linewidth = 2)
        visual(Scatter; markersize = 8)
    end

    # Plain figure(spec) binds legend entries to all matching series plots (Lines + Scatter)
    fig_plain = figure(p)
    leg_plain = only(filter(b -> b isa Legend, fig_plain.content))
    entries_plain = leg_plain.entrygroups[][1][2]
    @test length(entries_plain) == 2
    plots_plain = fig_plain.content[1].scene.plots
    @test length(plots_plain) == 4
    @test all(pl -> pl.visible[] == true, plots_plain)
    Makie.toggle_visibility!(entries_plain[1])
    @test [pl.visible[] for pl in plots_plain] == [false, true, false, true]
    Makie.toggle_visibility!(entries_plain[1])
    @test all(pl -> pl.visible[] == true, plots_plain)

    # ensure_editable! promotes plain figure(p) cleanly and keeps legend toggles working through LiveEntry
    ep_auto = Grafico.ensure_editable!(fig_plain)
    @test ep_auto isa Grafico.EditablePlot
    @test Grafico.editable_plot(fig_plain) === ep_auto
    leg_auto = only(filter(b -> b isa Legend, fig_plain.content))
    entries_auto = leg_auto.entrygroups[][1][2]
    Makie.toggle_visibility!(entries_auto[1])
    ax_auto = only(filter(b -> b isa Axis, fig_plain.content))
    @test [pl.plots[1].visible[] for pl in ax_auto.scene.plots] == [false, true, false, true]
    Makie.toggle_visibility!(entries_auto[1])
    @test all(pl -> pl.plots[1].visible[], ax_auto.scene.plots)

    # Visual edits propagate cleanly after ensure_editable!
    Grafico.set_visual_expr!(ep_auto, 1, :linewidth, "5")
    ax_after = only(filter(b -> b isa Axis, fig_plain.content))
    @test ax_after.scene.plots[1].plots[1].linewidth[] == 5

    # Live theme updates work in place for font size and reset cleanly for base=nothing
    ep = editable(p)
    fig = figure(ep)
    ax = only(filter(b -> b isa Axis, fig.content))
    leg = only(filter(b -> b isa Legend, fig.content))

    Grafico.set_theme_expr!(ep; base = :dark)
    @test fig.scene.backgroundcolor[] != Makie.RGBAf(1, 1, 1, 1)
    @test ax.xticklabelcolor[] != :black
    @test leg.labelcolor[] != :black

    compiled_before = ep.compiled[]
    Grafico.set_theme_expr!(ep; base = :dark, key = :fontsize, expr_text = "22")
    @test ep.compiled[] === compiled_before
    @test Float32(ax.xlabelsize[]) == 22.0f0
    @test Float32(ax.xticklabelsize[]) == 22.0f0
    @test Float32(leg.labelsize[]) == 22.0f0

    Grafico.set_theme_expr!(ep; base = nothing, key = :fontsize, expr_text = nothing)
    @test fig.scene.backgroundcolor[] == Makie.RGBAf(1, 1, 1, 1)
    @test ax.xticklabelcolor[] == :black
    @test Float32(ax.xlabelsize[]) == 14.0f0

    # structure_dirty resets to false after AST recompilation
    Grafico.add_layer!(ep; plottype = "Scatter")
    @test ep.structure_dirty == false
    Grafico.set_analysis!(ep, 2, "smooth()")
    @test ep.structure_dirty == false
end
