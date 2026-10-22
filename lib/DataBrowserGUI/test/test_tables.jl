using Test, DataBrowserGUI
using DataBrowserGUI: merge_item_tables
using DataBrowserCore: Group, select

# Items in memory, each with its data and metadata.
selection_of(entries...) = select([Group(label, Dict{Symbol,Any}(pairs(metadata)), data, []) for (label, data, metadata) in entries])
column(table, name) = [table.getvalue(row, findfirst(==(name), table.columns)) for row in 1:table.rows]

@testset "table union preserves values and item provenance" begin
    table, warnings = merge_item_tables(selection_of(
        ("A", (x=Float32[1, 2], y=[3, 4]), ()), ("B", (y=[5], z=[6]), ())))
    @test isempty(warnings)
    @test isequal(column(table, "x"), [1.0f0, 2.0f0, missing])
    @test column(table, "y") == [3, 4, 5]
    @test isequal(column(table, "z"), [missing, missing, 6])
    @test table.item_labels[table.row_item] == ["A", "A", "B"]
end

@testset "row tables and values that are not tables" begin
    table, _ = merge_item_tables(selection_of(
        ("rows", [(x=1, y=2), (x=3, y=4)], ()),
        ("matrix", [1 2; 3 4], ()),
        ("columns", (y=[5], z=[6]), ())))
    @test table.item_labels[table.row_item] == ["rows", "rows", "matrix", "columns"]
    @test isequal(column(table, "y"), [2, 4, missing, 5])
    # A value that is not a table is one cell beside all of the item's rows.
    @test column(table, "data")[3] == [1 2; 3 4]
    @test table.spans_item(3, findfirst(==("data"), table.columns))
end

@testset "blocks of names fold to one column" begin
    data = (iv=(V=[1, 2],), fit=(slope=2.0, intercept=0.5))
    table, _ = merge_item_tables(selection_of(("A", data, ())))
    @test table.columns == ["iv.V", "fit"]
    @test findfirst(==("fit"), table.columns) in table.groups
    @test table.getcell(1, 2) == "2 fields"

    table, _ = merge_item_tables(selection_of(("A", data, ())); unfolded=Set([["fit"]]))
    @test table.columns == ["iv.V", "fit.slope", "fit.intercept"]
    @test table.paths[2] == ["fit", "slope"]
    @test column(table, "fit.slope") == [2.0, 2.0]
end

@testset "metadata columns beside the items' rows" begin
    table, _ = merge_item_tables(selection_of(
        ("a", (V=[1, 2],), (gap=2,)), ("opaque", nothing, (gap=3,)), ("b", (V=[3],), ()));
        item_column=true, metadata=[:gap])
    @test table.columns == ["item", "gap", "V", "data"]
    @test isequal(column(table, "gap"), [2, 2, 3, missing])
    @test isequal(column(table, "V"), [1, 2, missing, 3])
end
