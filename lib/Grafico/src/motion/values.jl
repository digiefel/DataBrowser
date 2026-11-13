# Value operations shared by native motion sampling and browser export.
_motion_ease(u) = (u = clamp(u, 0, 1); u^3 * (10 + u * (-15 + 6u)))

_motion_copy(value) = value
_motion_copy(value::Tuple) = map(_motion_copy, value)
_motion_copy(value::NamedTuple) = map(_motion_copy, value)
_motion_copy(value::AbstractArray) = map(_motion_copy, value)

_motion_mix(a, b, u) = u < 1 ? a : b
_motion_mix(a::Number, b::Number, u) = (1 - u) * a + u * b
_motion_mix(a::Integer, b::Integer, u) = round(promote_type(typeof(a), typeof(b)), (1 - u) * a + u * b)
_motion_mix(a::Bool, b::Bool, u) = u < 1 ? a : b

function _motion_mix(a::Makie.Colorant, b::Makie.Colorant, u)
    x, y = Makie.RGBAf(a), Makie.RGBAf(b)
    value = Makie.RGBAf(_motion_mix(x.r, y.r, u), _motion_mix(x.g, y.g, u),
                       _motion_mix(x.b, y.b, u), _motion_mix(x.alpha, y.alpha, u))
    convert(typeof(a), value)
end

function _motion_mix(a::Tuple, b::Tuple, u)
    length(a) == length(b) || return u < 1 ? a : b
    map((x, y) -> _motion_mix(x, y, u), a, b)
end

function _motion_mix(a::NamedTuple, b::NamedTuple, u)
    keys(a) == keys(b) || return u < 1 ? a : b
    NamedTuple{keys(a)}(map((x, y) -> _motion_mix(x, y, u), values(a), values(b)))
end

function _motion_mix(a::AbstractArray, b::AbstractArray, u)
    numerical(T) = T <: Union{Number, Makie.Colorant, Makie.Point, Makie.Vec}
    if axes(a) == axes(b) && numerical(eltype(a)) && numerical(eltype(b))
        return _motion_mix.(a, b, Ref(u))
    end
    u < 1 ? a : b
end

function _motion_mix(a::Makie.Rect, b::Makie.Rect, u)
    typeof(a)(_motion_mix(a.origin, b.origin, u), _motion_mix(a.widths, b.widths, u))
end

function _motion_seconds(value; positive = false, name = "duration")
    value = Float64(value)
    isfinite(value) && (positive ? value > 0 : value >= 0) ||
        throw(ArgumentError("$name must be finite and $(positive ? "positive" : "nonnegative")."))
    value
end
