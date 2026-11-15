module GraficoArrayCopyChecks
println("IMPORT_WASMTARGET"); flush(stdout)
using WasmTarget
import JSON

struct ThreeWords
    a::Int32
    b::Int32
    c::Int32
end
struct PaddedValue
    tag::UInt8
    value::Float64
end

function separate(count::Int64)
    source = [ThreeWords(-i, 2i, 3i) for i in Int32(1):Int32(8)]
    target = [ThreeWords(9i, -7i, 5i) for i in Int32(1):Int32(8)]
    copyto!(target, 2, source, 2, count)
    total = Int64(0)
    for i in 1:8
        value = target[i]
        total += i * (Int64(value.a) + 1000Int64(value.b) + 1000000Int64(value.c))
    end
    total
end

function overlap_left(count::Int64)
    values = [ThreeWords(-i, 2i, 3i) for i in Int32(1):Int32(8)]
    copyto!(values, 1, values, 2, count)
    total = Int64(0)
    for i in 1:8
        value = values[i]
        total += i * (Int64(value.a) + 1000Int64(value.b) + 1000000Int64(value.c))
    end
    total
end

function overlap_right(count::Int64)
    values = [ThreeWords(-i, 2i, 3i) for i in Int32(1):Int32(8)]
    copyto!(values, 2, values, 1, count)
    total = Int64(0)
    for i in 1:8
        value = values[i]
        total += i * (Int64(value.a) + 1000Int64(value.b) + 1000000Int64(value.c))
    end
    total
end

function padded(count::Int64)
    source = [PaddedValue(UInt8(i), i / 4) for i in 1:8]
    target = [PaddedValue(UInt8(10i), -i / 2) for i in 1:8]
    copyto!(target, 2, source, 2, count)
    total = 0.0
    for i in 1:8
        value = target[i]
        total += i * (1000value.tag + value.value)
    end
    total
end

function floats(count::Int64)
    source = [i / 4 for i in 1:8]
    target = [-i / 2 for i in 1:8]
    copyto!(target, 2, source, 2, count)
    sum(i * target[i] for i in 1:8)
end

function shorts(count::Int64)
    source = Int16[i-9 for i in 1:8]
    target = Int16[100i for i in 1:8]
    copyto!(target, 2, source, 2, count)
    sum(Int64(i) * target[i] for i in 1:8)
end

functions = (("separate",separate),("left",overlap_left),("right",overlap_right),
             ("padded",padded),("floats",floats),("shorts",shorts))
roots = [(f,(Int64,),name) for (name,f) in functions]
fixtures = [(; name, count, expected=string(f(count))) for (name,f) in functions for count in Int64(0):Int64(6)]
diagnostics = WasmTarget.WasmDiagnostic[]
println("COMPILING_STRUCT_COPIES strides=",Base.aligned_sizeof(ThreeWords),",",Base.aligned_sizeof(PaddedValue)); flush(stdout)
bytes = WasmTarget.compile_multi(roots; diagnostics_sink=diagnostics,
    link_roots=(args...)->(println("STRUCT_COPY_DEPENDENCIES_COLLECTED");flush(stdout)))
isempty(diagnostics) || error(diagnostics)
output = joinpath(@__DIR__, "output")
mkpath(output)
write(joinpath(output,"array-copy.wasm"),bytes)
strides = (words=Base.aligned_sizeof(ThreeWords),padded=Base.aligned_sizeof(PaddedValue),
           float=Base.aligned_sizeof(Float64),short=Base.aligned_sizeof(Int16))
write(joinpath(output,"array-copy.json"),JSON.json((;strides,fixtures)))
println("STRUCT_COPIES_READY bytes=",length(bytes)); flush(stdout)
end
