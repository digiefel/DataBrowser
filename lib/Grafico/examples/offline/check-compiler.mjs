import {readFile} from 'node:fs/promises';
import {strict as assert} from 'node:assert';

const fixture = JSON.parse(await readFile(new URL('output/compiler-checks.json', import.meta.url), 'utf8'));
const source = await readFile(new URL('output/bridge-runtime.js', import.meta.url), 'utf8');
const createBridge = new Function(`${source}\nreturn createCompilerBridge;`)();
const {instance, module} = await WebAssembly.instantiate(await readFile(new URL('output/compiler-checks.wasm', import.meta.url)), {});
assert.deepEqual(WebAssembly.Module.imports(module), []);
const ex = instance.exports, bridge = createBridge(ex);
const codecSource = await readFile(new URL('value-runtime.js', import.meta.url), 'utf8');
const codec = new Function(`${codecSource}\nreturn createValueCodec;`)()();
const a = bridge.build(fixture.array_descriptor, codec.encode(fixture.array_descriptor, [1, 2]));
const b = bridge.build(fixture.array_descriptor, codec.encode(fixture.array_descriptor, [3, 4]));
assert.equal(ex.tuple_same(a, b), 1);
assert.equal(ex.tuple_copy(a, b), 0);
assert.equal(ex.tuple_distinct(a, b), 1);
for (const [x, y, expected] of [[0, 0, 1], [0, -0, 0], [-0, -0, 1], [NaN, NaN, 1], [0.3, 0.3, 1], [0.3, 0.4, 0]]) {
    assert.equal(ex.tuple_bits(x, y), expected);
    assert.equal(ex.tuple_nested(a, x, y), expected);
    assert.equal(ex.isequal_f64(x, y), expected);
    assert.equal(ex.isequal_f32(x, y), expected);
    assert.equal(ex.identity_f64(x, y), expected);
    assert.equal(ex.identity_f32(x, y), expected);
    assert.equal(ex.distinct_f64(x, y), 1 - expected);
    assert.equal(ex.distinct_f32(x, y), 1 - expected);
}
assert.equal(ex.converted_sum(a, b), 10);
const bits = new DataView(new ArrayBuffer(8));
bits.setBigUint64(0, 0x7ff8000000000001n);
const otherNaN = bits.getFloat64(0);
assert.equal(ex.isequal_f64(NaN, otherNaN), 1);
assert.equal(ex.identity_f64(NaN, otherNaN), 0);
assert.equal(ex.distinct_f64(NaN, otherNaN), 1);
assert.equal(ex.custom_equality_name(2, 3), 5);
assert.equal(ex.isequal_f64(NaN, 0), 0);
assert.equal(ex.isequal_f32(NaN, 0), 0);
assert.equal(ex.bytes_f64(0), 8n);
assert.equal(ex.bytes_f32(0), 4n);
console.log(JSON.stringify({tupleIdentity: true, nestedIdentity: true, signedZeroAndNaN: true, staticParameters: true, imports: []}));
