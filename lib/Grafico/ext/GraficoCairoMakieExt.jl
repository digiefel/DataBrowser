module GraficoCairoMakieExt

using Grafico, CairoMakie
import Makie
save_still(path, figure) = Makie.save(path, figure; backend = CairoMakie)

end
