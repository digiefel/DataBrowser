using Test, DataBrowserGUI
using DataBrowserGUI: edit!, ischanged_on_disk, isunsaved, load!, save!

@testset "a code file keeps the user's text around an edit, and notices another editor" begin
    mktempdir() do dir
        code = CodeFile(joinpath(dir, "plot.jl"))
        code.text = "@plot mapping(:x, :y) begin  # points\n    visual(Scatter)\nend\n"
        save!(code)
        # Insert before `visual`.
        line = findfirst("visual", code.text)
        edit!(code, first(line):first(line)-1, "@invisible ")
        @test code.text == "@plot mapping(:x, :y) begin  # points\n    @invisible visual(Scatter)\nend\n"
        @test isunsaved(code)
        save!(code)
        @test read(code.path, String) == code.text
        sleep(0.01)
        write(code.path, "changed elsewhere")
        @test ischanged_on_disk(code)
        @test load!(code).text == "changed elsewhere"
    end
end
