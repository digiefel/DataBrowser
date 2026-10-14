# A user project file with the patterns that defeat a static walk.
myfit(x) = 2x
helper(x) = x + 1
const g = Any[myfit]                       # function stored in a container
struct P; f::Function; end
const p = P(myfit)                         # function stored in a field
threshold = 1.0                            # non-const global

process_static(x) = myfit(x) + 1
process_dynamic(x) = g[1](x) + 1           # README case
process_field(x) = p.f(x)
process_cb(x, cb) = cb(x)
process_map(xs) = map(helper, xs)          # helper called by Base code
process_do(xs) = map(xs) do x; myfit(x) end
process_kw(x; scale=2) = scale * myfit(x)
process_bcast(xs) = myfit.(xs)
process_global(x) = x > threshold
process_threads(xs) = (out = similar(xs); Threads.@threads for i in eachindex(xs); out[i] = g[1](xs[i]); end; out)
process_forward(x) = later(x)              # `later` is defined below
later(x) = 3x
