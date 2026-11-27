using WgpuMakie

fig = Figure(size = (960, 480))

ax1 = Axis(fig[1, 1]; title = "Heatmap", xlabel = "x", ylabel = "y")
xs = range(-2, 2; length = 80)
ys = range(-2, 2; length = 60)
mat = [exp(-(x^2 + y^2)) * cos(3x) for x in xs, y in ys]
hm = heatmap!(ax1, xs, ys, mat; colormap = :inferno)
Colorbar(fig[1, 2], hm)

ax2 = Axis(fig[1, 3]; title = "RGBA Image", aspect = DataAspect())
img = [RGBAf(i / 64, j / 64, 0.5f0, 1.0f0) for i in 1:64, j in 1:64]
image!(ax2, img)

screen = display(fig)
isinteractive() || wait(screen)
