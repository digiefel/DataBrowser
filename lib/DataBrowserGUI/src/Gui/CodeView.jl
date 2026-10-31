import CImGui as ig

import DataBrowserAPI: draw!, label, prepare!, output, select!, selection
using DataBrowserAPI: Computation, cache_info, last_execution
using Printf: @sprintf
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
call to the calls that read its result, and ↗ opens the code in the editor. Select a row to see
its execution and cache information below the list. The computations of the selected row are the
output of the window, so a window that takes this window as input shows their results.
"""
Base.@kwdef mutable struct CodeView <: AbstractVisualizer
    rows::Vector{CodeRow} = CodeRow[]
    columns::Int = 0
    selected::Int = 0
    output::Vector{Computation} = Computation[]
end

label(::CodeView)::String = "Code"
output(view::CodeView) = view.output

"""
    select!(view::CodeView; row)

Select the row number `row` of the code view, counted from the top. Its computations become the
output of the view, without being evaluated.
"""
function select!(view::CodeView; row::Integer)::Nothing
    if isempty(view.rows)
        # `prepare!` selects the row when the rows arrive.
        view.selected = row
        return nothing
    end
    checkbounds(view.rows, row)
    view.selected = row
    call = view.rows[row].call
    next = Computation[call.computations[id] for id in sort!(collect(keys(call.computations)))]
    length(next) == length(view.output) && all(a === b for (a, b) in zip(next, view.output)) ||
        (view.output = next)
    return nothing
end

"""
    selection(view::CodeView) -> (; row)

The number of the selected row, counted from the top.
"""
selection(view::CodeView) = (row=view.selected,)

# The selected row stays on the same call when the items or their code change.
function call_identity(call::Call)
    code = call.code isa Method ? call.code.sig : call.code isa LineNumberNode ? call.code.file : nothing
    return (call.title, code, map(call_identity, call.inputs))
end

function prepare!(view::CodeView, selection::Workspace.Selection, ctx)::Nothing
    previous = 1 <= view.selected <= length(view.rows) ? call_identity(view.rows[view.selected].call) : nothing
    last_calls = Workspace.calls(ctx.workspace, selection)
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
    if isempty(rows)
        view.selected = 0
        isempty(view.output) || (view.output = Computation[])
    else
        selected = findfirst(row -> call_identity(row.call) == previous, rows)
        # A row selected before the first rows arrived keeps its number.
        previous === nothing && 1 <= view.selected <= length(rows) && (selected = view.selected)
        select!(view; row=something(selected, length(rows)))
    end
    return nothing
end

# Lines for a tooltip, cut after the first 30.
listed(lines::Vector{String})::String =
    join(first(lines, 30), '\n') * (length(lines) > 30 ? "\n… and $(length(lines) - 30) more" : "")

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
    line, dot = ig.GetColorU32(ig.ImGuiCol_Text, 0.4f0), ig.GetColorU32(ig.ImGuiCol_Text)
    width, height = ig.GetFontSize(), ig.GetFrameHeightWithSpacing()
    available = ig.GetContentRegionAvail()
    if ig.BeginChild("##calls", ig.ImVec2(0, max(height, 0.58f0 * available.y)))
        draw_list = ig.GetWindowDrawList()
        for (index, row) in enumerate(view.rows)
            ig.PushID(index)
            corner = ig.GetCursorScreenPos()
            ig.Selectable("##step", index == view.selected, ig.ImGuiSelectableFlags_AllowOverlap,
                ig.ImVec2(0, ig.GetFrameHeight())) && select!(view; row=index)
            ig.SetCursorScreenPos(corner)
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
            call = row.call
            # What it ran for: the item itself when there is one, the labels of the items when hovered.
            ig.SameLine()
            if length(call.items) == 1
                # A long label, such as a path, is cut in the middle and shown whole when hovered.
                name = only(values(call.items))
                ig.TextUnformatted(length(name) > 40 ? first(name, 15) * "…" * last(name, 24) : name)
                length(name) > 40 && ig.IsItemHovered() && ig.SetTooltip(first(name, 2000))
            else
                ig.TextUnformatted("$(length(call.items)) items")
                ig.IsItemHovered() && ig.SetTooltip(listed(sort!(collect(values(call.items)))))
            end
            # TODO: a window leaves out its failed items, so they reach this view only through `calls`.
            if !isempty(call.failed)
                ig.SameLine()
                ig.TextColored(ig.ImVec4(0.95f0, 0.45f0, 0.4f0, 1.0f0), "$(length(call.failed)) failed")
                ig.IsItemHovered() && ig.SetTooltip(listed(sort!(["$(call.items[id]): $error" for (id, error) in call.failed])))
            end
            if call.result !== nothing
                ig.SameLine()
                ig.TextDisabled("→ $(call.result)")
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
    end
    ig.EndChild()
    ig.Separator()
    if ig.BeginChild("##call_information", ig.ImVec2(0, 0))
        if view.selected == 0
            ig.TextDisabled("No calls")
        else
            call = view.rows[view.selected].call
            for id in sort!(collect(keys(call.computations)))
                length(call.computations) > 1 && ig.TextUnformatted(call.items[id])
                value = call.computations[id]
                cached = cache_info(ctx.workspace, value)
                size = cached.bytes === nothing ? "" : " ($(Base.format_bytes(cached.bytes)))"
                ig.TextUnformatted("Cached: $(cached.cached ? "yes" : "no")$size")
                execution = last_execution(ctx.workspace, value)
                if execution === nothing
                    ig.TextDisabled("Last execution: unavailable")
                else
                    duration = execution.duration < 1 ? @sprintf("%.3g ms", 1000execution.duration) :
                        @sprintf("%.3g s", execution.duration)
                    date = replace(string(execution.finished_at), 'T' => ' ')
                    ig.TextUnformatted("Last execution: $duration ($date)")
                    ig.SetItemTooltip("The time the call took, with the compilation of its first run and waits for other Julia work, but without evaluating its inputs or storing its result.")
                    execution.succeeded || ig.TextUnformatted("Execution failed")
                end
                failure = get(call.failed, id, nothing)
                if failure !== nothing
                    ig.PushTextWrapPos(0)
                    ig.TextUnformatted(failure)
                    ig.PopTextWrapPos()
                end
                length(call.computations) > 1 && ig.Spacing()
            end
        end
    end
    ig.EndChild()
    return nothing
end
