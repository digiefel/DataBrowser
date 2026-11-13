import {readFile, writeFile} from 'node:fs/promises';
import {strict as assert} from 'node:assert';
import {fileURLToPath} from 'node:url';

const directory = fileURLToPath(new URL('.', import.meta.url));
const reference = JSON.parse(await readFile(`${directory}/output/native-reference.json`, 'utf8'));
const bytes = await readFile(`${directory}/output/kernels.wasm`);
const {module, instance} = await WebAssembly.instantiate(bytes, {});
assert.deepEqual(WebAssembly.Module.imports(module), []);

const load = async (name, exported) => new Function(
    `${await readFile(`${directory}/${name}`, 'utf8')}\nreturn ${exported};`
)();
const createGraph = await load('observable-runtime.js', 'createObservableGraph');
const createBridge = await load('output/bridge-runtime.js', 'createCompilerBridge');
const createPlayer = await load('motion-runtime.js', 'createMotionPlayer');
const bridge = createBridge(instance.exports);
const calls = new Map();
const kernels = Object.fromEntries(Object.entries(instance.exports).map(([name, value]) =>
    [name, typeof value === 'function' ? (...args) => {
        calls.set(name, (calls.get(name) || 0) + 1);
        return value(...args);
    } : value]));
const graph = createGraph(reference.graph_wire, kernels, bridge);
const player = createPlayer(reference.motion_wire, kernels);

let comparisons = 0, maximumError = 0;
function compare(actual, expected) {
    assert(Number.isFinite(actual));
    const error = Math.abs(actual - expected);
    maximumError = Math.max(maximumError, error);
    assert(error <= 1e-10 * Math.max(1, Math.abs(expected)), `${actual} != ${expected}`);
    comparisons++;
}
for (const scenario of reference.cloud_cases.flat(Infinity)) {
    graph.set({angle: scenario.angle, stretch: scenario.stretch});
    const rows = graph.read('rows');
    rows.x.forEach((x, i) => {compare(x, scenario.x[i]); compare(rows.y[i], scenario.y[i]);});
}
for (const scenario of reference.integral_cases) {
    graph.set({lower: scenario.lower, upper: scenario.upper});
    compare(graph.read('area'), scenario.value);
}
for (const scenario of [...reference.motion_cases].reverse()) {
    const state = player.sample(scenario.time);
    compare(state.angle, scenario.angle);
    compare(state.stretch, scenario.stretch);
    graph.set(state);
}

for (const scenario of reference.source_cases) {
    graph.set({source: scenario.points, angle: scenario.angle, stretch: scenario.stretch});
    const rows = graph.read('rows');
    assert.equal(rows.x.length, scenario.x.length);
    rows.x.forEach((x, i) => {compare(x, scenario.x[i]); compare(rows.y[i], scenario.y[i]);});
}
graph.set({source: reference.points});

const areaIndex = reference.graph_wire.outputs.area;
const areaFunction = reference.graph_wire.nodes[areaIndex].function_name;
const areaCalls = calls.get(areaFunction);
graph.set({angle: 0.713, stretch: 1.317});
assert.equal(calls.get(areaFunction), areaCalls, 'Unrelated geometry inputs must not recompute integration');
graph.set({lower: 0.0173, upper: 0.7731});
assert.equal(calls.get(areaFunction), areaCalls + 1, 'Coupled inputs must evaluate their dependent computation once');

const previousRows = graph.read('rows'), previousArea = graph.read('area');
assert.throws(() => graph.set({lower: 0.3, angle: 'invalid'}), TypeError);
assert.deepEqual(graph.read('rows'), previousRows);
assert.equal(graph.read('area'), previousArea);
assert.throws(() => graph.set({unknown: 0.2}), /Unknown exported input/);
assert.throws(() => graph.set({signal: [1, 2]}));
assert.deepEqual(graph.read('rows'), previousRows);
assert.equal(graph.read('area'), previousArea);

const signalNode = reference.graph_wire.nodes.find(node => node.name === 'signal');
const vector = bridge.build(signalNode.input_descriptor, signalNode.initial);
assert.throws(() => kernels[signalNode.descriptor.get](vector, 0n));
const result = {comparisons, maximumAbsoluteError: maximumError,
    wasmBytes: bytes.length, moduleImports: [], boundsErrorPreserved: true,
    dependencyDiscovery: true, batchedInputs: true, changingArrayLengths: true, unrelatedComputationsRetained: true,
    invalidInputRejectedBeforePublication: true,
    compilerVersion: reference.compiler_version, compilerPatch: reference.compiler_patch};
await writeFile(`${directory}/output/kernel-check.json`, JSON.stringify(result, null, 2));
console.log(JSON.stringify(result));
