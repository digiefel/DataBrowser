using DataBrowserAnnotations
const Annotations = DataBrowserAnnotations
using Test

const ANNOT_FIXTURES = joinpath(@__DIR__, "fixtures", "annotations")
const ANNOT_MEASUREMENT_KEY = joinpath(
    @__DIR__,
    "fixtures",
    "3V FE PUND [RuO2test_A9_VI_D1(2) ; 2025-10-01 17_12_33].csv",
)

@testset "Annotations" begin

    @testset "Tags" begin
        @testset "missing files" begin
            mktempdir() do dir
                state = Annotations.Tags.load(dir)
                @test isempty(state.catalog)
                @test isempty(state.assignments)
            end
        end

        @testset "parse and roundtrip" begin
            fixture = joinpath(ANNOT_FIXTURES, "tags_full")
            state = Annotations.Tags.load(fixture)
            names = [t.name for t in state.catalog]
            @test "bad" in names && "todo" in names
            bad = state.catalog[findfirst(t -> t.name == "bad", state.catalog)]
            @test bad.color == (0xff, 0x30, 0x30)
            @test bad.priority == 100
            @test "bad" in state.assignments["RuO2test/A9/VI/D1"]
            @test "todo" in state.assignments["RuO2test/A10/VI"]

            mktempdir() do tmp
                Annotations.Tags.save(tmp, state)
                roundtripped = Annotations.Tags.load(tmp)
                @test Set(t.name for t in roundtripped.catalog) ==
                    Set(t.name for t in state.catalog)
                @test roundtripped.assignments == state.assignments
            end
        end

        @testset "generated item keys keep suffix fragments" begin
            mktempdir() do dir
                key = ANNOT_MEASUREMENT_KEY * "#cycle=10000000"
                write(joinpath(dir, "tags.txt"),
                    """
                    # sample generated tags file
                    [catalog]
                    bad\t#ff3030\t100

                    [assignments]
                    $key\tbad
                    """)
                state = Annotations.Tags.load(dir)
                @test state.catalog[1].color == (0xff, 0x30, 0x30)
                @test state.assignments[key] == Set(["bad"])
            end
        end

        @testset "malformed assignment row raises error" begin
            mktempdir() do dir
                write(joinpath(dir, "tags.txt"),
                    "[catalog]\nbad\tff3030\t100\n\n[assignments]\nonlyone\n")
                @test_throws Annotations.Tags.TagsParseError Annotations.Tags.load(dir)
            end
        end
    end

    @testset "Notes" begin
        @testset "round-trip with bracketed body content" begin
            fixture = joinpath(ANNOT_FIXTURES, "notes_basic")
            chipB = Annotations.Notes.read_section(fixture, "ChipB")
            @test occursin("Oxygen flow", chipB)
            site = Annotations.Notes.read_section(fixture, "ChipB/SiteVI")
            @test occursin("[observed in second pass]", site)
            @test occursin("dust particle", site)
            @test Annotations.Notes.read_section(fixture, "Missing/Path") == ""
        end

        @testset "merged_view ordering and editable flags" begin
            fixture = joinpath(ANNOT_FIXTURES, "notes_basic")
            view = Annotations.Notes.merged_view(fixture, "ChipB/SiteVI", ["ChipB"])
            @test length(view) == 2
            @test view[1].path == "ChipB"
            @test view[1].editable == false
            @test view[2].path == "ChipB/SiteVI"
            @test view[2].editable == true
        end

        @testset "missing notes file" begin
            mktempdir() do dir
                @test Annotations.Notes.read_section(dir, "Anything") == ""
                view = Annotations.Notes.merged_view(dir, "ChipA", ["Root"])
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

                Annotations.Notes.write_section!(dir, "ChipB", "Updated body\n")
                @test Annotations.Notes.read_section(dir, "ChipB") == "Updated body"
                # other section preserved
                @test occursin("dust particle",
                    Annotations.Notes.read_section(dir, "ChipB/SiteVI"))

                # New section appended
                Annotations.Notes.write_section!(dir, "ChipC", "fresh note")
                @test Annotations.Notes.read_section(dir, "ChipC") == "fresh note"
                @test Annotations.Notes.read_section(dir, "ChipB") == "Updated body"
            end
        end
    end

end
