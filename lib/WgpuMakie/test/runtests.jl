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
    WgpuMakie.activate!(; headless = true, visible = false, show_editor = false)

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
end
