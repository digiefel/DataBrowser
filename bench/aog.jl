# Run each mode in a fresh process with existing compiled package caches:
# julia --project=bench --threads=auto bench/aog.jl baseline
# julia --project=bench --threads=auto bench/aog.jl aog
# The comparison uses the same data, two graphics, legend placement, and GLMakie renderer.
using TOML, Dates, Statistics

mode = only(ARGS)
mode in ("baseline", "aog") || error("Choose baseline or aog.")
metrics = Dict{String,Any}("mode"=>mode, "julia"=>string(VERSION),
    "date"=>string(now()), "threads"=>Threads.nthreads())

function measure(f, name)
    sample = @timed f()
    metrics[name] = Dict("elapsed_s"=>sample.time, "compile_s"=>sample.compile_time,
        "recompile_s"=>sample.recompile_time, "bytes"=>sample.bytes)
    return sample.value
end

measure("load_makie_and_databrowser") do
    @eval using DataBrowserPlots, GLMakie
end
if mode == "aog"
    measure("load_aog") do
        @eval import AlgebraOfGraphics as AoG
    end
end

metrics["aog_loaded"] = Base.get_extension(DataBrowserPlots, :DataBrowserPlotsAlgebraOfGraphicsExt) !== nothing

x = repeat(collect(range(0, 10; length=500)), 2)
table = (; x, y=vcat(sin.(x[1:500]), cos.(x[1:500])),
    series=repeat(["A", "B"]; inner=500))

if mode == "baseline"
    @eval function build(table; width=2)
        description = DataBrowserPlots.PlotDescription(
            roles=[:x=>:x, :y=>:y, :color=>:series],
            layers=[DataBrowserPlots.Layer(:points),
                DataBrowserPlots.Layer(:lines; fixed=[:linewidth=>width])])
        return DataBrowserPlots.figure(description, table)
    end
    @eval function new_graphic()
        fig = Figure()
        barplot!(Axis(fig[1, 1]), 1:3, [2.0, 4.0, 3.0])
        return fig
    end
else
    @eval function build(table; width=2)
        spec = AoG.data(table) * AoG.mapping(:x, :y; color=:series) *
            (AoG.visual(Scatter) + AoG.visual(Lines; linewidth=width))
        return DataBrowserPlots.figure(spec; legend=(position=:bottom,))
    end
    @eval function new_graphic()
        return DataBrowserPlots.figure(AoG.mapping(1:3, [2.0, 4.0, 3.0]) * AoG.visual(BarPlot))
    end
end

first_figure = measure("first_build") do
    build(table)
end
measure("first_render") do
    GLMakie.colorbuffer(first_figure)
end
measure("first_barplot") do
    GLMakie.colorbuffer(new_graphic())
end

# Warm the edit and data-update calls before taking three samples of each.
build(table; width=3)
function warm_samples(f, name)
    f()
    samples = [@elapsed f() for _ in 1:3]
    metrics[name] = Dict("median_s"=>median(samples), "samples_s"=>samples)
end
warm_samples("style_edit_and_render") do
    GLMakie.colorbuffer(build(table; width=3))
end
warm_samples("data_update_and_render") do
    table.y .+= 0.01
    GLMakie.colorbuffer(build(table))
end

GLMakie.closeall()
TOML.print(stdout, metrics; sorted=true)
