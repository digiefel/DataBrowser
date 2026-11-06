using DataBrowserAnnotations: Tags, Notes
using Test

const ANNOT_FIXTURES = joinpath(@__DIR__, "fixtures", "annotations")

@testset "Annotations" begin

    @testset "Tags" begin
        @testset "missing files" begin
            mktempdir() do dir
                state = Tags.load(dir, "P")
                @test isempty(state.catalog)
                @test isempty(state.assignments)
            end
        end

        @testset "parse and roundtrip" begin
            fixture = joinpath(ANNOT_FIXTURES, "tags_full")
            state = Tags.load(fixture, "RuO2 test")
            names = [t.name for t in state.catalog]
            @test "bad" in names && "todo" in names
            bad = state.catalog[findfirst(t -> t.name == "bad", state.catalog)]
            @test bad.color == (0xff, 0x30, 0x30)
            @test bad.priority == 100
            @test "bad" in state.assignments["RuO2test/A9/VI/D1"]
            @test "todo" in state.assignments["RuO2test/A10/VI"]

            mktempdir() do tmp
                Tags.save(tmp, "RuO2 test", state)
                roundtripped = Tags.load(tmp, "RuO2 test")
                @test Set(t.name for t in roundtripped.catalog) ==
                    Set(t.name for t in state.catalog)
                @test roundtripped.assignments == state.assignments
            end
        end

        @testset "each project keeps its own tags" begin
            mktempdir() do dir
                Tags.save(dir, "A", Tags.TagState([Tags.Tag("bad")], Dict("x" => Set(["bad"]))))
                Tags.save(dir, "B", Tags.TagState([Tags.Tag("todo")], Dict{String,Set{String}}()))
                @test [t.name for t in Tags.load(dir, "A").catalog] == ["bad"]
                @test [t.name for t in Tags.load(dir, "B").catalog] == ["todo"]
                Tags.save(dir, "A", Tags.TagState())
                @test isempty(Tags.load(dir, "A").catalog)
                @test [t.name for t in Tags.load(dir, "B").catalog] == ["todo"]
                Tags.save(dir, "B", Tags.TagState())
                @test !isfile(Tags.tags_path(dir))
            end
        end

        @testset "item ids keep spaces, brackets and suffixes" begin
            mktempdir() do dir
                key = "A9/VI/3V FE PUND [D1(2) ; 2025-10-01 17_12_33].csv#cycle=10000000"
                write(joinpath(dir, "tags.txt"),
                    """
                    # sample generated tags file
                    [P catalog]
                    bad\t#ff3030\t100

                    [P assignments]
                    $key\tbad
                    """)
                state = Tags.load(dir, "P")
                @test state.catalog[1].color == (0xff, 0x30, 0x30)
                @test state.assignments[key] == Set(["bad"])
            end
        end

        @testset "malformed rows raise an error" begin
            mktempdir() do dir
                ## A malformed row of another project also raises.
                write(joinpath(dir, "tags.txt"),
                    "[A catalog]\nbad\tff3030\t100\n\n[B assignments]\nonlyone\n")
                @test_throws Tags.TagsParseError Tags.load(dir, "A")
                write(joinpath(dir, "tags.txt"), "[A catalog]\nbad\tred\t100\n")
                @test_throws Tags.TagsParseError Tags.load(dir, "A")
            end
        end
    end

    @testset "Notes" begin
        @testset "reading notes preserves bracketed body content" begin
            fixture = joinpath(ANNOT_FIXTURES, "notes_basic")
            chipB = Notes.read_section(fixture, "ChipB")
            @test occursin("Oxygen flow", chipB)
            site = Notes.read_section(fixture, "ChipB/SiteVI")
            @test occursin("[observed in second pass]", site)
            @test occursin("dust particle", site)
            @test Notes.read_section(fixture, "Missing/Path") == ""
        end

        @testset "merged_view ordering and editable flags" begin
            fixture = joinpath(ANNOT_FIXTURES, "notes_basic")
            view = Notes.merged_view(fixture, "ChipB/SiteVI", ["ChipB"])
            @test length(view) == 2
            @test view[1].path == "ChipB"
            @test view[1].editable == false
            @test view[2].path == "ChipB/SiteVI"
            @test view[2].editable == true
        end

        @testset "missing notes file" begin
            mktempdir() do dir
                @test Notes.read_section(dir, "Anything") == ""
                view = Notes.merged_view(dir, "ChipA", ["Root"])
                @test length(view) == 1
                @test view[1].path == "ChipA"
                @test view[1].body == ""
                @test view[1].editable == true
            end
        end

        @testset "write_section! preserves and inserts" begin
            mktempdir() do dir
                src = joinpath(ANNOT_FIXTURES, "notes_basic", "notes.txt")
                cp(src, joinpath(dir, "notes.txt"))

                Notes.write_section!(dir, "ChipB", "Updated body\n")
                @test Notes.read_section(dir, "ChipB") == "Updated body"
                # other section preserved
                @test occursin("dust particle", Notes.read_section(dir, "ChipB/SiteVI"))

                # New section appended
                Notes.write_section!(dir, "ChipC", "fresh note")
                @test Notes.read_section(dir, "ChipC") == "fresh note"
                @test Notes.read_section(dir, "ChipB") == "Updated body"
            end
        end
    end

end
