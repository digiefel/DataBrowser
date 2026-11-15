(async function initialize(root, WGL, data, sceneTemplates, actorTemplates) {
    const clone = value => {
        if (ArrayBuffer.isView(value)) return value.slice();
        if (Array.isArray(value)) return value.map(clone);
        if (value && typeof value === 'object' && 'recorded_buffer' in value) return clone(data.buffers[value.recorded_buffer - 1]);
        if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, clone(item)]));
        return value;
    };
    const observable = value => ({value, listeners: [], on(f) {this.listeners.push(f);},
        notify(next) {this.value = next; this.listeners.forEach(f => f(next));}});
    for (const template of sceneTemplates) {
        for (const key of ['viewport', 'backgroundcolor', 'backgroundcolor_alpha', 'clearscene',
            'camera', 'light_direction', 'camera_relative_light', 'ambient', 'light_color', 'visible'])
            template[key] = observable(template[key]);
        if (template.cam3d_state) for (const key of Object.keys(template.cam3d_state))
            template.cam3d_state[key] = observable(template.cam3d_state[key]);
    }
    actorTemplates.forEach(template => {template.updater = observable([]);});
    const wrapper = root.querySelector('.figure');
    const canvas = document.createElement('canvas');
    wrapper.append(canvas);
    const [,, width, height] = sceneTemplates[0].viewport.value;
    WGL.create_scene(wrapper, canvas, observable([width, height]), sceneTemplates[0],
        observable(null), width, height, data.fps, false, null, null);
    const rootScene = WGL.find_scene(data.scene_ids[0]);
    if (!rootScene) throw new Error('The native WebGL scene did not initialize.');
    const sceneById = new Map();
    for (let i = 0; i < data.scene_ids.length; ++i) {
        const id = data.scene_ids[i];
        const scene = WGL.find_scene(id) || WGL.deserialize_scene(sceneTemplates[i], rootScene.screen);
        sceneById.set(i + 1, scene);
    }
    const missing = actorTemplates.filter(template => WGL.find_plots([template.uuid]).length === 0);
    if (missing.length) {
        // The backend initializes glyphs as part of scene deserialization. Keep
        // this loading scene outside the rendered tree and move its actors into
        // their recorded owner scenes when applying a frame.
        const pool = {...sceneTemplates[0], uuid: `${data.scene_ids[0]}-recorded-actors`,
            plots: missing, children: [], cam3d_state: null, clearscene: false};
        WGL.deserialize_scene(pool, rootScene.screen);
    }
    function hideCurrent(scene) {
        scene.children.forEach(mesh => {mesh.visible = false;});
        scene.scene_children.forEach(hideCurrent);
    }
    hideCurrent(rootScene);
    const actors = data.actor_ids.map(id => {
        const mesh = WGL.find_plots([id])[0];
        if (!mesh) throw new Error(`A recorded drawing object did not load: ${id}`);
        return mesh.plot_object;
    });
    actors.forEach(actor => {actor.mesh.visible = false;});
    const value = index => clone(data.values[index - 1]);
    const notify = (object, key, next) => {
        if (object[key] && typeof object[key].notify === 'function') object[key].notify(next);
        else object[key] = next;
    };
    let lastFrame = -1, running = false, animationFrame, time = 0;
    const controls = root.querySelector('.controls');
    const play = document.createElement('button');
    play.textContent = 'Play';
    const scrubber = document.createElement('input');
    Object.assign(scrubber, {type: 'range', min: 0, max: data.duration, step: 'any', value: 0});
    scrubber.setAttribute('aria-label', 'Animation time');
    const output = document.createElement('output');
    controls.append(play, scrubber, output);

    function frameIndex(time) {
        let low = 0, high = data.frames.length - 1;
        while (low < high) {
            const middle = Math.ceil((low + high) / 2);
            if (data.frames[middle].time <= time) low = middle;
            else high = middle - 1;
        }
        return low;
    }
    const previousScenes = new Map(), previousActors = new Map();
    let liveActors = new Set();
    function apply(index) {
        const frame = data.frames[index];
        for (const scene of sceneById.values()) {
            notify(scene, 'visible', false);
            scene.scene_children = [];
        }
        const nextActors = new Set(frame.actors.map(entry => entry.id));
        for (const id of liveActors) if (!nextActors.has(id)) {
            actors[id - 1].mesh.visible = false;
            previousActors.delete(id);
        }
        for (const entry of frame.scenes) {
            const scene = sceneById.get(entry.id), p = entry.properties;
            const previous = previousScenes.get(entry.id) || {};
            if (entry.parent) sceneById.get(entry.parent).scene_children.push(scene);
            for (const key of ['viewport', 'visible', 'backgroundcolor', 'backgroundcolor_alpha', 'clearscene'])
                if (key === 'visible' || p[key] !== previous[key]) notify(scene, key, value(p[key]));
            if (p.camera !== previous.camera) scene.wgl_camera.update_matrices(...value(p.camera));
            if (p.ambient !== previous.ambient) scene.ambient.value.fromArray(value(p.ambient));
            if (p.light_color !== previous.light_color) scene.light_color.value.fromArray(value(p.light_color));
            if (p.light_direction !== previous.light_direction || p.camera_relative_light !== previous.camera_relative_light) {
                if (value(p.camera_relative_light)) scene.wgl_camera.update_light_dir(value(p.light_direction));
                else scene.light_direction.value.fromArray(value(p.light_direction));
            }
            previousScenes.set(entry.id, p);
        }
        for (const entry of frame.actors) {
            const actor = actors[entry.id - 1], previous = previousActors.get(entry.id) || {};
            actor.move_to(sceneById.get(entry.scene));
            const updates = Object.entries(entry.properties)
                .filter(([key, index]) => key !== '__render_state' && index !== previous[key])
                .map(([key, index]) => [key, value(index)]);
            if (updates.length) actor.update(updates);
            const rendering = entry.properties.__render_state;
            if (rendering !== previous.__render_state) {
                const [order, overdraw, transparency] = value(rendering);
                actor.mesh.renderOrder = order;
                actor.mesh.material.depthTest = !overdraw;
                actor.mesh.material.depthWrite = !transparency;
            }
            previousActors.set(entry.id, entry.properties);
        }
        liveActors = nextActors;
        lastFrame = index;
    }
    function seek(next, force = true) {
        if (!Number.isFinite(next)) throw new TypeError('Time must be finite');
        time = Math.max(0, Math.min(data.duration, next));
        const index = frameIndex(time);
        if (force || index !== lastFrame) apply(index);
        scrubber.value = time;
        output.value = `${time.toFixed(2)} / ${data.duration.toFixed(2)} s`;
        return {time, frame: index};
    }
    function pause() {
        running = false;
        cancelAnimationFrame(animationFrame);
        play.textContent = 'Play';
    }
    scrubber.addEventListener('input', () => {pause(); seek(Number(scrubber.value));});
    play.addEventListener('click', () => {
        if (running) return pause();
        if (time === data.duration) seek(0);
        running = true;
        play.textContent = 'Pause';
        let previous = performance.now();
        function tick(now) {
            if (!running) return;
            seek(time + (now - previous) / 1000, false);
            previous = now;
            if (time === data.duration) pause();
            else animationFrame = requestAnimationFrame(tick);
        }
        animationFrame = requestAnimationFrame(tick);
    });
    seek(0);
    window.graficoRecording = {seek, pause, data, actors, scenes: sceneById,
        mode: 'native-state-recording', get time() {return time;}};
})
