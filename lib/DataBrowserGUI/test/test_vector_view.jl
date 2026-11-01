using Test, DataBrowserGUI
import CImGui as ig
using DataBrowserAPI: draw!, draw_header!, initial_size, label, prepare!, settings
using DataBrowserCore: Group, Selection
using DataBrowserGUI: TableSelection
using DataBrowserGUI.Browser: VectorView, distribution_frame_widths, vector_density, vector_signal, visualizers
@isdefined(ItemsProject) || include("fixtures/items_project.jl")

@testset "composed vector view draws without a graphics backend" begin
    gui = ig.CreateContext()
    plots = ig.lib.ImPlot_CreateContext()
    try
        io = ig.GetIO()
        unsafe_store!(io.IniFilename, C_NULL)
        unsafe_store!(io.DisplaySize, ig.ImVec2(960, 640))
        unsafe_store!(io.DeltaTime, 1 / 60)
        unsafe_store!(io.BackendFlags,
            unsafe_load(io.BackendFlags) | ig.ImGuiBackendFlags_RendererHasTextures)
        view = VectorView()
        ctx = (id="vector-test",)
        # Reuse one view, as a live window does when its value changes. Ranges, views, empty
        # inputs, ties and nonfinite values must all draw through the visualizer contract.
        for values in (1:10, @view([4.0, 2, 2, 8][2:4]), Float32[3], fill(0.0, 20),
                [NaN, 1, Inf, 2, -Inf, 3, NaN], [NaN, Inf], Float64[])
            @test prepare!(view, values, ctx) === nothing
            for _ in 1:2
                ig.NewFrame()
                ig.SetNextWindowPos((0, 0))
                ig.SetNextWindowSize(initial_size(view))
                ig.Begin("Vector test")
                @test draw!(view, ctx) === nothing
                ig.End()
                ig.Render()
                @test unsafe_load(ig.GetDrawData().TotalVtxCount) > 0
            end
        end
        # Changing these settings does not run prepare! again in the browser.
        prepare!(view, [1.0, 2, 3, 7], ctx)
        for bins in (16, 32, 64, 128, 256, 512), density in (false, true)
            view.bins, view.density, view.markers = bins, density, true
            ig.NewFrame()
            ig.Begin("Vector test")
            @test draw!(view, ctx) === nothing
            ig.End()
            ig.Render()
        end
        for values in (fill(3.0, 10), [1e16, 1e16 + 2, 1e16 + 4]), smooth in (false, true)
            view.smooth = smooth
            prepare!(view, values, ctx)
            ig.NewFrame()
            ig.Begin("Vector test")
            @test draw!(view, ctx) === nothing
            ig.End()
            ig.Render()
        end
        # The browser's + Window menu receives a Selection, including when "through" returns
        # a vector. Exercise that contract rather than only the standalone drawing case.
        @test any(v -> v isa VectorView, visualizers(Selection))
        for selected in (selection_of(("vector", [1.0, 2, 3], ())), selection_of(),
                selection_of(("vector", [1, 2], ()), ("other", [3, 4], ())))
            @test prepare!(view, selected, ctx) === nothing
            ig.NewFrame()
            ig.Begin("Vector test")
            @test draw!(view, ctx) === nothing
            ig.End()
            ig.Render()
        end
        # Selecting one table column keeps its name and row order. That one-column result
        # is usable by Vector without an additional column chooser.
        table_item = Group("vector", Dict{Symbol,Any}(), (Time_s=[1.0, 2, 3], Current_A=[4.0, 5, 6]), [])
        selected_column = table_item[TableSelection([3, 1], [["Current_A"]])]
        @test selected_column.data == (Current_A=[6.0, 4.0],)
        for data in (selected_column.data, (Current_A=Float64[],))
            @test prepare!(view, selection_of(("vector", data, ())), ctx) === nothing
            ig.NewFrame()
            ig.Begin("Vector test")
            @test draw!(view, ctx) === nothing
            ig.End()
            ig.Render()
        end
        # Each table-column result remains a separate vector, including unequal lengths and
        # empty/nonfinite inputs. Both distributions and spectra must draw for the selection.
        overlay = selection_of([("series-$i", (Current_A=values,), ())
            for (i, values) in enumerate(([1.0, 2, 4, 8], [3.0, -1], Float64[], [NaN, Inf]))]...)
        for signal in (false, true)
            view.signal = signal
            prepare!(view, overlay, ctx)
            for logarithmic in (false, true), density in (false, true)
                view.log_frequency = view.log_amplitude = logarithmic
                view.density = density
                ig.NewFrame()
                ig.Begin("Vector test")
                @test draw_header!(view, ctx) === nothing
                @test draw!(view, ctx) === nothing
                ig.End()
                ig.Render()
            end
        end
        view.signal = false
        # Multiple columns, including numeric plus nonnumeric, require an explicit selection.
        for data in ((x=[1.0, 2, 3], y=[4.0, 5, 6]), Dict(:x => [1, 2]),
                (x=[1.0, 2], name=["a", "b"]), (name=["a", "b"],),
                "text", [1 2; 3 4], ComplexF64[1, 2])
            @test_throws Union{ArgumentError,MethodError} prepare!(view, selection_of(("vector", data, ())), ctx)
        end
        view.signal = true
        for values in ([sinpi(i / 8) for i in 0:63], fill(2.0, 64), [NaN, 1.0], [1.0], Float64[])
            @test prepare!(view, values, ctx) === nothing
            ig.NewFrame()
            ig.Begin("Vector test")
            @test draw!(view, ctx) === nothing
            ig.End()
            ig.Render()
        end
        # Scale changes only affect drawing; include one positive frequency bin and a zero spectrum.
        for values in ([sinpi(i / 8) for i in 0:63], [1.0, -1.0], zeros(8))
            prepare!(view, values, ctx)
            for (log_frequency, log_amplitude) in ((false, false), (true, false), (false, true), (true, true), (false, false)), markers in (false, true)
                view.log_frequency = log_frequency
                view.log_amplitude = log_amplitude
                view.markers = markers
                ig.NewFrame()
                ig.Begin("Vector test")
                @test draw_header!(view, ctx) === nothing
                @test draw!(view, ctx) === nothing
                ig.End()
                ig.Render()
            end
        end
    finally
        ig.lib.ImPlot_DestroyContext(plots)
        ig.DestroyContext(gui)
        foreach(Workspace.close_workspace!, OPENED)
        empty!(OPENED)
    end
