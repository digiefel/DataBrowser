"""
Loading GLMakie makes compiled engine code invalid. This extension compiles it again, and compiles
drawing a registered plot in the browser window, so that a session with plots starts as fast as
one without.

Julia loads another extension while it precompiles this one only if this one lists every package
that the other needs. `Project.toml` therefore lists DataBrowserPlots, CImGui, GLFW and ModernGL
beside GLMakie: the plot windows of DataBrowserPlots and the Makie support of CImGui are then
loaded, as they are in a session, and the code compiled here stays valid there.
"""
module DataBrowserGLMakieExt

using DataBrowser
using DataBrowser: _precompile_engine, _precompile_project
using GLMakie: Axis, Figure, axislegend, cgrad, contents, lines!, linkxaxes!, scatter!
using PrecompileTools: @compile_workload

@compile_workload begin
    project = _precompile_project()
    register_plot!(project, :iv; label="I-V",
        setup=function (_selection)
            figure = Figure()
            current = Axis(figure[1, 1]; ylabel="Current (A)", title="I-V")
            magnitude = Axis(figure[2, 1]; xlabel="Voltage (V)", ylabel="|Current| (A)")
            linkxaxes!(current, magnitude)
            return figure
        end,
        # The calls a plot of a project usually makes: linked axes, a color per item, solid and
        # dashed lines, markers, and a legend.
        draw=function (selection, figure)
            current, magnitude = only(contents(figure[1, 1])), only(contents(figure[2, 1]))
            colors = cgrad(:tab10, length(selection); categorical=true)
            for (index, entry) in enumerate(selection)
                data = entry.data
                lines!(current, data.VoltageHigh_V, data.Current_A;
                    color=colors[index], linewidth=2, label=entry.label)
                scatter!(current, data.VoltageHigh_V, data.Current_A; color=colors[index], markersize=4)
                lines!(magnitude, data.VoltageHigh_V, abs.(data.Current_A);
                    color=colors[index], linestyle=:dash)
            end
            axislegend(current)
            nothing
        end)
    _precompile_engine(project; selected=function (workspace, items)
        plot = only(registered_plots(project, :iv))
        selection = select(workspace, id.(items))
        plot.draw(selection, plot.setup(selection))
    end)
end

end
