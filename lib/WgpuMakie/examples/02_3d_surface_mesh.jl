using WgpuMakie
using GeometryBasics

fig = Figure(size = (900, 650))
ax = Axis3(fig[1, 1]; title = "3D Surface, Mesh & MeshScatter", aspect = :data)

xs = range(-3, 3; length = 60)
ys = range(-3, 3; length = 60)
zs = [sin(x) * cos(y) * exp(-0.1 * (x^2 + y^2)) for x in xs, y in ys]
surface!(ax, xs, ys, zs; colormap = :plasma, shading = true)

sphere = GeometryBasics.Sphere(Point3f(0, 0, 1.3), 0.45f0)
mesh!(ax, sphere; color = :steelblue, shading = true)

pts = [Point3f(2.2 * cos(t), 2.2 * sin(t), 0.8 + 0.3 * sin(2t)) for t in range(0, 2π; length = 13)[1:12]]
meshscatter!(ax, pts; markersize = 0.18, color = 1:length(pts), colormap = :turbo)

screen = display(fig)
isinteractive() || wait(screen)
