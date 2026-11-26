"""
    InspectorSpec

Settings for hover inspection created by [`inspector`](@ref).
"""
struct InspectorSpec
    show::Bool
    title::Union{Nothing,String}
    fields::Vector{Symbol}
    show_coords::Bool
    digits::Int
    callback::Union{Nothing,Function}
end

"""
    inspector(show::Bool) -> InspectorSpec
    inspector(callback::Function) -> InspectorSpec
    inspector(fields...; show=true, title=nothing, show_coords=true, digits=4) -> InspectorSpec

Configure hover inspection on a `@plot` or composed figure.

- `inspector(false)` hides hover tooltips for the plot.
- `inspector(f)` calls `f(plot, index, position)` to format each tooltip in Julia.
- `inspector(:a, :b; title="Run", show_coords=true, digits=4)` shows coordinates and the
  listed fields in both Makie's inspector and the `WgpuMakie` GPU inspector without calling
  back into Julia on hover.
"""
inspector(show::Bool) = InspectorSpec(show, nothing, Symbol[], true, 4, nothing)

inspector(callback::Function) = InspectorSpec(true, nothing, Symbol[], true, 4, callback)

function inspector(
    fields::Union{Symbol,AbstractString}...;
    show::Bool=true,
    title::Union{Nothing,AbstractString}=nothing,
    show_coords::Bool=true,
    digits::Integer=4,
)
    digits >= 1 || throw(ArgumentError("digits must be at least 1"))
    return InspectorSpec(
        show,
        title === nothing ? nothing : String(title),
        Symbol[Symbol(field) for field in fields],
        show_coords,
        Int(digits),
        nothing,
    )
end

"""
    DeclarativeInspector

Callable tooltip formatter generated from an [`InspectorSpec`](@ref) and layer metadata.
"""
struct DeclarativeInspector
    label::String
    xlabel::String
    ylabel::String
    zlabel::String
    is3d::Bool
    show_coords::Bool
    digits::Int
    fields::Vector{Pair{String,Vector{String}}}
end

function Base.:(==)(a::DeclarativeInspector, b::DeclarativeInspector)
    return a.label == b.label &&
        a.xlabel == b.xlabel &&
        a.ylabel == b.ylabel &&
        a.zlabel == b.zlabel &&
        a.is3d == b.is3d &&
        a.show_coords == b.show_coords &&
        a.digits == b.digits &&
        a.fields == b.fields
end

function (di::DeclarativeInspector)(_plot, index, position)::String
    lines = String[]
    isempty(di.label) || push!(lines, di.label)
    if di.show_coords && length(position) >= 2
        push!(lines, "$(di.xlabel): $(inspected(position[1]; digits=di.digits))")
        push!(lines, "$(di.ylabel): $(inspected(position[2]; digits=di.digits))")
        if di.is3d && length(position) >= 3
            push!(lines, "$(di.zlabel): $(inspected(position[3]; digits=di.digits))")
        end
    end
    for (name, vals) in di.fields
        isempty(vals) && continue
        if length(vals) == 1
            push!(lines, "$name: $(vals[1])")
        elseif 1 <= index <= length(vals)
            push!(lines, "$name: $(vals[index])")
        end
    end
    return join(lines, "\n")
end
