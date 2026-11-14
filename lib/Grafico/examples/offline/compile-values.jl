# A shared root registry and type bridge for computations and motion values.
function add_wasm_root!(roots, bindings, f, signature; name = nothing, prefix = "computation")
    if name === nothing
        existing = findfirst(root -> root[1] === f && root[2] == signature, roots)
        existing === nothing || return roots[existing][3]
        name = "$(prefix)_$(length(roots) + 1)"
    else
        existing = findfirst(root -> root[3] == name, roots)
        if existing !== nothing
            root = roots[existing]
            root[2] == signature && typeof(root[1]) === typeof(f) ||
                throw(ArgumentError("Conflicting Wasm function name $name."))
            return name
        end
    end
    push!(roots, (f, signature, name))
    if fieldcount(typeof(f)) > 0
        constants = Dict(key => getfield(f, key) for key in fieldnames(typeof(f)))
        bindings[name] = WasmTarget.RootBindings(;
            captured_constants = constants, elide_closure_context = true)
    end
    name
end

function transport_type!(T, direction, roots, bindings)
    result = direction === :argument ? WasmTarget.Bridge.arg_descriptor(T) : WasmTarget.Bridge.descriptor(T)
    result === nothing && throw(ArgumentError("Export cannot transport $T across the browser boundary."))
    descriptor, accessors = result
    for (f, signature, name) in accessors
        add_wasm_root!(roots, bindings, f, signature; name)
    end
    descriptor
end
