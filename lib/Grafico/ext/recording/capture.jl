unobserve(value) = value
unobserve(value::Makie.Observable) = value[]

function scene_objects(root)
    scenes = Makie.Scene[]
    actors = Tuple{Makie.Scene,Makie.Plot}[]
    function visit_plot(scene, plot)
        Makie.is_atomic_plot(plot) && push!(actors, (scene, plot))
        foreach(child -> visit_plot(scene, child), plot.plots)
    end
    function visit(scene)
        push!(scenes, scene)
        foreach(plot -> visit_plot(scene, plot), scene.plots)
        foreach(visit, scene.children)
    end
    visit(root)
    scenes, actors
end

# Scene serialization creates temporary maps for camera, viewport, color and
# lights. Keep those maps live during capture and detach them afterwards.
function scene_metadata(scene, owned)
    descendants, _ = scene_objects(scene)
    scoped = [copy(child.deregister_callbacks) for child in descendants]
    computes = [last.(Makie.Observables.listeners(child.compute.onchange))
                for child in descendants]
    data = WGLMakie.serialize_scene(scene)
    for (child, previous, callbacks) in zip(descendants, scoped, computes)
        observers = [observer for observer in child.deregister_callbacks if all(other -> other !== observer, previous)]
        functions = [f for (_, f) in Makie.Observables.listeners(child.compute.onchange) if all(other -> other !== f, callbacks)]
        push!(owned, (; scene = child, observers, functions))
    end
    data
end

function release_metadata!(owned)
    for entry in owned
        foreach(Makie.off, entry.observers)
        filter!(observer -> all(other -> other !== observer, entry.observers), entry.scene.deregister_callbacks)
        foreach(f -> Makie.off(entry.scene.compute.onchange, f), entry.functions)
    end
end

function renderer_fields(template)
    accepted = Set((:visible, :faces, :glyph_data))
    for group in (:uniforms, :attributes, :vertexarrays, :instance_attributes)
        union!(accepted, keys(get(template, group, Dict())))
    end
    accepted
end

function watch_actor(plot, template, pool)
    accepted = renderer_fields(template)
    inputs = filter(input -> input.name in accepted, plot.attributes[:wgl_renderobject].parent.inputs)
    names = Tuple(input.name for input in inputs)
    arguments = NamedTuple{names}(Tuple(input[] for input in inputs))
    updates = WGLMakie.plot_updates(arguments, map(_ -> true, arguments))
    properties = Dict(string(key) => retain!(pool, value) for (key, value) in updates)
    updater = plot.attributes[:wgl_update_obs][]
    observer = Makie.on(updater) do changes
        values = changes isa Bonito.LargeUpdate ? changes.data : changes
        for (key, value) in values
            key in accepted || continue
            properties[string(key)] = retain!(pool, value)
        end
    end
    properties, observer
end

