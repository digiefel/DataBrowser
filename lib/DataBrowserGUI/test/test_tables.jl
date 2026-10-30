using Test, DataBrowserGUI
import DataBrowserAPI
using DataBrowserGUI: merge_item_tables, value_table, zoom_value
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

@testset "row tables, matrices and values that are not tables" begin
    table, _ = merge_item_tables(selection_of(
        ("rows", [(x=1, y=2), (x=3, y=4)], ()),
        ("matrix", [1 2; 3 4], ()),
        ("text", "seven", ()),
        ("columns", (y=[5], z=[6]), ())))
    @test table.item_labels[table.row_item] == ["rows", "rows", "matrix", "matrix", "text", "columns"]
    @test isequal(column(table, "y"), [2, 4, missing, missing, missing, 5])
    @test isequal(column(table, "2"), [missing, missing, 2, 4, missing, missing])
    # A value that is not a table is one cell beside all of the item's rows.
    @test column(table, "data")[5] == "seven"
    @test table.spans_item(5, findfirst(==("data"), table.columns))
end

@testset "zooming into a cell" begin
    data = (iv=(V=[1, 2], trace=[[1, 2], [3, 4, 5]]), fit=(slope=2.0, map=[1 2; 3 4]))
    @test something(zoom_value(data, 2, ["iv", "trace"])) == [3, 4, 5]
    map = something(zoom_value(data, 0, ["fit", "map"]))
    @test something(zoom_value(map, 2, ["1"])) == 3
    @test zoom_value(data, 0, ["fit", "missing"]) === nothing
    table = value_table("A", map)
    @test table.columns == ["1", "2"]
    @test column(table, "2") == [2, 4]
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
    # The metadata comes first, also when the first item lacks it.
    table, _ = merge_item_tables(selection_of(
        ("b", (V=[3],), ()), ("a", (V=[1, 2],), (gap=2,)), ("opaque", nothing, (gap=3,)));
        item_column=true, metadata=[:gap])
    @test table.columns == ["item", "gap", "V", "data"]
    @test isequal(column(table, "gap"), [missing, 2, 2, 3])
    @test isequal(column(table, "V"), [3, 1, 2, missing])
end

@testset "a table cut to some rows and columns" begin
    table, _ = merge_item_tables(selection_of(("A", (x=[1, 2], y=[3, 4], z=[5, 6]), ())))
    cut = table[[2], [3, 1]]
    @test cut.columns == ["z", "x"]
    @test cut.getvalue(1, 1) == 6 && cut.getvalue(1, 2) == 2
end

@testset "column choices survive unavailable columns and explicit choices replace them" begin
    first = selection_of(("A", (V=[1.,2.], I=[3.,4.]), ()))
    missing = selection_of(("B", (V=[5.],), ()))
    returned = selection_of(("C", (I=[6.], V=[7.]), ()))
    view = only(filter(v -> DataBrowserAPI.label(v) == "Table", DataBrowserGUI.Browser.visualizers(typeof(first))))
    DataBrowserAPI.prepare!(view, first, nothing)
    select_columns!(view, ["I"])
    @test selected_columns(view; available=true) == ["I"]
    DataBrowserAPI.prepare!(view, missing, nothing)
    @test selected_columns(view) == ["I"]
    @test isempty(selected_columns(view; available=true))
    DataBrowserAPI.prepare!(view, returned, nothing)
    @test selected_columns(view; available=true) == ["I"]
    DataBrowserAPI.prepare!(view, missing, nothing)
    select_columns!(view, ["V"])
    DataBrowserAPI.prepare!(view, returned, nothing)
    @test selected_columns(view) == ["V"]
    @test selected_columns(view; available=true) == ["V"]
    select_columns!(view, String[])
    DataBrowserAPI.prepare!(view, first, nothing)
    @test isempty(selected_columns(view))
    @test isempty(selected_columns(view; available=true))
end

@testset "dictionary columns use their values rather than their declared Any type" begin
    table, warnings = merge_item_tables(selection_of(("stats", Dict{Symbol,Any}(:charge => [1.,2.,3.]), ())))
    @test isempty(warnings)
    @test table.rows == 3
    @test column(table, "charge") == [1., 2., 3.]
end
