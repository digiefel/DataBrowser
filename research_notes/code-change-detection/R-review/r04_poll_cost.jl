# Cost of re-hashing a polled const (design: value hashes rechecked on every tick).
#   julia --startup-file=no --project=bench research_notes/code-change-detection/R-review/r04_poll_cost.jl
include(joinpath(@__DIR__, "harness.jl"))
h(x) = CodeRevisionFixed.deep_hash(nothing, x)
h(rand(10)); h([rand(2) for _ in 1:10]); CodeRevision.value_text(rand(10))
for n in (10^4, 10^5, 10^6, 10^7)
    v = rand(n)
    t_bytes = @elapsed h(v)
    t_text = n <= 10^5 ? @elapsed(CodeRevision.value_text(v)) : NaN   # prototype: printed text
    t_nested = n <= 10^5 ? @elapsed(h([rand(3) for _ in 1:n])) : NaN   # n small vectors
    println(rpad("n = $n", 12), "Vector{Float64}: raw bytes ", round(1000t_bytes; digits=2), " ms, as text ",
        round(1000t_text; digits=1), " ms;  Vector of n 3-vectors (structural) ", round(1000t_nested; digits=1), " ms")
    flush(stdout)
end
