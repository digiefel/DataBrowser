using Test
using WgpuMakie
using Colors
using GeometryBasics

let
    grafico_dir = normpath(joinpath(@__DIR__, "..", "..", "Grafico"))
    grafico_dir in LOAD_PATH || push!(LOAD_PATH, grafico_dir)
end
using Grafico

function count_non_white(img)
    return count(c -> (red(c) < 0.96 || green(c) < 0.96 || blue(c) < 0.96), img)
end

@testset "WgpuMakie Phase 1A" begin
    @test Makie.current_backend() === WgpuMakie
    WgpuMakie.activate!(; visible = false)

    @testset "2D Axis + Lines + LineSegments + Scatter + Text + PNG save" begin
        fig = Figure(size = (400, 300))
        ax = Axis(fig[1, 1]; title = "2D Test", xlabel = "X", ylabel = "Y")
        lines!(ax, [0.0, 1.0, 2.0, 3.0], [0.5, 2.0, 1.0, 2.5]; color = :blue, linewidth = 4)
        linesegments!(ax, [Point2f(0.0, 0.0), Point2f(3.0, 0.0)]; color = :green, linewidth = 3)
        scatter!(ax, [0.5, 1.5, 2.5], [1.0, 2.2, 1.5]; color = :red, markersize = 16)
        text!(ax, 1.5, 2.6; text = "Hello WgpuMakie", color = :black)

        img = Makie.colorbuffer(fig)
        @test size(img) == (300, 400)
        @test count(c -> red(c) > 0.7 && green(c) < 0.3 && blue(c) < 0.3, img) > 40
        @test count(c -> blue(c) > 0.7 && red(c) < 0.3 && green(c) < 0.3, img) > 40
        @test count(c -> green(c) > 0.5 && red(c) < 0.3 && blue(c) < 0.3, img) > 20

        tmp_png = joinpath(tempdir(), "wgpu_makie_test_2d.png")
        isfile(tmp_png) && rm(tmp_png; force = true)
        Makie.save(tmp_png, fig)
        @test isfile(tmp_png)
        @test filesize(tmp_png) > 500
        rm(tmp_png; force = true)

        scr = Makie.getscreen(fig.scene)
        !isnothing(scr) && close(scr)
    end

    @testset "Heatmap and Image" begin
        fig = Figure(size = (400, 240))
        ax1 = Axis(fig[1, 1])
        mat = Float32[i + j for i in 1:20, j in 1:20]
        heatmap!(ax1, mat; colormap = :viridis)

        ax2 = Axis(fig[1, 2])
        rgba_img = [RGBAf(i / 20, 0.1f0, 1.0f0 - j / 20, 1.0f0) for i in 1:20, j in 1:20]
        image!(ax2, rgba_img)

        img = Makie.colorbuffer(fig)
        @test size(img) == (240, 400)
        @test count_non_white(img) > 5000

        scr = Makie.getscreen(fig.scene)
        !isnothing(scr) && close(scr)
    end

    @testset "3D Axis3 + Surface + Mesh + MeshScatter" begin
        fig = Figure(size = (360, 320))
        ax = Axis3(fig[1, 1])
        xs = range(-2, 2; length = 20)
        ys = range(-2, 2; length = 20)
        zs = [sin(x) * cos(y) for x in xs, y in ys]
        surface!(ax, xs, ys, zs; colormap = :plasma, shading = true)
        mesh!(ax, GeometryBasics.Sphere(Point3f(0, 0, 1.5), 0.4f0); color = :orange, shading = true)
        meshscatter!(ax, [Point3f(-1, -1, 1), Point3f(1, 1, 1)]; markersize = 0.25, color = :teal)

        img = Makie.colorbuffer(fig)
        @test size(img) == (320, 360)
        @test count_non_white(img) > 2000

        scr = Makie.getscreen(fig.scene)
        !isnothing(scr) && close(scr)
    end

    @testset "Live Observable update + GPU picking" begin
        pts = Observable(Point2f[(1.0, 5.0), (5.0, 5.0), (9.0, 5.0)])
        fig = Figure(size = (300, 300))
        ax = Axis(fig[1, 1]; limits = (0, 10, 0, 10))
        hidedecorations!(ax)
        hidespines!(ax)
        plt = scatter!(ax, pts; color = :red, markersize = 36)

        img1 = Makie.colorbuffer(fig)
        scr = Makie.getscreen(fig.scene)
        @test !isnothing(scr)

        # Pick middle point (5.0, 5.0) at center of canvas
        vp = Makie.viewport(ax.scene)[]
        mid_xy = (minimum(vp)[1] + widths(vp)[1] * 0.5, minimum(vp)[2] + widths(vp)[2] * 0.5)
        picked_plt, picked_idx = Makie.pick_closest(fig.scene, scr, mid_xy, 15)
        @test picked_plt === plt
        @test picked_idx == 2

        # Mutate observable -> move middle point up to (5.0, 8.5)
        pts[] = Point2f[(1.0, 5.0), (5.0, 8.5), (9.0, 5.0)]
        img2 = Makie.colorbuffer(fig; update = true)
        @test img1 != img2

        # Center should no longer hit index 2, upper point should hit index 2
        upper_xy = (minimum(vp)[1] + widths(vp)[1] * 0.5, minimum(vp)[2] + widths(vp)[2] * 0.85)
        picked_plt2, picked_idx2 = Makie.pick_closest(fig.scene, scr, upper_xy, 15)
        @test picked_plt2 === plt
        @test picked_idx2 == 2

        close(scr)
        @test !isopen(scr)
    end

    @testset "Grafico quickstart integration" begin
        rows = [(x = Float64(i), y = Float64(i)^1.5, grp = iseven(i) ? "even" : "odd") for i in 1:10]
        spec = @plot data(rows) * mapping(:x, :y; color = :grp) begin
            visual(Scatter; markersize = 12)
            visual(Lines; linewidth = 2)
        end
        fig = Grafico.figure(spec)
        img = Makie.colorbuffer(fig)
        @test size(img, 1) > 100 && size(img, 2) > 100
        @test count_non_white(img) > 500
        scr = Makie.getscreen(fig.scene)
        !isnothing(scr) && close(scr)
    end

    @testset "Grafico inspector metadata + EditablePlot updates" begin
        rows1 = [(x = Float64(i), y = Float64(i)^2, grp = iseven(i) ? "even" : "odd") for i in 1:6]
        rows2 = [(x = Float64(i), y = 10.0 - Float64(i), grp = iseven(i) ? "even" : "odd") for i in 1:6]
        spec = @plot data(rows1) * mapping(:x => "X val", :y => "Y val"; color = :grp) begin
            visual(Scatter; markersize = 10)
            inspector(:color; title = "Run 1")
        end
        ep = Grafico.editable(spec)
        fig = Grafico.figure(ep)
        img1 = Makie.colorbuffer(fig)

        ax = first(c for c in fig.content if c isa Axis)
        leaf_scatter = nothing
        function find_scatter(p)
            p isa Scatter && (leaf_scatter = p; return)
            for child in p.plots
                find_scatter(child)
            end
        end
        foreach(find_scatter, ax.scene.plots)
        @test leaf_scatter !== nothing
        meta = WgpuMakie._extract_inspector_meta(leaf_scatter)
        @test meta["label"] == "Run 1"
        @test meta["xlabel"] == "X val"
        @test meta["ylabel"] == "Y val"
        @test !isempty(meta["fields"])

        Grafico.set_visual!(ep, 1; markersize = 26)
        img2 = Makie.colorbuffer(fig; update = true)
        @test img1 != img2

        ep.data[] = rows2
        img3 = Makie.colorbuffer(fig; update = true)
        @test img2 != img3
        @test all(s -> all(==(26), s.markersize[]), begin
            found = Scatter[]
            function collect_s(p)
                p isa Scatter && push!(found, p)
                foreach(collect_s, p.plots)
            end
            foreach(collect_s, ax.scene.plots)
            found
        end)

        scr = Makie.getscreen(fig.scene)
        !isnothing(scr) && close(scr)
    end

    @testset "Editor protocol & live bi-directional editing" begin
        rows = [(x = Float64(i), y = Float64(i)^1.5, grp = iseven(i) ? "even" : "odd") for i in 1:8]
        spec = @plot data(rows) * mapping(:x, :y; color = :grp) begin
            visual(Scatter; markersize = 8, color = :steelblue)
            coord(x = (; scale = identity))
            inspector(:color; title = "Editable")
        end
        ep = Grafico.editable(spec)
        fig = Grafico.figure(ep)
        img1 = Makie.colorbuffer(fig)
        scr = Makie.getscreen(fig.scene)
        @test !isnothing(scr)

        snap = WgpuMakie._build_editor_snapshot(scr)
        @test snap["has_grafico"] == true
        @test snap["available_columns"] == ["grp", "x", "y"]
        @test occursin("@plot data(rows)", snap["code"])

        # Zero-recompile expression edit preserves source formula and updates GPU image
        WgpuMakie._handle_viewer_event!(scr, Dict(
            "op" => "editor_command",
            "command" => Dict("cmd" => "set_visual", "layer_id" => 1, "key" => "markersize", "expr" => "6 * 4"),
        ))
        @test scr.last_editor_error === nothing
        @test ep.revision == 0
        @test occursin("markersize = 6 * 4", Grafico.to_code(ep))
        img2 = Makie.colorbuffer(fig; update = true)
        @test img1 != img2

        # Add, toggle visibility, reorder, and remove layer + coord, legend, theme, inspector
        WgpuMakie._handle_viewer_event!(scr, Dict(
            "op" => "editor_command",
            "command" => Dict("cmd" => "add_layer", "plottype_expr" => "Lines"),
        ))
        @test length(ep.doc.layers) == 2

        WgpuMakie._handle_viewer_event!(scr, Dict(
            "op" => "editor_command",
            "command" => Dict("cmd" => "move_layer", "layer_id" => 2, "delta" => -1),
        ))
        @test ep.doc.layers[1].id == 2

        WgpuMakie._handle_viewer_event!(scr, Dict(
            "op" => "editor_command",
            "command" => Dict("cmd" => "set_coord", "key" => "xscale", "expr" => "log10"),
        ))
        ax = first(c for c in fig.content if c isa Axis)
        @test ax.xscale[] === log10

        WgpuMakie._handle_viewer_event!(scr, Dict(
            "op" => "editor_command",
            "command" => Dict("cmd" => "set_legend", "key" => "position", "expr" => ":bottom"),
        ))
        WgpuMakie._handle_viewer_event!(scr, Dict(
            "op" => "editor_command",
            "command" => Dict("cmd" => "set_theme", "base" => "dark", "key" => "fontsize", "expr" => "15"),
        ))
        WgpuMakie._handle_viewer_event!(scr, Dict(
            "op" => "editor_command",
            "command" => Dict("cmd" => "request_code", "include_imports" => true, "include_figure" => true),
        ))
        @test scr.editor_include_imports == true
        @test scr.editor_include_figure == true
        full_code = WgpuMakie._build_editor_snapshot(scr)["code"]
        @test startswith(full_code, "using Makie, Grafico")
        @test occursin("fig = figure(plot)", full_code)

        # Syntax error resilience: invalid expression records error without crashing or dropping plot
        WgpuMakie._handle_viewer_event!(scr, Dict(
            "op" => "editor_command",
            "command" => Dict("cmd" => "set_visual", "layer_id" => 1, "key" => "markersize", "expr" => "1 + * )"),
        ))
        @test scr.last_editor_error !== nothing

        # Valid edit clears error state
        WgpuMakie._handle_viewer_event!(scr, Dict(
            "op" => "editor_command",
            "command" => Dict("cmd" => "set_visual", "layer_id" => 1, "key" => "markersize", "expr" => "12"),
        ))
        @test scr.last_editor_error === nothing
        close(scr)

        # Plain Makie fallback editing (axes + plot attributes) + custom callback tooltip
        pfig = Figure(size = (400, 300))
        pax = Axis(pfig[1, 1]; title = "Before", xlabel = "t")
        pplt = scatter!(pax, [1.0, 2.0, 3.0], [1.0, 4.0, 9.0]; markersize = 10, color = :steelblue,
            inspector_label = (_, idx, pos) -> "cb:$idx")
        pimg1 = Makie.colorbuffer(pfig)
        pscr = Makie.getscreen(pfig.scene)
        @test WgpuMakie._build_editor_snapshot(pscr)["has_grafico"] == false

        aid = UInt64(objectid(pax))
        pid = UInt64(objectid(pplt))
        WgpuMakie._handle_viewer_event!(pscr, Dict(
            "op" => "editor_command",
            "command" => Dict("cmd" => "set_axis_attr", "axis_id" => aid, "key" => "title", "expr" => "\"After\""),
        ))
        @test pax.title[] == "After"
        WgpuMakie._handle_viewer_event!(pscr, Dict(
            "op" => "editor_command",
            "command" => Dict("cmd" => "set_plot_attr", "plot_id" => pid, "key" => "markersize", "expr" => "28"),
        ))
        @test all(==(28), pplt.markersize[])
        pimg2 = Makie.colorbuffer(pfig; update = true)
        @test pimg1 != pimg2

        # Custom inspector callback reply does not throw
        WgpuMakie._handle_viewer_event!(pscr, Dict(
            "op" => "editor_command",
            "command" => Dict("cmd" => "request_custom_tooltip", "plot_id" => pid, "element_index" => 1, "pos" => [2.0, 4.0, 0.0]),
        ))
        close(pscr)
    end

    @testset "High-throughput streaming & large-N LOD rendering" begin
        WgpuMakie.activate!(; visible = false)

        # 1) Large-N (>100k) monotonic-X line triggers Rust M4 LOD builder and preserves spikes
        n_lod = 200_000
        xs_lod = collect(Float32, range(0.0f0, 100.0f0; length = n_lod))
        ys_lod = sin.(xs_lod .* 0.5f0)
        ys_lod[50_000] = 6.0f0
        ys_lod[150_000] = -6.0f0
        fig_lod = Figure(size = (480, 240))
        ax_lod = Axis(fig_lod[1, 1])
        lines!(ax_lod, xs_lod, ys_lod; color = :royalblue, linewidth = 2)
        ylims!(ax_lod, -7.0, 7.0)
        img_lod = Makie.colorbuffer(fig_lod; update = true)
        @test size(img_lod) == (240, 480)
        @test count(c -> c.r < 0.4 && c.b > 0.6, img_lod) > 100

        # 2) 60-frame Observable streaming updates produce distinct changing renders cleanly
        n_stream = 1024
        xs_s = collect(Float32, range(0.0f0, 2.0f0 * Float32(pi); length = n_stream))
        pts_obs = Observable(Point2f.(xs_s, sin.(xs_s)))
        fig_s = Figure(size = (320, 200))
        ax_s = Axis(fig_s[1, 1])
        lines!(ax_s, pts_obs; color = :crimson, linewidth = 3)
        ylims!(ax_s, -1.5, 1.5)
        img_start = copy(Makie.colorbuffer(fig_s; update = true))
        for frame_i in 1:60
            phase = Float32(frame_i) * 0.1f0
            buf = pts_obs.val
            for j in eachindex(xs_s)
                buf[j] = Point2f(xs_s[j], sin(xs_s[j] + phase))
            end
            notify(pts_obs)
            Makie.colorbuffer(fig_s; update = true)
        end
        img_end = Makie.colorbuffer(fig_s; update = true)
        @test size(img_end) == (200, 320)
        @test img_start != img_end
    end

    @testset "Milestone 2: Annotations, Layout Manipulation & Brushing" begin
        WgpuMakie.activate!(; visible = false)

        # 1. Grafico.EditablePlot annotations, fit_label persistence, and zero-recompile moves
        fit_fn(x; a = 1.0, b = 0.0) = a * x + b
        xs = collect(range(0.0, 5.0; length = 20))
        d1 = (x = xs, y = 2.0 .* xs .+ 1.0)
        d2 = (x = xs, y = 4.0 .* xs .+ 2.0)

        decl = Grafico.@plot mapping(:x, :y) begin
            f = fit(fit_fn, (a = 1.0, b = 0.0))
            visual(Scatter; color = :steelblue, markersize = 10)
            f * visual(Lines; color = :crimson)
            annotate(:fit_label, f; x = 0.06, y = 0.92, space = :relative, digits = 3)
        end
        ep = Grafico.editable(decl, d1)
        fig = Grafico.figure(ep)
        scr = WgpuMakie.Screen(fig.scene, WgpuMakie.ScreenConfig("M2", false, 1.0f0, (640, 420)))
        display(scr, fig.scene; figure = fig)
        WgpuMakie.flush_updates!(scr)

        img0 = copy(Makie.colorbuffer(scr; update = true))
        @test length(ep.doc.annotations) == 1

        compile_fires = Ref(0)
        on(ep.compiled) do _
            compile_fires[] += 1
        end

        # Add rect + move zero-recompile + style + toggle visibility + remove
        WgpuMakie._handle_viewer_event!(scr, Dict(
            "op" => "editor_command",
            "command" => Dict(
                "cmd" => "add_annotation",
                "kind" => "rect",
                "text" => "ROI",
                "source_expr" => nothing,
                "axis_id" => nothing,
                "kwargs" => [["xmin", "1.0"], ["xmax", "3.0"], ["ymin", "2.0"], ["ymax", "8.0"]],
            ),
        ))
        @test length(ep.doc.annotations) == 2
        img1 = copy(Makie.colorbuffer(scr; update = true))
        @test img1 != img0

        fires_before_move = compile_fires[]
        WgpuMakie._handle_viewer_event!(scr, Dict(
            "op" => "editor_command",
            "command" => Dict(
                "cmd" => "move_annotation",
                "id" => 1,
                "updates" => [["x", 0.45], ["y", 0.28]],
            ),
        ))
        @test compile_fires[] == fires_before_move
        @test occursin("x = 0.45", Grafico.to_code(ep))
        img2 = copy(Makie.colorbuffer(scr; update = true))
        @test img2 != img1

        # Updating underlying data updates fit_label while keeping moved (x, y)
        old_txt = ep.annotation_obs[1][].text
        ep.data[] = d2
        WgpuMakie.flush_updates!(scr)
        @test ep.annotation_obs[1][].text != old_txt
        @test ep.annotation_obs[1][].kwargs.x == 0.45

        WgpuMakie._handle_viewer_event!(scr, Dict(
            "op" => "editor_command",
            "command" => Dict("cmd" => "set_annotation_visible", "id" => 2, "visible" => false),
        ))
        img_hidden = copy(Makie.colorbuffer(scr; update = true))
        @test img_hidden != img2
        WgpuMakie._handle_viewer_event!(scr, Dict(
            "op" => "editor_command",
            "command" => Dict("cmd" => "remove_annotation", "id" => 2),
        ))
        @test length(ep.doc.annotations) == 1
        close(scr)

        # 2. Multi-panel plain Makie layout, insets, legend move, split resize, and brushing
        fig_m = Figure(size = (800, 480))
        ax_l = Axis(fig_m[1, 1]; title = "L")
        ax_r = Axis(fig_m[1, 2]; title = "R")
        pl_s = scatter!(ax_l, [1.0, 2.0, 5.0, 6.0], [2.0, 4.0, 8.0, 9.0]; color = :blue, markersize = 14, label = "pts")
        lines!(ax_r, 1:5, 1:5; color = :orange, label = "line")
        Legend(fig_m[1, 3], ax_l)
        Colorbar(fig_m[2, 1:2]; vertical = false, limits = (0, 1))

        mscr = WgpuMakie.Screen(fig_m.scene, WgpuMakie.ScreenConfig("M2-Layout", false, 1.0f0, (800, 480)))
        display(mscr, fig_m.scene; figure = fig_m)
        WgpuMakie.flush_updates!(mscr)

        lmeta = WgpuMakie._extract_layout_meta(mscr, fig_m)
        @test length(lmeta["blocks"]) == 4
        @test any(s -> s["is_vertical"] == true && s["index"] == UInt32(1), lmeta["splits"])
        leg_block = only(filter(b -> b["kind"] == "legend", lmeta["blocks"]))
        @test leg_block["dock_position"] == "right"

        # Plain Makie annotation add + move + remove
        WgpuMakie._handle_viewer_event!(mscr, Dict(
            "op" => "editor_command",
            "command" => Dict(
                "cmd" => "add_annotation",
                "kind" => "vspan",
                "text" => "",
                "source_expr" => nothing,
                "axis_id" => UInt64(objectid(ax_l)),
                "kwargs" => [["xmin", "1.5"], ["xmax", "4.5"]],
            ),
        ))
        @test length(mscr.plain_annotations) == 1
        m_before = copy(Makie.colorbuffer(mscr; update = true))

        # Resize vertical split cleanly
        WgpuMakie._handle_viewer_event!(mscr, Dict(
            "op" => "editor_command",
            "command" => Dict(
                "cmd" => "resize_layout_split",
                "is_vertical" => true,
                "index" => 1,
                "prev_frac" => 0.72f0,
                "next_frac" => 0.28f0,
            ),
        ))
        m_split = copy(Makie.colorbuffer(mscr; update = true))
        @test m_split != m_before
        @test widths(ax_l.layoutobservables.computedbbox[])[1] > widths(ax_r.layoutobservables.computedbbox[])[1] * 1.5

        # Move legend inside cell
        WgpuMakie._handle_viewer_event!(mscr, Dict(
            "op" => "editor_command",
            "command" => Dict(
                "cmd" => "move_block",
                "block_id" => leg_block["block_id"],
                "kind" => "legend",
                "dock_position" => "inside",
                "halign" => 0.2f0,
                "valign" => 0.85f0,
            ),
        ))
        lmeta2 = WgpuMakie._extract_layout_meta(mscr, fig_m)
        leg_block2 = only(filter(b -> b["kind"] == "legend", lmeta2["blocks"]))
        @test leg_block2["dock_position"] == "inside"

        # Add inset & move inset
        WgpuMakie._handle_viewer_event!(mscr, Dict(
            "op" => "editor_command",
            "command" => Dict(
                "cmd" => "add_inset",
                "axis_id" => UInt64(objectid(ax_l)),
                "bbox" => [0.55, 0.95, 0.55, 0.95],
                "xlimits" => [0.5, 2.5],
                "ylimits" => [1.5, 4.5],
            ),
        ))
        @test length(mscr.plain_insets) == 1
        WgpuMakie._handle_viewer_event!(mscr, Dict(
            "op" => "editor_command",
            "command" => Dict(
                "cmd" => "move_inset",
                "id" => 1,
                "bbox" => [0.50, 0.92, 0.45, 0.88],
            ),
        ))
        @test mscr.plain_insets[1][2][:bbox][1] ≈ 0.50

        # Brush selection event translates zero-based Rust vertex indices into 1-based Julia indices
        WgpuMakie._handle_viewer_event!(mscr, Dict(
            "op" => "brush_selection_changed",
            "axis_id" => UInt64(objectid(ax_l)),
            "rect" => [0.5, 1.0, 3.0, 5.0],
            "plot_indices" => Any[Any[UInt64(objectid(pl_s)), UInt32[0, 1]]],
        ))
        @test !isnothing(mscr.brush_selection[])
        @test mscr.brush_selection[].axis === ax_l
        @test mscr.brush_selection[].plots[1].second == [1, 2]

        # Legend click forwards pointer events and toggles series visibility cleanly
        lmeta_cur = WgpuMakie._extract_layout_meta(mscr, fig_m)
        leg_cur = only(filter(b -> b["kind"] == "legend", lmeta_cur["blocks"]))
        leg_cx = Float64(leg_cur["bbox_px"][1] + leg_cur["bbox_px"][3] * 0.5)
        leg_cy = Float64(leg_cur["bbox_px"][2] + leg_cur["bbox_px"][4] * 0.5)
        @test pl_s.visible[] == true
        for (knd, bmask) in (("move", 0), ("down", 1), ("up", 0))
            WgpuMakie._handle_viewer_event!(mscr, Dict(
                "op" => "pointer_event",
                "x" => leg_cx,
                "y" => leg_cy,
                "buttons" => bmask,
                "kind" => knd,
            ))
        end
        @test pl_s.visible[] == false
        for (knd, bmask) in (("down", 1), ("up", 0))
            WgpuMakie._handle_viewer_event!(mscr, Dict(
                "op" => "pointer_event",
                "x" => leg_cx,
                "y" => leg_cy,
                "buttons" => bmask,
                "kind" => knd,
            ))
        end
        @test pl_s.visible[] == true

        # Inline text annotation update handles plain text cleanly
        WgpuMakie._handle_viewer_event!(mscr, Dict(
            "op" => "editor_command",
            "command" => Dict(
                "cmd" => "add_annotation",
                "kind" => "text",
                "text" => "Note",
                "source_expr" => nothing,
                "axis_id" => UInt64(objectid(ax_l)),
                "kwargs" => [["x", "2.0"], ["y", "3.0"]],
            ),
        ))
        txt_id = mscr.plain_annotations[end][:id]
        WgpuMakie._handle_viewer_event!(mscr, Dict(
            "op" => "editor_command",
            "command" => Dict("cmd" => "set_annotation_attr", "id" => txt_id, "key" => "text", "expr" => "Peak A"),
        ))
        @test mscr.plain_annotations[end][:text] == "Peak A"

        @test !hasfield(WgpuMakie.ScreenConfig, :show_editor)
        @test mscr.editor_visible[] == false
        WgpuMakie.set_editor!(fig_m, true)
        @test mscr.editor_visible[] == true
        WgpuMakie._handle_viewer_event!(mscr, Dict("op" => "editor_visibility_changed", "visible" => false))
        @test mscr.editor_visible[] == false

        # Zooming does not overwrite reset_limits
        orig_reset = copy(WgpuMakie._extract_axis_meta(ax_l)["reset_limits"])
        ax_l.targetlimits[] = GeometryBasics.Rect2d(1.5, 2.5, 1.0, 2.0)
        zoomed_meta = WgpuMakie._extract_axis_meta(ax_l)
        @test zoomed_meta["reset_limits"] ≈ orig_reset

        # wait(screen) unblocks when window_closed arrives
        wait_task = @async wait(mscr)
        yield()
        WgpuMakie._handle_viewer_event!(mscr, Dict("op" => "window_closed"))
        @test fetch(wait_task) === mscr

        close(mscr)
    end

    @testset "Plain annotation arrowhead rotation tracks pixel space" begin
        fig_arr = Makie.Figure(size = (800, 600))
        ax_arr = Makie.Axis(fig_arr[1, 1]; limits = (0, 10, 0, 1))
        Makie.lines!(ax_arr, [0.0, 10.0], [0.0, 1.0])
        scr_arr = WgpuMakie.Screen(; visible = false)
        display(scr_arr, fig_arr.scene; figure = fig_arr)

        WgpuMakie._handle_viewer_event!(scr_arr, Dict(
            "op" => "editor_command",
            "command" => Dict(
                "cmd" => "add_annotation",
                "kind" => "arrow",
                "text" => "",
                "source_expr" => nothing,
                "axis_id" => UInt64(objectid(ax_arr)),
                "kwargs" => [["x", "1.0"], ["y", "0.1"], ["x2", "5.0"], ["y2", "0.9"]],
            ),
        ))
        arr_id = scr_arr.plain_annotations[end][:id]
        arr_head = scr_arr.plain_annotation_plots[arr_id][2]

        WgpuMakie._handle_viewer_event!(scr_arr, Dict(
            "op" => "editor_command",
            "command" => Dict(
                "cmd" => "add_annotation",
                "kind" => "callout",
                "text" => "Peak",
                "source_expr" => nothing,
                "axis_id" => UInt64(objectid(ax_arr)),
                "kwargs" => [["tx", "1.0"], ["ty", "0.1"], ["x", "5.0"], ["y", "0.9"]],
            ),
        ))
        cal_id = scr_arr.plain_annotations[end][:id]
        cal_head = scr_arr.plain_annotation_plots[cal_id][2]

        exp1 = WgpuMakie._plain_arrow_screen_angle(
            ax_arr.scene,
            GeometryBasics.Point2f(1.0f0, 0.1f0),
            GeometryBasics.Point2f(5.0f0, 0.9f0),
            :data,
            ax_arr.scene.camera.projectionview[],
            Makie.viewport(ax_arr.scene)[],
        )
        data_angle = atan(0.8f0, 4.0f0)
        @test isapprox(Float32(arr_head.rotation[]), exp1; atol = 1.0f-4)
        @test isapprox(Float32(cal_head.rotation[]), exp1; atol = 1.0f-4)
        @test abs(Float32(arr_head.rotation[]) - data_angle) > 0.4f0

        Makie.ylims!(ax_arr, 0, 10)
        exp2 = WgpuMakie._plain_arrow_screen_angle(
            ax_arr.scene,
            GeometryBasics.Point2f(1.0f0, 0.1f0),
            GeometryBasics.Point2f(5.0f0, 0.9f0),
            :data,
            ax_arr.scene.camera.projectionview[],
            Makie.viewport(ax_arr.scene)[],
        )
        @test abs(exp2 - exp1) > 0.4f0
        @test isapprox(Float32(arr_head.rotation[]), exp2; atol = 1.0f-4)
        @test isapprox(Float32(cal_head.rotation[]), exp2; atol = 1.0f-4)

        close(scr_arr)
        @test isempty(scr_arr.plain_annotation_observers)
    end

    @testset "Insets keep zoom and opaque background; decorations in AxisMeta" begin
        fig_i = Makie.Figure(size = (640, 480))
        ax_i = Makie.Axis(fig_i[1, 1])
        Makie.lines!(ax_i, 0.0:0.5:10.0, 0.0:0.5:10.0; color = :blue, linewidth = 12)
        scr_i = WgpuMakie.Screen(; visible = false)
        display(scr_i, fig_i.scene; figure = fig_i)

        # Deactivated Makie camera interactions prevent ghost marquee zoom behind overlays
        for iname in (:rectanglezoom, :dragpan, :scrollzoom, :limitreset)
            if haskey(ax_i.interactions, iname)
                @test !ax_i.interactions[iname][1]
            end
        end

        # Decorations metadata reports Axis defaults and updates via set_axis_attr
        ameta = WgpuMakie._extract_axis_meta(ax_i)
        @test ameta["decorations"]["xgridvisible"] == true
        @test ameta["decorations"]["xminorticksvisible"] == false
        @test ameta["decorations"]["topspinevisible"] == true
        WgpuMakie._handle_viewer_event!(scr_i, Dict(
            "op" => "editor_command",
            "command" => Dict(
                "cmd" => "set_axis_attr",
                "axis_id" => UInt64(objectid(ax_i)),
                "key" => "topspinevisible",
                "expr" => "false",
            ),
        ))
        @test ax_i.topspinevisible[] == false

        # Plain annotations stay non-inspectable
        WgpuMakie._handle_viewer_event!(scr_i, Dict(
            "op" => "editor_command",
            "command" => Dict(
                "cmd" => "add_annotation",
                "kind" => "text",
                "text" => "Note",
                "source_expr" => nothing,
                "axis_id" => UInt64(objectid(ax_i)),
                "kwargs" => [["x", "2.0"], ["y", "2.0"]],
            ),
        ))
        ann_id = scr_i.plain_annotations[end][:id]
        @test all(p -> p.inspectable[] === false, scr_i.plain_annotation_plots[ann_id])

        # Zoom main axis, add an inset, move it, and verify both keep their limits
        Makie.xlims!(ax_i, 2.0, 8.0)
        Makie.ylims!(ax_i, 2.0, 8.0)
        zoomed_lims = ax_i.finallimits[]
        WgpuMakie._handle_viewer_event!(scr_i, Dict(
            "op" => "editor_command",
            "command" => Dict(
                "cmd" => "add_inset",
                "axis_id" => UInt64(objectid(ax_i)),
                "bbox" => [0.10, 0.90, 0.10, 0.90],
                "xlimits" => [0.5, 2.5],
                "ylimits" => [7.0, 9.0],
            ),
        ))
        @test ax_i.finallimits[] == zoomed_lims
        ins_ax = scr_i.plain_insets[1][1]
        ins_lims = ins_ax.finallimits[]

        WgpuMakie._handle_viewer_event!(scr_i, Dict(
            "op" => "editor_command",
            "command" => Dict(
                "cmd" => "move_inset",
                "id" => 1,
                "bbox" => [0.15, 0.85, 0.15, 0.85],
            ),
        ))
        @test ax_i.finallimits[] == zoomed_lims
        @test ins_ax.finallimits[] == ins_lims

        # Inset white background occludes the main diagonal blue line underneath
        img = Makie.colorbuffer(scr_i)
        center_px = img[size(img, 1) ÷ 2, size(img, 2) ÷ 2]
        @test Float64(Colors.red(center_px)) > 0.9
        @test Float64(Colors.green(center_px)) > 0.9
        @test Float64(Colors.blue(center_px)) > 0.9

        # Invalid log10 xscale rolls back axis scale, transform_func, and limits cleanly
        Makie.xlims!(ax_i, -1.0, 8.0)
        lims_before_log = ax_i.finallimits[]
        WgpuMakie._handle_viewer_event!(scr_i, Dict(
            "op" => "editor_command",
            "command" => Dict(
                "cmd" => "set_axis_attr",
                "axis_id" => UInt64(objectid(ax_i)),
                "key" => "xscale",
                "expr" => "log10",
            ),
        ))
        @test !isnothing(scr_i.last_editor_error)
        @test ax_i.xscale[] === identity
        @test ax_i.scene.transformation.transform_func[] == (identity, identity)
        @test ax_i.finallimits[] == lims_before_log

        close(scr_i)
    end

    @testset "Legend moves between outside docks and inside without phantom cells" begin
        fig_d = Makie.Figure(size = (640, 480))
        ax_d = Makie.Axis(fig_d[1, 1])
        Makie.lines!(ax_d, 1:5, 1:5; label = "a")
        leg_d = Makie.axislegend(ax_d)
        scr_d = WgpuMakie.Screen(; visible = false)
        display(scr_d, fig_d.scene; figure = fig_d)
        bid = UInt64(objectid(leg_d))

        for (dock, hx, hy) in (
            ("top", 0.5, 0.95),
            ("top", 0.25, 0.95),
            ("left", 0.05, 0.5),
            ("left", 0.05, 0.25),
            ("bottom", 0.5, 0.05),
            ("right", 0.95, 0.5),
            ("top", 0.5, 0.95),
            ("inside", 0.85, 0.85),
        )
            WgpuMakie._handle_viewer_event!(scr_d, Dict(
                "op" => "editor_command",
                "command" => Dict(
                    "cmd" => "move_block",
                    "block_id" => bid,
                    "kind" => "legend",
                    "dock_position" => dock,
                    "halign" => hx,
                    "valign" => hy,
                ),
            ))
            gl_d = WgpuMakie._active_gridlayout(fig_d)
            expected_sz = if dock in ("top", "bottom")
                (2, 1)
            elseif dock in ("left", "right")
                (1, 2)
            else
                (1, 1)
            end
            @test size(gl_d) == expected_sz
            @test all(c -> c.span.rows.start >= 1 && c.span.cols.start >= 1, gl_d.content)
            @test widths(ax_d.layoutobservables.computedbbox[])[2] > 250.0
        end
        @test size(WgpuMakie._active_gridlayout(fig_d)) == (1, 1)
        @test leg_d.orientation[] === :vertical
        ax_h = widths(ax_d.layoutobservables.computedbbox[])[2]
        @test ax_h > 300.0

        # Symbolic :rt aligns serialize to (1.0, 1.0) and corner moves reach flush edges
        leg_d.halign = :right
        leg_d.valign = :top
        meta_rt = WgpuMakie._extract_layout_meta(scr_d, fig_d)
        leg_meta_rt = first(b for b in meta_rt["blocks"] if b["kind"] == "legend")
        @test leg_meta_rt["halign"] == 1.0f0
        @test leg_meta_rt["valign"] == 1.0f0

        rt_bbox = leg_d.layoutobservables.computedbbox[]
        WgpuMakie._handle_viewer_event!(scr_d, Dict(
            "op" => "editor_command",
            "command" => Dict(
                "cmd" => "move_block",
                "block_id" => bid,
                "kind" => "legend",
                "dock_position" => "inside",
                "halign" => 0.0,
                "valign" => 0.0,
            ),
        ))
        lb_bbox = leg_d.layoutobservables.computedbbox[]
        ax_bbox = ax_d.layoutobservables.computedbbox[]
        @test abs(minimum(lb_bbox)[1] - minimum(ax_bbox)[1]) < 2.0f0
        @test abs(minimum(lb_bbox)[2] - minimum(ax_bbox)[2]) < 2.0f0

        WgpuMakie._handle_viewer_event!(scr_d, Dict(
            "op" => "editor_command",
            "command" => Dict(
                "cmd" => "move_block",
                "block_id" => bid,
                "kind" => "legend",
                "dock_position" => "inside",
                "halign" => 1.0,
                "valign" => 1.0,
            ),
        ))
        rt_after = leg_d.layoutobservables.computedbbox[]
        @test abs(minimum(rt_after)[1] - minimum(rt_bbox)[1]) < 2.0f0
        @test abs(minimum(rt_after)[2] - minimum(rt_bbox)[2]) < 2.0f0
        close(scr_d)
    end

    @testset "Declarative speculative drag specs for Legend and Colorbar" begin
        fig_s = Makie.Figure(size = (900, 600))
        ax_s = Makie.Axis(fig_s[1, 1])
        Makie.lines!(ax_s, 0.0:0.5:6.0, sin; label = "sin(x)")
        Makie.lines!(ax_s, 0.0:0.5:6.0, cos; label = "cos(x)")
        leg_s = Makie.axislegend(ax_s; position = :rt)
        scr_s = WgpuMakie.Screen(; visible = false)
        display(scr_s, fig_s.scene; figure = fig_s)

        ori_before = leg_s.orientation[]
        ax_bb_before = ax_s.layoutobservables.computedbbox[]
        meta_s = WgpuMakie._extract_layout_meta(scr_s, fig_s)
        @test leg_s.orientation[] === ori_before
        @test ax_s.layoutobservables.computedbbox[] == ax_bb_before
        @test haskey(meta_s, "drag_specs")
        @test length(meta_s["drag_specs"]) == 1

        leg_spec = meta_s["drag_specs"][1]
        @test leg_spec["kind"] == "legend"
        @test length(leg_spec["candidates"]) == 8
        @test !isnothing(leg_spec["vary"])
        top_cand = first(c for c in leg_spec["candidates"] if c["id"] == "top")
        ax_bid = UInt64(objectid(ax_s))
        spec_ax_top = first(pair[2] for pair in top_cand["layout_blocks"] if pair[1] == ax_bid)

        WgpuMakie._handle_viewer_event!(scr_s, Dict(
            "op" => "editor_command",
            "command" => Dict(
                "cmd" => "move_block",
                "block_id" => UInt64(objectid(leg_s)),
                "kind" => "legend",
                "dock_position" => "top",
                "halign" => 0.5,
                "valign" => 0.5,
            ),
        ))
        real_leg_top = WgpuMakie._block_bbox_px(leg_s)
        real_ax_top = WgpuMakie._block_bbox_px(ax_s)
        @test all(i -> abs(top_cand["target_bbox_px"][i] - real_leg_top[i]) < 2.0f0, 1:4)
        @test all(i -> abs(spec_ax_top[i] - real_ax_top[i]) < 2.0f0, 1:4)
        close(scr_s)

        fig_cb = Makie.Figure(size = (700, 500))
        ax_cb = Makie.Axis(fig_cb[1, 1])
        hm = Makie.heatmap!(ax_cb, rand(8, 8))
        cb = Makie.Colorbar(fig_cb[1, 2], hm)
        scr_cb = WgpuMakie.Screen(; visible = false)
        display(scr_cb, fig_cb.scene; figure = fig_cb)
        meta_cb = WgpuMakie._extract_layout_meta(scr_cb, fig_cb)
        cb_spec = first(s for s in meta_cb["drag_specs"] if s["kind"] == "colorbar")
        @test length(cb_spec["candidates"]) == 4
        @test isnothing(cb_spec["vary"])
        close(scr_cb)
    end

    @testset "Axis3 reset, child inspectability, and colormap names" begin
        fig3 = Makie.Figure(size = (700, 520))
        ax3 = Makie.Axis3(fig3[1, 1])
        xs = range(-2, 2; length = 12)
        surf = Makie.surface!(ax3, xs, xs, [sin(x) * cos(y) for x in xs, y in xs]; colormap = :plasma)
        msh = Makie.mesh!(ax3, GeometryBasics.Sphere(GeometryBasics.Point3f(0, 0, 1), 0.3f0); color = :steelblue)
        msc = Makie.meshscatter!(ax3, [GeometryBasics.Point3f(i * 0.3f0, 0, 0.5f0) for i in 1:4]; color = 1:4, colormap = :turbo)
        scr3 = WgpuMakie.Screen(; visible = false)
        display(scr3, fig3.scene; figure = fig3)

        # Child backdrop LineSegments inside ax3.blockscene inherit inspectable == false
        bs_msgs = Dict{String, Any}[]
        WgpuMakie._collect_scene_plots!(scr3, ax3.blockscene, ax3.blockscene.plots, bs_msgs, Ref(Int32(0)))
        @test !isempty(bs_msgs)
        @test all(m -> !m["plot"]["inspectable"], bs_msgs)

        # Surface and MeshScatter report true colormap names, while layout reports Axis3 scene_id
        data_msgs = Dict{String, Any}[]
        WgpuMakie._collect_scene_plots!(scr3, ax3.scene, ax3.scene.plots, data_msgs, Ref(Int32(0)))
        cmap_names = [m["plot"]["primitive"]["colormap"]["name"] for m in data_msgs if haskey(m["plot"]["primitive"], "colormap") && !isnothing(m["plot"]["primitive"]["colormap"])]
        @test ":plasma" in cmap_names
        @test ":turbo" in cmap_names
        meta3 = WgpuMakie._extract_layout_meta(scr3, fig3)
        ax3_blk = first(b for b in meta3["blocks"] if b["kind"] == "axis3")
        @test ax3_blk["scene_id"] == UInt64(objectid(ax3.scene))

        # Cmd+left-click resets Axis3 view angles and zoom
        orig_el = Float64(ax3.elevation[])
        orig_az = Float64(ax3.azimuth[])
        orig_zm = Float64(ax3.zoom_mult[])
        ax3.elevation[] = orig_el + 0.4
        ax3.azimuth[] = orig_az + 0.5
        ax3.zoom_mult[] = orig_zm * 1.4
        vp3 = Makie.viewport(ax3.scene)[]
        cx = Float64(minimum(vp3)[1] + 0.5 * widths(vp3)[1])
        cy = Float64(minimum(vp3)[2] + 0.5 * widths(vp3)[2])
        WgpuMakie._handle_viewer_event!(scr3, Dict(
            "op" => "pointer_event",
            "x" => cx,
            "y" => cy,
            "kind" => "down",
            "buttons" => 0x01,
            "modifiers" => 0x02,
        ))
        @test isapprox(Float64(ax3.elevation[]), orig_el; atol = 1e-6)
        @test isapprox(Float64(ax3.azimuth[]), orig_az; atol = 1e-6)
        @test isapprox(Float64(ax3.zoom_mult[]), orig_zm; atol = 1e-6)
        close(scr3)
    end

    @testset "Zooming updates shifted scene viewports on multi-subplot layouts" begin
        fig_z = Makie.Figure(size = (960, 480))
        ax1 = Makie.Axis(fig_z[1, 1]; title = "Heatmap", xlabel = "x", ylabel = "y")
        xs = range(-2, 2; length = 40)
        ys = range(-2, 2; length = 40)
        mat = [exp(-(x^2 + y^2)) * cos(3x) for x in xs, y in ys]
        hm = Makie.heatmap!(ax1, xs, ys, mat; colormap = :inferno)
        Makie.Colorbar(fig_z[1, 2], hm)
        ax2 = Makie.Axis(fig_z[1, 3]; title = "RGBA Image", aspect = Makie.DataAspect())
        img_data = [RGBAf(i / 32, j / 32, 0.5f0, 1.0f0) for i in 1:32, j in 1:32]
        Makie.image!(ax2, img_data)

        scr_z = WgpuMakie.Screen(; visible = false)
        display(scr_z, fig_z.scene; figure = fig_z)

        vp1_before = Makie.viewport(ax1.scene)[]
        aid1 = UInt64(objectid(ax1))
        # Zoom in so y-tick labels widen ("-1,0,1" -> "-0.25,0.00,0.25,0.50,0.75") and shift viewports right
        updates = Dict{UInt64, Tuple{Vector{Float64}, UInt64}}(
            aid1 => ([-0.52, -0.24, 0.14, 0.78], UInt64(1)),
        )
        WgpuMakie._apply_axis_limits!(scr_z, updates)
        vp1_after = Makie.viewport(ax1.scene)[]
        @test minimum(vp1_after)[1] > minimum(vp1_before)[1] + 2.0f0

        buf = Makie.colorbuffer(scr_z)
        h_px, w_px = size(buf)
        left_spine_x = round(Int, minimum(vp1_after)[1])
        mid_y_topdown = clamp(h_px - round(Int, minimum(vp1_after)[2] + 0.5 * widths(vp1_after)[2]), 1, h_px)
        outside_x = clamp(left_spine_x - 6, 1, w_px)
        px_out = buf[mid_y_topdown, outside_x]
        @test Float64(Colors.red(px_out)) > 0.9
        @test Float64(Colors.green(px_out)) > 0.9
        @test Float64(Colors.blue(px_out)) > 0.9
        close(scr_z)
    end
end
