using Test
import DataBrowserAPI
using DataBrowserSources: DirectorySource

module ErrorReportFixture
    include_string(@__MODULE__, "fail(data) = error(\"bad plot\")", "/project/tlm.jl")
    include_string(@__MODULE__, "draw(data) = fail(data)", "/lib/DataBrowserPlots/src/plots.jl")
end

@testset "concise errors retain the callback location and full details" begin
    error, bt = try
        ErrorReportFixture.draw([(x=1,)])
    catch error
        (error, catch_backtrace())
    end
    summary = DataBrowserAPI.error_summary(error, bt)
    @test occursin("bad plot", summary)
    @test occursin("/project/tlm.jl:1", summary)
    @test occursin("fail", summary)
    @test !occursin("NamedTuple", summary)
    @test !occursin("test_errors.jl", summary)
    report = @test_logs (:error, r"Plot drawing failed") (:debug, "Plot drawing failed") min_level=Base.CoreLogging.Debug DataBrowserAPI.report_error(
        "Plot drawing failed", error, bt; details="sample.csv#csv:1")
    @test occursin("test_errors.jl", report[2])
    @test occursin("sample.csv#csv:1", report[2])
    @test DataBrowserAPI.source_description(DirectorySource("exp_raw")) == "DirectorySource(\"exp_raw\")"
end
