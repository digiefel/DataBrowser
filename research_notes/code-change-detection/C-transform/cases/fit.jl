# Gauss-Newton fit of y = a exp(-b x) + c, written the way a user would.
model(p, x) = p[1] * exp(-p[2] * x) + p[3]
grad(p, x) = (e = exp(-p[2] * x); (e, -p[1] * x * e, 1.0))

# One user-function call per element; `m` is a local, so `m(p, x)` is a dynamic call.
function fit_elementwise(xs, ys, p0; iters=5, m=model)
    p = collect(p0)
    for _ in 1:iters
        JtJ = zeros(3, 3); Jtr = zeros(3)
        for i in eachindex(xs)
            r = ys[i] - m(p, xs[i])
            g = grad(p, xs[i])
            for a in 1:3
                Jtr[a] += g[a] * r
                for b in 1:3
                    JtJ[a, b] += g[a] * g[b]
                end
            end
        end
        p .+= JtJ \ Jtr
    end
    return p
end

# Same fit, user helpers called once per iteration; the loops are in Base broadcasting.
function fit_vectorized(xs, ys, p0; iters=5)
    p = collect(p0)
    for _ in 1:iters
        e = exp.(-p[2] .* xs)
        r = ys .- model.(Ref(p), xs)
        J = hcat(e, -p[1] .* xs .* e, ones(length(xs)))
        p .+= (J' * J) \ (J' * r)
    end
    return p
end

# Forward reference: `late_model` is defined after its caller, so the transform cannot know yet
# that it will be a const function and checks at run time.
function fit_forward(xs, ys, p0; iters=5)
    p = collect(p0); s = 0.0
    for _ in 1:iters, i in eachindex(xs)
        s += ys[i] - late_model(p, xs[i])
    end
    return s
end
late_model(p, x) = p[1] * exp(-p[2] * x) + p[3]
