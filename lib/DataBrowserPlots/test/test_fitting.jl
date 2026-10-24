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
