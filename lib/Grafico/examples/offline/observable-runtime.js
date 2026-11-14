function createObservableGraph(description, ex, bridge, codec) {
    let values = new Array(description.nodes.length);
    const inputs = new Map();
    const constants = new Map();
    const {encode, decode} = codec;

    description.nodes.forEach((node, index) => {
        if (node.function_name === null) {
            if (inputs.has(node.name)) throw new Error(`Duplicate input name ${node.name}`);
            inputs.set(node.name, index);
            values[index] = bridge.build(node.input_descriptor, node.initial);
        }
        node.arguments.forEach(argument => {
            if (argument.node === undefined) constants.set(argument, bridge.build(argument.descriptor, argument.value));
        });
    });

    function set(changes = {}, initialize = false) {
        const dirty = new Set();
        // Validate and construct the complete input batch before publishing it.
        const updates = Object.entries(changes).map(([name, value]) => {
            if (!inputs.has(name)) throw new Error(`Unknown exported input ${name}`);
            const index = inputs.get(name), node = description.nodes[index];
            return [index, bridge.build(node.input_descriptor, encode(node.input_descriptor, value))];
        });
        const next = values.slice();
        for (const [index, value] of updates) {next[index] = value; dirty.add(index);}
        description.nodes.forEach((node, index) => {
            if (node.function_name === null) return;
            const affected = initialize || node.arguments.some(argument => dirty.has(argument.node));
            if (!affected) return;
            const args = node.arguments.map(argument => argument.node === undefined ? constants.get(argument) : next[argument.node]);
            next[index] = ex[node.function_name](...args);
            dirty.add(index);
        });
        values = next;
        return new Set(Object.entries(description.outputs).filter(([_, index]) => dirty.has(index)).map(([name]) => name));
    }

    function read(name) {
        if (!(name in description.outputs)) throw new Error(`Unknown exported output ${name}`);
        const index = description.outputs[name];
        if (!description.nodes[index].descriptor) throw new TypeError('This native renderer value needs its typed numeric binding');
        return decode(description.nodes[index].descriptor, bridge.walk(description.nodes[index].descriptor, values[index]));
    }
    function readBuffer(name, binding, Constructor) {
        if (!(name in description.outputs)) throw new Error(`Unknown exported output ${name}`);
        const value = values[description.outputs[name]];
        const count = Number(ex[binding.count_kernel](value));
        if (!Number.isSafeInteger(count) || count < 0) throw new RangeError('Invalid GPU buffer length');
        const data = new Constructor(count), get = ex[binding.component_kernel];
        for (let i = 0; i < count; ++i) data[i] = get(value, BigInt(i + 1));
        return data;
    }
    set({}, true);
    return {set, read, readBuffer, inputNames: Array.from(inputs.keys())};
}