end

@testset "distribution frame widths include each axis" begin
    histogram = (frame=200.0, plot=180.0)
    ecdf = (frame=200.0, plot=120.0)
    h, e = distribution_frame_widths(histogram, ecdf)
    @test h + e == histogram.frame + ecdf.frame
    @test h - (histogram.frame - histogram.plot) == e - (ecdf.frame - ecdf.plot)
end

@testset "signal analysis preserves amplitude, power and sample spacing" begin
    for n in (128, 129)
        spacing, amplitude, k = 0.002, 3.0, 7
        values = [4 + amplitude * sinpi(2k * i / n) for i in 0:n-1]
        data = vector_signal(values, spacing)
        @test isempty(data.issue)
        @test data.frequency[argmax(data.amplitude)] ≈ k / (n * spacing)
        @test maximum(data.amplitude) ≈ amplitude
        @test first(data.amplitude) ≈ 0 atol=1e-12
        @test sum(data.psd) / (n * spacing) ≈ amplitude^2 / 2
        @test first(data.correlation) ≈ 1
        scaled = vector_signal(values, 1000spacing)
        @test scaled.frequency ≈ data.frequency ./ 1000
        @test scaled.psd ≈ data.psd .* 1000
        @test scaled.lag ≈ data.lag .* 1000
    end
    @test vector_signal([-1.0, 0, 1], 1.0).correlation ≈ [1.0, 0, -0.5] atol=1e-12
    # DC and the even-length Nyquist bin are not doubled in a one-sided spectrum.
    dc = vector_signal(fill(3.0, 64), 1.0; remove_mean=false)
    @test first(dc.amplitude) ≈ 3
    @test sum(dc.psd) / 64 ≈ 9
    @test isempty(dc.correlation)
    nyquist = vector_signal([2.0 * (-1)^i for i in 0:63], 1.0)
    @test last(nyquist.amplitude) ≈ 2
    @test !isempty(vector_signal([NaN, 1.0], 1.0).issue)
    @test !isempty(vector_signal([1.0, 2], 0.0).issue)
    @test !isempty(vector_signal([1.0], 1.0).issue)
end

@testset "smoothed distribution preserves probability and units" begin
    values = [-2.0, -1, 0, 0, 1, 2]
    xs, density = vector_density(values)
    dx = xs[2] - xs[1]
    @test all(>=(0), density)
    @test sum(density) * dx ≈ 1 atol=1e-4
    @test sum(xs .* density) * dx ≈ 0 atol=1e-4
    # Changing the unit of the values rescales density by the inverse factor.
    scaled_xs, scaled_density = vector_density(1000 .* values)
    @test scaled_xs ≈ 1000 .* xs
    @test scaled_density ≈ density ./ 1000
end
