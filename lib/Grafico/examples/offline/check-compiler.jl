module GraficoCompilerChecks

using WasmTarget, Makie
include("compile-values.jl")

# Makie terminates argument conversion by testing tuple identity. Tuples use
# field identity: equal array references, distinct copies, and exact float bits.
Base.@noinline rewrap(a, b) = (a, b)
tuple_same(a, b) = rewrap(a, b) === (a, b)
tuple_copy(a, b) = rewrap(a, b) === (copy(a), b)
tuple_distinct(a, b) = rewrap(a, b) !== (copy(a), b)
tuple_bits(a, b) = (a,) === (b,)
tuple_nested(a, x, y) = rewrap((a, x), true) === ((a, y), true)
converted_sum(a, b) = sum(point -> point[1] + point[2], only(Makie.convert_arguments(Makie.PointBased(), a, b)))
type_bytes(x::T) where {T} = sizeof(T)
float_isequal(x, y) = isequal(x, y)
scalar_identity(x, y) = x === y
scalar_distinct(x, y) = x !== y
Base.@noinline fpiseq(x, y) = x + y
custom_equality_name(x, y) = fpiseq(x, y)

roots = Any[]
bindings = Dict{String,WasmTarget.RootBindings}()
for (f, signature, name) in (
    (tuple_same, (Vector{Float64}, Vector{Float64}), "tuple_same"),
    (tuple_copy, (Vector{Float64}, Vector{Float64}), "tuple_copy"),
    (tuple_distinct, (Vector{Float64}, Vector{Float64}), "tuple_distinct"),
    (tuple_bits, (Float64, Float64), "tuple_bits"),
    (tuple_nested, (Vector{Float64}, Float64, Float64), "tuple_nested"),
    (converted_sum, (Vector{Float64}, Vector{Float64}), "converted_sum"),
    (type_bytes, (Float64,), "bytes_f64"),
    (type_bytes, (Float32,), "bytes_f32"),
    (float_isequal, (Float64, Float64), "isequal_f64"),
    (float_isequal, (Float32, Float32), "isequal_f32"),
    (scalar_identity, (Float64, Float64), "identity_f64"),
    (scalar_identity, (Float32, Float32), "identity_f32"),
    (scalar_distinct, (Float64, Float64), "distinct_f64"),
    (scalar_distinct, (Float32, Float32), "distinct_f32"),
    (custom_equality_name, (Float64, Float64), "custom_equality_name"),
)
    add_wasm_root!(roots, bindings, f, signature; name)
end
for T in (Float64, Float32)
    instance = WasmTarget.entry_method_instance(type_bytes, (T,))
    @assert instance.sparam_vals == Core.svec(T)
end
array_descriptor = transport_type!(Vector{Float64}, :argument, roots, bindings)
diagnostics = WasmTarget.WasmDiagnostic[]
bytes = WasmTarget.compile_multi(roots; diagnostics_sink = diagnostics, root_bindings = bindings)
isempty(diagnostics) || error("Compiler conformance produced diagnostics: $diagnostics")
output = joinpath(@__DIR__, "output")
mkpath(output)
write(joinpath(output, "compiler-checks.wasm"), bytes)
import JSON
write(joinpath(output, "compiler-checks.json"), JSON.json((; array_descriptor)))
println("GRAFICO_COMPILER_CHECKS_READY bytes=", length(bytes))

end
