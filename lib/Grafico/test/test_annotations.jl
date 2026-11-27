using Test, CairoMakie, Grafico

_ann_linear_model(x; a = 1.0, b = 0.0) = a .* x .+ b

@testset "Annotation kinds, fit_label, insets, and inside legend" begin
    df = (x = [0.0, 1.0, 2.0, 3.0, 4.0], y = [1.1, 2.9, 5.2, 6.8, 9.1], z = [0.2, 0.4, 0.6, 0.8, 1.0])
    p = @plot data(df) * mapping(:x, :y) begin
        f = fit(_ann_linear_model, (a = 1.5, b = 0.5))
        visual(Scatter; color = :navy, markersize = 10)
        f * visual(Lines; color = :crimson, linewidth = 2)
        annotate(:fit_label, f; x = 0.05, y = 0.94, space = :relative, title = "Linear Fit")
        annotate(:text, "Note"; x = 2.0, y = 4.0)
        annotate(:arrow, "slope"; x = 0.5, y = 2.0, x2 = 1.5, y2 = 4.2, color = :darkgreen)
        annotate(:callout, "Peak"; x = 4.0, y = 9.1, tx = 2.8, ty = 8.4, color = :purple)
        annotate(:vspan, "Window"; xmin = 1.0, xmax = 2.5, color = (:gold, 0.25))
        annotate(:hspan; ymin = 2.0, ymax = 4.0, color = (:teal, 0.18))
        annotate(:rect, "ROI"; xmin = 2.6, xmax = 3.4, ymin = 6.0, ymax = 7.6)
        annotate(:hline, "Target"; y = 5.0, color = :gray40, linestyle = :dash)
        annotate(:vline; x = 3.0, color = :gray40, linestyle = :dot)
        inset(bbox = (0.58, 0.96, 0.12, 0.46), xlimits = (2.5, 4.2), ylimits = (6.0, 9.5))
        legend(position = :inside, halign = 0.1, valign = 0.2)
        panel_layout(colgaps = 12)
    end

    @test p isa Grafico.Scaled
    @test length(p.annotations) == 9
    @test length(p.insets) == 1
    @test occursin("±", p.annotations[1].text)
    @test occursin("Linear Fit", p.annotations[1].text)

    s = spec(p)
    @test s isa Makie.GridLayoutSpec
    fig = figure(p)
    img = CairoMakie.colorbuffer(fig)
    @test size(img, 1) > 0 && size(img, 2) > 0
    # Main axis + zoom inset axis are both materialized in fig.content
    @test count(b -> b isa Axis, fig.content) == 2

    # Continuous color + colorbar modifier
    p_cb = data(df) * mapping(:x, :y; color = :z) * visual(Scatter) +
        colorbar(position = :bottom, label = "Metric")
    fig_cb = figure(p_cb)
    @test any(b -> b isa Colorbar && b.label[] == "Metric", fig_cb.content)
end

@testset "EditablePlot zero-recompile annotation edits and fit update persistence" begin
    xs = collect(range(0.0, 4.0; length = 21))
    d1 = (x = xs, y = 2.0 .* xs .+ 1.0)
    d2 = (x = xs, y = 5.0 .* xs .+ 3.0)

    decl = @plot mapping(:x, :y) begin
        f = fit(_ann_linear_model, (a = 1.0, b = 0.0))
        visual(Scatter; color = :royalblue)
        f * visual(Lines; color = :crimson)
        annotate(:fit_label, f; x = 0.06, y = 0.92, space = :relative, digits = 3)
        annotate(:callout, "Focus"; x = 2.0, y = 5.0, tx = 1.2, ty = 7.0)
    end

    ep = editable(decl, d1)
    fig = figure(ep)
    img1 = copy(CairoMakie.colorbuffer(fig))

    compile_fires = Ref(0)
    Makie.on(ep.compiled) do _
        compile_fires[] += 1
    end

    # Moving and re-styling an existing annotation updates live without recompiling
    Grafico.move_annotation!(ep, 2; x = 3.0, y = 7.0, tx = 2.2, ty = 8.8)
    Grafico.set_annotation_expr!(ep, 2, :text, "Updated Focus")
    @test compile_fires[] == 0
    @test ep.annotation_obs[2][].kwargs.x == 3.0
    @test ep.annotation_obs[2][].text == "Updated Focus"
    img2 = copy(CairoMakie.colorbuffer(fig))
    @test img1 != img2

    # Hiding and re-showing an annotation works without recompiling
    Grafico.set_annotation_visible!(ep, 2, false)
    @test compile_fires[] == 0
    img_hidden = copy(CairoMakie.colorbuffer(fig))
    @test img_hidden != img2
    Grafico.set_annotation_visible!(ep, 2, true)
    @test compile_fires[] == 0

    # Updating data preserves the moved coordinates AND refreshes the fit_label numbers
    old_fit_text = ep.annotation_obs[1][].text
    Grafico.move_annotation!(ep, 1; x = 0.45, y = 0.25)
    ep.data[] = d2
    new_fit_text = ep.annotation_obs[1][].text
    @test old_fit_text != new_fit_text
    @test occursin("5", new_fit_text)
    @test ep.annotation_obs[1][].kwargs.x == 0.45
    @test ep.annotation_obs[1][].kwargs.y == 0.25

    # Dynamic add + inset + layout + remove + code export round-trip
    id3 = Grafico.add_annotation!(ep, :vspan; kwargs_exprs = Dict(:xmin => "1.0", :xmax => "2.5"))
    @test id3 == 3
    ins_id = Grafico.add_inset!(ep; bbox = (0.55, 0.95, 0.15, 0.5), xlimits = (1.0, 2.5), ylimits = (5.0, 16.0))
    @test ins_id == 1
    Grafico.move_inset!(ep, ins_id, (0.50, 0.92, 0.12, 0.48))
    Grafico.set_layout_expr!(ep, :colgaps, "16")

    code = to_code(ep; include_imports = true, include_figure = true)
    @test occursin("annotate(:fit_label, f", code)
    @test occursin("x = 0.45", code)
    @test occursin("Updated Focus", code)
    @test occursin("inset(", code)
    @test occursin("panel_layout(colgaps = 16)", code)

    # Parse back exported @plot expression and verify to_code idempotency
    plot_only = to_code(ep; include_imports = false, include_figure = false)
    reparsed = Grafico.parse_plot_code(plot_only; eval_module = @__MODULE__)
    @test to_code(reparsed) == plot_only

    Grafico.remove_annotation!(ep, id3)
    Grafico.remove_inset!(ep, ins_id)
    @test length(ep.doc.annotations) == 2
    @test isempty(ep.doc.insets)
end
