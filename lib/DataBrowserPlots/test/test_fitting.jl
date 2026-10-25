using Test, DataBrowserAPI, DataBrowserCore, DataBrowserPlots, GLMakie, AlgebraOfGraphics

resistance(gap; Rc, Rsh) = 2Rc + Rsh * gap
estimate(parameter) = parameter.value

struct FitTestDevice <: AbstractDataItem
    name::String
    chip::String
    gap::Float64
    R::Float64
end
DataBrowserAPI.id(device::FitTestDevice) = device.name
DataBrowserAPI.metadata(device::FitTestDevice) =
    Dict{Symbol,Any}(:Chip => device.chip, :Wafer => "W$(device.chip)", :gap => device.gap)
DataBrowserAPI.item_data(device::FitTestDevice) = (R=[device.R],)

axis(drawn) = only(filter(c -> c isa Axis, drawn.content))

@testset "a fit draws one curve for each group, and the legend text reads each group's values" begin
    # Two chips with exact lines: R = 2 * 300 + 100 * gap and R = 2 * 50 + 100 * gap.
    devices = [FitTestDevice("$chip$gap", chip, gap, 2Rc + 100gap)
        for (chip, Rc) in (("A", 300), ("B", 50)) for gap in (5.0, 10.0, 20.0)]
    plot = @plot mapping(:gap, only(:data.R); color=:Chip) begin
        visual(Scatter)
        contacts = fit(resistance, (Rc=1.0, Rsh=1.0))
        contacts * visual(Lines)
        scales(color = (; categories = ["A" => "chip A", "B" => "chip B"]))
        legend(color = "$(:Chip) on $(:Wafer): $(round(estimate(contacts.Rc)))")
    end
    legend = only(filter(c -> c isa Legend, figure(plot, select(devices)).content))
    @test [entry.label[] for (_, entries) in legend.entrygroups[] for entry in entries] == ["chip A on WA: 300.0", "chip B on WB: 50.0"]
end

@testset "a named fit takes the rows of the header's own table" begin
    rows = [(gap=g, R=2 * 300 + 100g) for g in (5.0, 10.0, 20.0)]
    plot = @plot data(rows) * mapping(:gap, :R) begin
        contacts = fit(resistance, (Rc=1.0, Rsh=1.0))
        contacts * visual(Lines)
    end
    curve = only(p for p in axis(figure(plot)).scene.plots if p isa Lines)[1][]
    @test first(curve) ≈ Point2f(5, 1100)
end

@testset "a fit line changes the points as any line does" begin
    devices = [FitTestDevice("$chip$gap", chip, gap, 2Rc + 100gap)
        for (chip, Rc) in (("A", 300), ("B", 50)) for gap in (5.0, 10.0, 20.0)]
    # Without color, the two chips are one group: Rc is their mean, 175.
    plot = @plot mapping(:gap, only(:data.R); color=:Chip) begin
        mapping(; color=nothing) * fit(resistance, (Rc=1.0, Rsh=1.0)) * visual(Lines)
    end
    curve = only(p for p in axis(figure(plot, select(devices))).scene.plots if p isa Lines)[1][]
    @test first(curve) ≈ Point2f(5, 850)
end

average(values) = sum(values) / length(values)
half_range(values) = (maximum(values) - minimum(values)) / 2

@testset "a line maps the values of an aggregate, and takes its x when it maps only y" begin
    devices = [FitTestDevice("$chip$gap$R", chip, gap, R) for chip in ("A", "B") for gap in (5.0, 10.0) for R in (1.0, 3.0)]
    plot = @plot mapping(:gap, only(:data.R); color=:Chip) begin
        result = aggregate(average, half_range)
        mapping(y = result.average) * visual(Scatter)
        mapping(result.gap, result.average, result.half_range) * visual(Errorbars)
        mapping(result.gap, result.count) * visual(Lines)
    end
    drawn = figure(plot, select(devices))
    plots(type, drawn=drawn) = [p for p in axis(drawn).scene.plots if p isa type]
    @test sort(Tuple.(reduce(vcat, [p[1][] for p in plots(Scatter)]))) == [(5.0, 2.0), (5.0, 2.0), (10.0, 2.0), (10.0, 2.0)]
    @test length(plots(Errorbars)) == 2
    @test [last.(p[1][]) for p in plots(Lines)] == [[2, 2], [2, 2]]
    plot = @plot mapping(:gap, only(:data.R)) begin
        aggregate(average) * visual(Lines)
    end
    @test Tuple.(only(plots(Lines, figure(plot, select(devices))))[1][]) == [(5.0, 2.0), (10.0, 2.0)]
end

deviation(values) = sqrt(sum(abs2, values .- average(values)) / (length(values) - 1))

@testset "on a log axis, an aggregate takes the logarithms and draws its values back on the axis" begin
    rows = [(x=x, y=y) for x in (1.0, 2.0) for y in (1.0, 100.0)]
    plot = @plot data(rows) * mapping(:x, :y) begin
        result = aggregate(average, deviation)
        mapping(y = result.average) * visual(Lines)
        mapping(result.x, result.average, result.deviation) * visual(Errorbars)
        scales(y = (; scale = log10))
    end
    drawn = figure(plot)
    lines = only(p for p in axis(drawn).scene.plots if p isa Lines)
    @test last.(lines[1][]) ≈ [10.0, 10.0]
    bars = only(p for p in axis(drawn).scene.plots if p isa Errorbars)
    # One standard deviation of the logarithms, √2 decades, on each side of 10.
    @test collect(first(bars[1][])) ≈ [1.0, 10.0, 10.0 - 10^(1 - √2), 10^(1 + √2) - 10.0]
end
