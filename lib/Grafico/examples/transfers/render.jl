output_dir = joinpath(@__DIR__, "output")
mkpath(output_dir)

# A small contact sheet makes the actual intermediate states inspectable.
for (name, p) in (("start", 0.0), ("flight", 0.35), ("comparison", 0.55), ("final", 1.0))
    Grafico.seek!(playback, 0.6 + 6.0 * p)
    save(joinpath(output_dir, "$name.png"), probe_figure; px_per_unit = 1)
end
save(joinpath(output_dir, "final.svg"), probe_figure)
save(joinpath(output_dir, "final.pdf"), probe_figure)

open(joinpath(output_dir, "sampled_counts.csv"), "w") do io
    println(io, "progress,arrived,exposed_output_count,pre_stat_counts,post_stat_counts")
    for p in (0.0, 0.2, 0.35, 0.55, 0.8, 1.0)
        sampled = sample_transfer(plan, p)
        exposed = sample_output_exposure(plan, p)
        println(io, "$p,$(sum(sampled.counts)),$(sum(exposed)),\"$(join(sampled.counts, ';'))\",\"$(join(exposed, ';'))\"")
    end
end

timeline = range(0.0, playback.seconds; length = round(Int, 30 * playback.seconds) + 1)
record(probe_figure, joinpath(output_dir, "sample_flights.mp4"), timeline; framerate = 30) do p
    Grafico.seek!(playback, p)
end
println("Temporal grammar probe artifacts: ", output_dir)
