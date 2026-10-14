# A small stand-in for user project code, shared by all scripts in this folder.
# `process(item)` fits y = a*exp(-b*x) + c over 1e5 points with Gauss-Newton and reaches its
# helpers through every kind of call that a tracer must see:
#   static call, dynamic call through `Any[...]`, closure, keyword call,
#   a Base function (`sum`, `map!`) calling back into user code, and a global read.
module UserProject

model(p, x) = p[1] * exp(-p[2] * x) + p[3]
residual(p, x, y) = model(p, x) - y
jacrow(p, x) = (exp(-p[2] * x), -p[1] * x * exp(-p[2] * x), 1.0)

const threshold = Ref(1e-10)          # global data: tracing cannot see changes to this value
const steps = Any[nothing]            # dynamic call site: steps[1](...) is dispatched at run time

# One Gauss-Newton step. Reached only through `steps[1]`, never by name from `process`.
function gn_step(p, xs, ys)
    JtJ = zeros(3, 3); Jtr = zeros(3)
    for i in eachindex(xs)
        j = jacrow(p, xs[i]); r = residual(p, xs[i], ys[i])
        for a in 1:3
            Jtr[a] += j[a] * r
            for b in 1:3
                JtJ[a, b] += j[a] * j[b]
            end
        end
    end
    return p .- (JtJ \ Jtr)
end
steps[1] = gn_step

# Keyword call; the loop stops through the global `threshold[]`.
function fit(xs, ys; p0 = [1.0, 1.0, 0.0], iters = 20)
    p = p0
    for _ in 1:iters
        pnew = steps[1](p, xs, ys)                   # dynamic dispatch
        done = sum(abs2, pnew .- p) < threshold[]
        p = pnew
        done && break
    end
    return p
end

# `sum` (Base) calls back into the user closure, which calls `residual`.
cost(p, xs, ys) = sum(i -> abs2(residual(p, xs[i], ys[i])), eachindex(xs))

function process(item)
    xs, ys = item
    p = fit(xs, ys; iters = 30)
    return (p = p, cost = cost(p, xs, ys))
end

# Helper that `process` never calls: a tracer must NOT report it.
unused_helper(x) = x + 1

make_item(n = 100_000) = (xs = collect(range(0, 5; length = n));
                          (xs, 2.0 .* exp.(-1.3 .* xs) .+ 0.5 .+ 1e-3 .* sin.(37 .* xs)))

# Methods a tracer must report for `process`.
const EXPECTED = (:process, :fit, :gn_step, :jacrow, :residual, :model, :cost)

end
