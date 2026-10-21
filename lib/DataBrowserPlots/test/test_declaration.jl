using DataBrowserPlots: @plot

@testset "@plot multiplies each line by the header and adds the lines" begin
    @test @plot(2, begin
        3
        4 *
            5
    end) == 2 * (3 + 4 * 5)
    @test @plot(2, begin end) == 2
    @test @plot(2, begin
        3
    end) == 2 * 3
end
