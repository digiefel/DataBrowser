# Staging the ordinary grammar preserves numeric dependencies all the way to
# Makie. These private array/table views only exist during compilation.
# Compilation captures one coherent state. Retain ordinary map metadata, but
# detach compiler-owned listeners so later authored updates cannot evaluate a
# half-updated set of analysis columns. The exported scheduler evaluates batches.
function _retained_lift(f, arguments...)
    output = Makie.lift(f, arguments...)
    foreach(Makie.off, output.inputs)
    output
end

struct _RetainedArray{T,N,A<:AbstractArray{T,N},O} <: AbstractArray{T,N}
    value::A
    source::O
end
_RetainedArray(source::Makie.Observable) = _RetainedArray(source[], source)
Base.size(array::_RetainedArray) = size(array.value)
Base.axes(array::_RetainedArray) = axes(array.value)
Base.IndexStyle(::Type{<:_RetainedArray{T,N,A}}) where {T,N,A} = Base.IndexStyle(A)
Base.getindex(array::_RetainedArray, indices...) = getindex(array.value, indices...)

struct _RetainedMap{F}
    function_value::F
end
(call::_RetainedMap)(arrays...) = map(call.function_value, arrays...)
_retained_source(array) = array
_retained_source(array::_RetainedArray) = array.source
function Base.map(f, first::_RetainedArray, others::AbstractArray...)
    source = _retained_lift(_RetainedMap(f), first.source, map(_retained_source, others)...)
    _RetainedArray(source)
end

struct _RetainedColumn{Name} end
(::_RetainedColumn{Name})(table) where {Name} = Tables.getcolumn(Tables.columns(table), Name)

struct _RetainedColumns{T,O} <: Tables.AbstractColumns
    columns::T
    source::O
end
Tables.columnnames(table::_RetainedColumns) = Tables.columnnames(getfield(table, :columns))
Tables.schema(table::_RetainedColumns) = Tables.schema(getfield(table, :columns))
function Tables.getcolumn(table::_RetainedColumns, name::Symbol)
    source = _retained_lift(_RetainedColumn{name}(), getfield(table, :source))
    values = source[]
    scientific_eltype(values) === categorical && throw(ArgumentError(
        "Offline compilation cannot yet change categorical groups. Keep grouping columns static and animate numeric data with lift/map."))
    _RetainedArray(source)
end
Tables.getcolumn(table::_RetainedColumns, index::Int) =
    Tables.getcolumn(table, Tables.columnnames(table)[index])

function _retained_data(source::Makie.Observable)
    Layer(data = Columns(_RetainedColumns(Tables.columns(source[]), source)))
end

_retained_plot(plot) = plot
function _retained_plot(source::ObservablePlot)
    producer = _observable_producer(source)
    producer === nothing && throw(ArgumentError(
        "Offline compilation needs a stable plot declaration; animate its data and attributes rather than replacing an entire plot Observable."))
    if producer.f === data
        return _retained_data(only(producer.args))
    elseif producer.f isa _ReactiveCall
        call = producer.f
        if call.operation === data
            # Replay data's arguments, without constructing Layer values in Wasm.
            arguments = _ReactiveCall(identity, call.positional, call.named)
            table_source = _retained_lift(arguments, producer.args...)
            return _retained_data(table_source)
        end
        arguments = map(producer.args) do argument
            argument isa ObservablePlot ? _retained_plot(argument) : argument[]
        end
        return call(arguments...)
    elseif producer.f === (*) || producer.f === (+)
        return producer.f(map(_retained_plot, producer.args)...)
    end
    throw(ArgumentError("Offline compilation cannot stage $(typeof(producer.f)). Use ordinary Grafico data/mapping/visual declarations with lift/map for numeric computations."))
end
_retained_plot(plot::PlotLines) = PlotLines([
    PlotLine(_retained_plot(line.layers), line.shared, line.drawn) for line in plot.lines])
_retained_plot(plot::Scaled) = Scaled(_retained_plot(plot.layers), plot.scales,
    plot.texts, plot.legend, plot.theme, plot.coords)
_retained_plot(plot::YScaleLayers) = YScaleLayers([
    role => _retained_plot(layer) for (role, layer) in plot.layers])
_retained_plot(plot::ComposedFigure) = ComposedFigure([
    position => _retained_plot(child) for (position, child) in plot.cells])

_entry_argument(array::_RetainedArray) = array.source

_tracked_array(::_RetainedArray) = true
struct _RetainedConcat end
(::_RetainedConcat)(arrays...) = reduce(vcat, arrays)
function _concat_data(arrays, ::Val{true})
    _RetainedArray(_retained_lift(_RetainedConcat(), map(_retained_source, arrays)...))
end
_data_width(array::_RetainedArray) = _retained_lift(_data_width, array.source)

struct _RetainedAnalysis{F,N,Names,E}
    operation::F
end
function (call::_RetainedAnalysis{F,N,Names,E})(arrays::Vararg{Any,M}) where {F,N,Names,E,M}
    positional = ntuple(i -> arrays[i], Val(N))
    named = NamedTuple{Names}(ntuple(i -> arrays[N + i], Val(length(Names))))
    context = ntuple(i -> arrays[N + length(Names) + i], Val(E))
    p, n = Base.@inline call.operation(positional, named, context...)
    (Tuple(p)..., Tuple(values(n))...)
end

struct _RetainedResult{I} end
(::_RetainedResult{I})(values) where {I} = values[I]

function _map_numeric(f, positional, named, context, ::Val{true})
    # Analyses run the same numerical function on concrete tuples of arrays.
    # Dictionaries remain in the host grammar, outside the compiled kernel.
    names = Tuple(keys(named))
    all(name -> name isa Symbol, names) || throw(ArgumentError(
        "An exported analysis needs symbolic named inputs."))
    arguments = (Tuple(positional)..., Tuple(values(named))..., context...)
    call = _RetainedAnalysis{typeof(f),length(positional),names,length(context)}(f)
    initial_p, initial_n = f(Tuple(map(Makie.to_value ∘ _retained_source, positional)),
        NamedTuple{names}(Tuple(map(Makie.to_value ∘ _retained_source, values(named)))),
        map(Makie.to_value, context)...)
    output_names = Tuple(keys(initial_n))
    source = _retained_lift(call, map(_retained_source, arguments)...)
    results = ntuple(length(source[])) do i
        value = _retained_lift(_RetainedResult{i}(), source)
        value[] isa AbstractArray || throw(ArgumentError(
            "An exported analysis returned a nonarray column $(typeof(value[]))."))
        _RetainedArray(value)
    end
    n = length(initial_p)
    Tuple(results[1:n]), dictionary([name => results[n + i] for (i, name) in enumerate(output_names)])
end

_tracked_numeric(::Makie.Observable) = true

struct _RetainedLimits{F}
    transform::F
end
function (call::_RetainedLimits)(columns::Vararg{Any,N}) where {N}
    nested_extrema_finite(map(column -> to_transformed_numerical(column, call.transform), columns))
end
function _transformation_datalimits(positional, transforms, ::Val{true})
    dimensions = ntuple(length(transforms)) do i
        _retained_lift(_RetainedLimits(transforms[i]), map(_retained_source, Tuple(positional[i]))...)
    end
    _retained_lift(tuple, dimensions...)
end
