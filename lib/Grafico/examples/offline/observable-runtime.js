function createObservableGraph(description, ex, bridge) {
    let values = new Array(description.nodes.length);
    const inputs = new Map();
    const constants = new Map();
    const view = new DataView(new ArrayBuffer(8));

    // The compiler bridge owns Wasm representation. These functions expose
    // its exact trees as ordinary browser values for controls and rendering.
    function decode(d, t) {
        switch (d.k) {
            case 'bits':
                view.setBigInt64(0, BigInt(t.x));
                return view.getFloat64(0);
            case 'int': {
                const value = d.s ? BigInt.asIntN(d.w, BigInt(t.x)) : BigInt.asUintN(d.w, BigInt(t.x));
                if (d.w === 1) return value !== 0n;
                const number = Number(value);
                return Number.isSafeInteger(number) ? number : value;
            }
            case 'char': return String.fromCodePoint(Number(t.x));
            case 'str': return new TextDecoder().decode(Uint8Array.from(t.s));
            case 'vec': return t.a.map(value => decode(d.el, value));
            case 'mat': return {rows: t.r, columns: t.c, values: t.a.map(value => decode(d.el, value))};
            case 'fields': {
                const fields = d.fs.map((field, i) => decode(field.d, t.f[i]));
                return d.names ? Object.fromEntries(d.names.map((name, i) => [name, fields[i]])) : fields;
            }
            default: throw new Error(`Unsupported exported value ${d.k}`);
        }
    }

    function encode(d, value) {
        switch (d.k) {
            case 'bits':
                if (typeof value !== 'number') throw new TypeError('Expected a number');
                view.setFloat64(0, d.w === 32 ? Math.fround(value) : value);
                return {x: String(view.getBigInt64(0))};
            case 'int': {
                if (d.w === 1) {
                    if (typeof value !== 'boolean') throw new TypeError('Expected a boolean');
                    return {x: value ? '1' : '0'};
                }
                if (typeof value !== 'bigint' && !Number.isSafeInteger(value)) throw new TypeError('Expected an exact integer');
                const integer = BigInt(value), width = BigInt(d.w);
                const lower = d.s ? -(1n << (width - 1n)) : 0n;
                const upper = d.s ? (1n << (width - 1n)) : (1n << width);
                if (integer < lower || integer >= upper) throw new RangeError('Integer is outside its exported type');
                return {x: String(integer)};
            }
            case 'char': return {x: String(value.codePointAt(0))};
            case 'str': return {s: Array.from(new TextEncoder().encode(value))};
            case 'vec':
                if (!Array.isArray(value) && !ArrayBuffer.isView(value)) throw new TypeError('Expected an array');
                return {a: Array.from(value, item => encode(d.el, item))};
            case 'mat': {
                const {rows, columns, values} = value;
                if (!Number.isSafeInteger(rows) || rows < 0 || !Number.isSafeInteger(columns) || columns < 0 || values.length !== rows * columns)
                    throw new TypeError('Expected matrix dimensions and row-major values');
                return {r: rows, c: columns, a: Array.from(values, item => encode(d.el, item))};
            }
            case 'fields': return {f: d.fs.map((field, i) => encode(field.d, d.names ? value[d.names[i]] : value[i]))};
            default: throw new Error(`Unsupported input value ${d.k}`);
        }
    }

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
        return decode(description.nodes[index].descriptor, bridge.walk(description.nodes[index].descriptor, values[index]));
    }
    set({}, true);
    return {set, read, inputNames: Array.from(inputs.keys())};
}
