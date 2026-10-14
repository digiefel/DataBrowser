inner(x) = x > 1 ? error("x too large") : x
middle(xs, cb) = map(x -> cb(x) + 1, xs)
outer(xs) = middle(xs, inner)
