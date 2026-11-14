function createFigureBindings(description, plots, graph) {
    const constructors = {Float32Array, Float64Array, Uint32Array, Int32Array, Uint8Array};
    function update(affected, initialize = false) {
        const batches = plots.map(() => []);
        for (const binding of description) {
            if (!initialize && !affected.has(binding.output)) continue;
            const data = binding.format === 'scalar' ? graph.read(binding.output) :
                graph.readBuffer(binding.output, binding, constructors[binding.format]);
            batches[binding.plot].push([binding.key, data]);
        }
        batches.forEach((batch, index) => { if (batch.length) plots[index].update(batch); });
    }
    return {update};
}
