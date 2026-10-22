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
DataBrowserAPI.metadata(device::FitTestDevice) = Dict{Symbol,Any}(:Chip => device.chip, :gap => device.gap)
DataBrowserAPI.item_data(device::FitTestDevice) = (R=[device.R],)

texts(drawn) = sort([t for p in only(filter(c -> c isa Axis, drawn.content)).scene.plots if p isa Makie.Text for t in p.text[]])

@testset "a fit gives a group for each chip, and lines draw the groups" begin
    # Two chips with exact lines: R = 2 * 300 + 100 * gap and R = 2 * 50 + 100 * gap.
    devices = [FitTestDevice("$chip$gap", chip, gap, 2Rc + 100gap)
        for (chip, Rc) in (("A", 300), ("B", 50)) for gap in (5.0, 10.0, 20.0)]
    plot = @plot mapping(:gap, only(:data.R); color=:Chip) begin
        visual(Scatter)
        contacts = fit(resistance, (Rc=1.0, Rsh=1.0))
        data(contacts) * mapping(:data.x, :data.y; color=:Chip) * visual(Lines)
        data(contacts) * mapping(last(:data.x), last(:data.y);
            text=string(:Chip, ": ", round(estimate(:Rc))) => verbatim) * visual(Makie.Text)
    end
    @test texts(figure(plot, select(devices))) == ["A: 300.0", "B: 50.0"]
end

@testset "a fit takes the rows of the header's own table" begin
    rows = [(gap=g, R=2 * 300 + 100g) for g in (5.0, 10.0, 20.0)]
    plot = @plot data(rows) * mapping(:gap, :R) begin
        contacts = fit(resistance, (Rc=1.0, Rsh=1.0))
        data(contacts) * mapping(last(:data.x), last(:data.y); text=string(round(estimate(:Rc))) => verbatim) *
            visual(Makie.Text)
    end
    @test texts(figure(plot)) == ["300.0"]
end
