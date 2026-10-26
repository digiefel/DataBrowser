import CImGui as ig

import DataBrowserAPI: draw!, label, prepare!
using DataBrowserAPI: AbstractVisualizer
using DataBrowserCore: Workspace
using .Workspace: Call

# One row of the timeline: a call, and the lines that pass through the row. Lines run in columns
# at the left; a line carries the result of a call down to the calls that read it.
struct CodeRow
    call::Call
    column::Int
    # The columns whose lines come from above into this call: one for each input.
    from::Vector{Int}
    # The columns whose lines pass through the row, with results that later rows read.
    through::Vector{Int}
    # Whether the line of this call goes on down, to later calls that read its result.
    down::Bool
    # The text of the method's docstring, shown when the title is hovered.
    docstring::String
end

"""
The visualizer that shows the code that made a selection of items, as a timeline: the first call
at the top and the last at the bottom. Each row names a function, where its code is, and the
number of items that went through it; items made by the same code share a row. Lines join each
call to the calls that read its result, and ↗ opens the code in the editor.
"""
Base.@kwdef mutable struct CodeView <: AbstractVisualizer
    rows::Vector{CodeRow} = CodeRow[]
    columns::Int = 0
end

label(::CodeView)::String = "Code"

function prepare!(view::CodeView, selection::Workspace.Selection, ctx)::Nothing
    last_calls = Workspace.calls(ctx.workspace, selection.id)
    # Each call comes after the calls whose results it reads.
    order, seen = Call[], Set{Call}()
    visit(call) = call in seen || (push!(seen, call); foreach(visit, call.inputs); push!(order, call))
    foreach(visit, last_calls)
    readers = Dict{Call,Int}(call => 0 for call in order)
    for call in order, input in call.inputs
        readers[input] += 1
    end
    # Each column holds the call whose result runs down it, until its last reader takes it.
    columns, rows = Union{Call,Nothing}[], CodeRow[]
    for call in order
        before = copy(columns)
        from = [findfirst(==(input), columns) for input in call.inputs]
        for input in call.inputs
            readers[input] -= 1
            readers[input] == 0 && (columns[findfirst(==(input), columns)] = nothing)
        end
        # A call goes on in the column of its first input when that column is free.
        column = !isempty(from) && columns[from[1]] === nothing ? from[1] :
            something(findfirst(isnothing, columns), length(columns) + 1)
        column > length(columns) && push!(columns, nothing)
        readers[call] > 0 && (columns[column] = call)
        through = [index for index in eachindex(before) if before[index] !== nothing && before[index] === columns[index]]
        push!(rows, CodeRow(call, column, from, through, readers[call] > 0, docstring(call.code)))
    end
    view.rows, view.columns = rows, length(columns)
    return nothing
end

# The docstring of the method itself, without those of the other methods of its function.
function docstring(code)::String
    code isa Method || return ""
    f = Base.unwrap_unionall(code.sig).parameters[1]
    isdefined(f, :instance) || return ""
    binding = Docs.Binding(parentmodule(f.instance), nameof(f.instance))
    found = get(Docs.meta(code.module), binding, nothing)
    found === nothing && return ""
    doc = get(found.docs, Base.tuple_type_tail(code.sig), nothing)
    return doc === nothing ? "" : join(doc.text)
end

function draw!(view::CodeView, ctx)::Nothing
    draw_list = ig.GetWindowDrawList()
    line, dot = ig.GetColorU32(ig.ImGuiCol_Text, 0.4f0), ig.GetColorU32(ig.ImGuiCol_Text)
    width, height = ig.GetFontSize(), ig.GetFrameHeightWithSpacing()
    for (index, row) in enumerate(view.rows)
        ig.PushID(index)
        corner = ig.GetCursorScreenPos()
        x(column) = corner.x + (column - 0.5f0) * width
        top, middle, bottom = corner.y, corner.y + height / 2, corner.y + height
        for column in row.through
            ig.AddLine(draw_list, ig.ImVec2(x(column), top), ig.ImVec2(x(column), bottom), line, 1.5f0)
        end
        for column in row.from
            ig.AddLine(draw_list, ig.ImVec2(x(column), top), ig.ImVec2(x(row.column), middle), line, 1.5f0)
        end
        row.down && ig.AddLine(draw_list, ig.ImVec2(x(row.column), middle), ig.ImVec2(x(row.column), bottom), line, 1.5f0)
        ig.AddCircleFilled(draw_list, ig.ImVec2(x(row.column), middle), width / 4, dot)
        ig.Dummy(ig.ImVec2(view.columns * width, ig.GetFrameHeight()))

        ig.SameLine()
        ig.AlignTextToFramePadding()
        with_font(:code) do
            ig.TextUnformatted(row.call.title)
        end
        !isempty(row.docstring) && ig.IsItemHovered() && ig.SetTooltip(row.docstring)
        # The count shows where it changes: at a first call, and where a call makes fewer or more
        # items than the call before it.
        call = row.call
        if isempty(call.inputs) || call.count != first(call.inputs).count
            ig.SameLine()
            ig.TextDisabled("$(call.count)×")
        end
        code = call.code
        if code !== nothing
            ig.SameLine()
            ig.TextDisabled("$(basename(string(code.file))):$(code.line)")
            ig.IsItemHovered() && ig.SetTooltip(string(code.file))
            ig.SameLine()
            # An editor in the terminal waits until it is closed, so it opens apart from the frame.
            ig.SmallButton("↗") && errormonitor(Threads.@spawn Workspace.InteractiveUtils.edit(call))
        end
        ig.PopID()
    end
    return nothing
end
