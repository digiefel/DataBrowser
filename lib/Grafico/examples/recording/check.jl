module GraficoRecordingChecks

using Test
include("generic.jl")

extension = Base.get_extension(Grafico, :GraficoWGLMakieExt)
scenes, _ = extension.scene_objects(fig.scene)
observer_counts(scene) = (
    length(scene.deregister_callbacks),
    length(Makie.Observables.listeners(scene.compute.onchange)),
)
Grafico.seek!(story, 0.63)
original = (phase[], shown[], window[], colour[], story.time[])
previous_backend = Makie.current_backend()
before = observer_counts.(scenes)

record(fig, joinpath(output, "native.html"), story;
       still = joinpath(output, "final.svg"))

@test (phase[], shown[], window[], colour[], story.time[]) == original
@test Makie.current_backend() === previous_backend
@test observer_counts.(scenes) == before
@test all(scene -> all(screen -> !(screen isa WGLMakie.Screen), scene.current_screens), scenes)
@test isfile(joinpath(output, "native.html"))
@test isfile(joinpath(output, "final.svg"))
println("GRAFICO_RECORDING_CHECKED state_restored=true observer_cleanup=true")

end
