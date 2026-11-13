(async function initialize(root, plot, base64, reference) {
    const bytes = Uint8Array.from(atob(base64), c => c.charCodeAt(0));
    const {instance, module} = await WebAssembly.instantiate(bytes, {});
    const kernels = instance.exports;
    if (WebAssembly.Module.imports(module).length) throw new Error('Unexpected Wasm imports');

    const attributes = plot.plot_data.instance_attributes;
    const positionKey = ['wgl_positions', 'positions_transformed_f32c']
        .find(key => key in attributes);
    if (!positionKey) throw new Error('Scatter position attribute is absent');
    const width = attributes[positionKey].type_length;
    let buffer;
    const graph = createObservableGraph(reference.graph_wire, kernels, createCompilerBridge(kernels));
    const state = {angle: 0, stretch: 1, lower: 0, upper: 1};
    const controls = root.querySelector('#controls');
    const inputs = {};
    const player = createMotionPlayer(reference.motion_wire, kernels);
    const integral = document.createElement('output');

    function set(next) {
        const affected = graph.set(next);
        Object.assign(state, next);
        if (!buffer || affected.has('rows')) {
            const rows = graph.read('rows');
            buffer = new Float32Array(rows.x.length * width);
            rows.x.forEach((x, i) => {
                buffer[i * width] = x;
                buffer[i * width + 1] = rows.y[i];
            });
            plot.update([[positionKey, buffer]]);
        }
        const value = graph.read('area');
        integral.value = `Integral: ${value.toPrecision(10)}`;
        for (const [name, input] of Object.entries(inputs)) input.value = state[name];
        return {points: Array.from(buffer), integral: value, state: {...state}};
    }

    for (const [name, minimum, maximum] of [
        ['angle', 0, 6.3], ['stretch', 0.4, 1.8], ['lower', 0, 1], ['upper', 0, 1]
    ]) {
        const label = document.createElement('label');
        label.textContent = name;
        const input = document.createElement('input');
        Object.assign(input, {type: 'range', min: minimum, max: maximum, step: 'any', value: state[name]});
        input.setAttribute('aria-label', name);
        input.addEventListener('input', () => set({[name]: Number(input.value)}));
        inputs[name] = input;
        label.append(input);
        controls.append(label);
    }
    controls.append(integral);
    const playback = document.createElement('button');
    playback.textContent = 'Play';
    const scrubber = document.createElement('input');
    Object.assign(scrubber, {type: 'range', min: 0, max: player.duration, step: 'any', value: 0});
    scrubber.setAttribute('aria-label', 'Animation time');
    let running = false, animationFrame, previousTime;
    function pause() {
        running = false;
        cancelAnimationFrame(animationFrame);
        playback.textContent = 'Play';
    }
    function seek(time) {
        scrubber.value = Math.max(0, Math.min(player.duration, time));
        return set(player.sample(Number(scrubber.value)));
    }
    scrubber.addEventListener('input', () => {pause(); seek(Number(scrubber.value));});
    for (const input of Object.values(inputs)) input.addEventListener('input', pause);
    playback.addEventListener('click', () => {
        if (running) return pause();
        if (Number(scrubber.value) === player.duration) seek(0);
        running = true;
        playback.textContent = 'Pause';
        previousTime = performance.now();
        function tick(now) {
            if (!running) return;
            seek(Number(scrubber.value) + (now - previousTime) / 1000);
            previousTime = now;
            if (Number(scrubber.value) === player.duration) pause();
            else animationFrame = requestAnimationFrame(tick);
        }
        animationFrame = requestAnimationFrame(tick);
    });
    const timeline = document.createElement('label');
    timeline.textContent = 'Animation';
    timeline.append(scrubber, playback);
    controls.prepend(timeline);

    // Input mapping is browser code; all changes still enter through set().
    const canvas = root.querySelector('canvas');
    let drag;
    canvas.addEventListener('pointerdown', event => {
        pause();
        drag = {x: event.clientX, angle: state.angle};
        canvas.setPointerCapture(event.pointerId);
        event.preventDefault();
    });
    canvas.addEventListener('pointermove', event => {
        if (!drag) return;
        set({angle: drag.angle + 2 * Math.PI * (event.clientX - drag.x) / canvas.clientWidth});
    });
    canvas.addEventListener('pointerup', () => {drag = null;});
    canvas.addEventListener('pointercancel', () => {drag = null;});
    canvas.title = 'Drag horizontally to rotate';
    set(state);
    // Inspection handle for the offline verification, not an authoring API.
    window.graficoOffline = {set, seek, player, state, plot, positionKey, width, kernels, reference, graph,
        imports: WebAssembly.Module.imports(module)};
})
