function createValueCodec() {
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

    return {encode, decode};
}
