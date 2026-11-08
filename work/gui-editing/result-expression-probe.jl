# A generic capture boundary, independent of the unsettled plot declaration syntax.
module ResultExpressionProbe
import GLM
struct StatisticRequest
    key::Symbol
end
struct DeferredExpression{F,C}
    expression::Any
    captured::C
    evaluate::F
end
resolve(context, value) = value
resolve(context, value::StatisticRequest) = get(context, value.key) do
    error("No aligned result for statistic $(value.key)")
end
function arguments(ex)
    ex isa Symbol && return Symbol[ex]
    ex isa Expr && ex.head == :tuple && return reduce(vcat, arguments.(ex.args); init=Symbol[])
    error("Only ordinary lambda arguments are covered by this probe")
end
function rewrite(ex, aliases, bound=Set{Symbol}())
    if ex isa Symbol
        return ex in bound || ex == :end ? ex : get!(aliases, ex) do
            gensym(ex)
        end
    elseif ex isa Expr
        ex.head == :quote && return ex
        ex.head in (:(=), :let, :function, :for, :while, :local, :global) &&
            error("Use a named function for statement-based formatting in this probe")
        if ex.head == :->
            localnames = union(bound, Set(arguments(first(ex.args))))
            return Expr(:->, first(ex.args), rewrite(last(ex.args), aliases, localnames))
        elseif ex.head == :kw
            return Expr(:kw, first(ex.args), rewrite(last(ex.args), aliases, bound))
        end
        return Expr(ex.head, (rewrite(x, aliases, bound) for x in ex.args)...)
    end
    ex
end
"""Capture one ordinary value expression over aligned statistic results."""
macro result(ex)
    context = gensym(:context)
    aliases = Dict{Symbol,Symbol}()
    body = rewrite(ex, aliases)
    bindings = [:(local $alias = $(GlobalRef(@__MODULE__, :resolve))($context, $name)) for (name, alias) in aliases]
    captured = collect(keys(aliases))
    closure = :($context -> begin $(bindings...); $body end)
    esc(:($(GlobalRef(@__MODULE__, :DeferredExpression))($(QuoteNode(ex)), ($(captured...),), $closure)))
end
function run(record)
    fit = StatisticRequest(:fit)
    context = Dict(:fit => record)
    config = (; prefix="Gain = ")
    expression = @result "$(config.prefix)$(round(fit.slope; digits=2))"
    @assert expression.evaluate(context) == config.prefix * "2.0"
    native = @result GLM.coef(fit.model)[2]
    @assert isapprox(native.evaluate(context), 2)
    width = @result 1 + abs(fit.slope)
    @assert isapprox(width.evaluate(context), 3)
    endpoint = @result fit.x[end]
    @assert endpoint.evaluate(context) == last(record.x)
    format_record(r) = "Gain = $(round(r.slope; digits=2))"
    named = @result format_record(fit)
    @assert named.evaluate(context) == "Gain = 2.0"
    native_function = @result (x -> x + fit.slope)
    @assert isapprox(native_function.evaluate(context)(5), 7)
    literal = @result :(fit.slope)
    @assert literal.evaluate(context) == :(fit.slope)
    missing = false
    try
        expression.evaluate(Dict{Symbol,Any}())
    catch error
        occursin("No aligned result", sprint(showerror,error)) || rethrow()
        missing = true
    end
    @assert missing
    @assert any(x -> x === fit, expression.captured)
    println("Generic result capture passed: interpolation, direct numeric value, endpoint indexing, named formatter and native function-valued attribute.")
    println("Literal quoted code is preserved; missing alignment errors instead of choosing a last result.")
    println("Scope: expression capture only; no plot grammar or GUI/source roundtrip is claimed.")
    nothing
end
end
