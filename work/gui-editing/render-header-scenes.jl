module HeaderSceneRender
import AlgebraOfGraphics as AoG
import Makie
import CairoMakie
using Main.FitCaptureProbe: @plot
using Makie: Scatter, Text

function render()
    x = repeat(collect(1.0:6.0),2)
    y = [3.2,4.7,7.1,9.1,10.7,13.2,3.38,3.16,2.46,1.96,1.66,.88]
    series = repeat(["A","B"];inner=6)
    global table = (;x,y,series)
    tlm_y = [8.2,9.7,12.1,14.1,15.7,18.2,13.8,14.8,19.4,22.4,23.8,28.8]
    global measurements = (;gap_um=vcat(x,x),R_ohm=vcat(tlm_y,tlm_y.+2),chip=vcat(series,series),site=repeat(["Site 1","Site 2"];inner=12))
    # These files are the exact source displayed by the editor mockups.
    generic = Base.include(@__MODULE__,joinpath(@__DIR__,"header-generic-source.jl"))
    tlm = Base.include(@__MODULE__,joinpath(@__DIR__,"header-tlm-source.jl"))
    figures = Makie.with_theme(Makie.theme_dark()) do
        palette = AoG.scales(Color=(;palette=["#87a9d2","#d7ad78"]))
        common=(;figure=(;size=(720,390),backgroundcolor="#14171b"),
            axis=(;backgroundcolor="#14171b",xautolimitmargin=(.05,.6),yautolimitmargin=(.1,.1)),
            legend=(;position=:top,titleposition=:left))
        (AoG.draw(generic.specification,palette;common...),AoG.draw(tlm.specification,palette;common...))
    end
    for (name,figure) in zip(("fit-generic-native.png","fit-tlm-native.png"),figures)
        CairoMakie.save(joinpath(@__DIR__,name),figure.figure;px_per_unit=2)
    end
    @assert generic.fit_calls==2 && tlm.fit_calls==6
    println("Exact displayed source rendered. Generic: 2 models. Synthetic TLM: 6 models, two facets.")
    nothing
end
end
