"""Prepare application startup after both optional plotting packages have loaded."""
module DataBrowserGLMakieAlgebraOfGraphicsExt

using DataBrowser
using DataBrowser: _precompile_engine
using AlgebraOfGraphics
using GLMakie
using PrecompileTools: @compile_workload

@compile_workload begin
    _precompile_engine()
    project = define_project("CSV startup")
    register_csv!(project)
    _precompile_engine(project)
end

end