function capture(figure, planned; fps = 60)
    pool = ValuePool()
    scenes = Makie.Scene[]
    scene_indices = IdDict{Any,Int}()
    actors = NamedTuple[]
    actor_indices = IdDict{Any,Int}()
    scene_data = Dict{String,Any}()
    frames = NamedTuple[]
    metadata_observers = NamedTuple[]
    function cache_scene(data)
        scene_data[string(data[:uuid])] = data
        foreach(cache_scene, data[:children])
    end
    function scene_index(scene)
        get!(scene_indices, scene) do
            push!(scenes, scene)
            length(scenes)
        end
    end

    try
        Grafico._with_motion_state(planned) do
            for time in Grafico._motion_record_times(planned, fps)
                Grafico.seek!(planned, time)
                Makie.update_state_before_display!(figure)
                current_scenes, current_actors = scene_objects(figure.scene)
                # Initialize recipe computations before tracking the temporary
                # metadata observers; recipe dependencies continue to belong to Makie.
                for (scene, plot) in current_actors
                    haskey(plot.attributes, :wgl_renderobject) || WGLMakie.serialize_three(scene, plot)
                end
                scene_states = NamedTuple[]
                actor_states = NamedTuple[]
                for scene in current_scenes
                    id = scene_index(scene)
                    uuid = WGLMakie.js_uuid(scene)
                    haskey(scene_data, uuid) || cache_scene(scene_metadata(scene, metadata_observers))
                    metadata = scene_data[uuid]
                    keys = (:viewport, :backgroundcolor, :backgroundcolor_alpha, :clearscene,
                            :visible, :camera, :light_direction, :camera_relative_light, :ambient, :light_color)
                    properties = Dict(string(key) => retain!(pool, unobserve(metadata[key])) for key in keys)
                    parent = scene.parent === nothing ? 0 : scene_index(scene.parent)
                    push!(scene_states, (; id, parent, properties))
                end
                for (scene, plot) in current_actors
                    id = get!(actor_indices, plot) do
                        template = copy(WGLMakie.serialize_three(scene, plot))
                        # A displayed backend keeps its creation template while its
                        # buffers continue changing. Recreate that template through
                        # the backend's own constructor at the captured start.
                        edge = plot.attributes[:wgl_renderobject].parent
                        names = Tuple(input.name for input in edge.inputs)
                        arguments = NamedTuple{names}(Tuple(input[] for input in edge.inputs))
                        fresh = first(edge.callback(arguments, map(_ -> true, arguments), nothing))
                        uniforms = merge(template[:uniforms], fresh[:uniforms])
                        template = merge(template, fresh)
                        template[:uniforms] = uniforms
                        uuid = WGLMakie.js_uuid(plot) * "-recorded"
                        template[:uuid] = uuid
                        template[:updater] = Any[]
                        template = freeze(template)
                        properties, observer = watch_actor(plot, template, pool)
                        push!(actors, (; plot, scene, uuid, template, properties, observer))
                        length(actors)
                    end
                    # Pull the native renderer edge just as WGLMakie's display
                    # loop does. Its updater reports only changed inputs; the
                    # stored IDs still describe a complete independently seekable
                    # frame. Freeze updates as they arrive because native arrays
                    # can be mutated again before the next captured frame.
                    plot.attributes[:wgl_renderobject][]
                    properties = copy(actors[id].properties)
                    properties["visible"] = retain!(pool, plot.visible[])
                    properties["__render_state"] = retain!(pool,
                        (Makie.zvalue2d(plot), plot.overdraw[], plot.transparency[]))
                    push!(actor_states, (; id, scene = scene_index(scene), properties))
                end
                push!(frames, (; time, scenes = scene_states, actors = actor_states))
            end
        end
    finally
        foreach(actor -> Makie.off(actor.observer), actors)
        release_metadata!(metadata_observers)
    end

    # Every stored frame is independently seekable. Keep only changing renderer
    # inputs; immutable values remain in the native drawing object's template.
    initial = Dict{Tuple{Int,String},Int}()
    changing = Set{Tuple{Int,String}}()
    for frame in frames, actor in frame.actors, (key, value) in actor.properties
        identity = (actor.id, key)
        previous = get!(initial, identity, value)
        previous == value || push!(changing, identity)
    end
    for frame in frames, actor in frame.actors
        filter!(pair -> first(pair) in ("visible", "__render_state") || (actor.id, first(pair)) in changing, actor.properties)
    end
    used = Set{Int}()
    for frame in frames, item in (frame.scenes..., frame.actors...)
        union!(used, values(item.properties))
    end
    indices = sort!(collect(used))
    compact = Dict(old => new for (new, old) in enumerate(indices))
    for frame in frames, item in (frame.scenes..., frame.actors...)
        for (key, value) in item.properties
            item.properties[key] = compact[value]
        end
    end
    buffers = ValuePool()
    function pack(value)
        if value isa AbstractArray && isbitstype(eltype(value))
            return (; recorded_buffer = retain!(buffers, value))
        elseif value isa AbstractDict
            return Dict(key => pack(item) for (key, item) in value)
        elseif value isa Union{Tuple,NamedTuple,AbstractArray}
            return map(pack, value)
        end
        value
    end
    packed_values = map(index -> pack(pool.values[index]), indices)
    templates = map(scenes) do scene
        template = copy(scene_data[WGLMakie.js_uuid(scene)])
        template[:plots] = Any[]
        template[:children] = Any[]
        freeze(template)
    end
    description = (; duration = Grafico.duration(planned), fps, frames,
        values = packed_values, buffers = buffers.values, scene_ids = WGLMakie.js_uuid.(scenes), actor_ids = [actor.uuid for actor in actors])
    (; description, scene_templates = templates, actor_templates = [actor.template for actor in actors])
end
