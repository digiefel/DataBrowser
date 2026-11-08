# Lay out axis text on a worker thread, as the plot warmup does, while Julia exits.
using GLMakie
const figures = Threads.Atomic{Int}(0)
Threads.@spawn :default while true
    figure = Figure()
    Axis(figure[1, 1]; title="warmup", xlabel="x", ylabel="y")
    Threads.atomic_add!(figures, 1)
end
while figures[] < 3
    sleep(0.1)
end
exit()
