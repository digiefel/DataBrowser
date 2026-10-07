"""
Loading GLMakie makes compiled engine code invalid. This extension compiles it again, and compiles
drawing a registered plot, so that a session with plots starts as fast as one without.
"""
module DataBrowserGLMakieExt

using DataBrowser
using DataBrowser: _precompile_engine, _precompile_project
using DataBrowser.DataBrowserPlots: PlotRecipe, _plot_recipes
using GLMakie: Axis, Figure, contents, lines!
using PrecompileTools: @compile_workload

@compile_workload begin
    project = _precompile_project()
    # `register_plot!` has no method here: Julia does not load the extension of DataBrowserPlots
    # that defines it while it precompiles this extension.
    _plot_recipes(project)[:iv] = Dict("I-V" => PlotRecipe(:iv, "I-V",
        (_workspace, _items) -> (figure = Figure(); Axis(figure[1, 1]); figure),
        function (_workspace, items, figure)
            axis = only(contents(figure[1, 1]))
            foreach(item -> lines!(axis, item_data(item).VoltageHigh_V, item_data(item).Current_A), items)
            nothing
        end))
    _precompile_engine(project; selected=function (workspace, items)
        plot_kind = only(registered_plot_kinds(project, :iv))
        plot_data!(workspace, plot_kind, items, setup_plot(workspace, plot_kind, items))
    end)
end

end
