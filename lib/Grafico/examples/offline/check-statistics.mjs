import {readFile} from 'node:fs/promises';
import {strict as assert} from 'node:assert';

const load = async (name, result) => new Function(`${await readFile(new URL(name, import.meta.url), 'utf8')}\nreturn ${result};`)();
const createBridge = await load('output/bridge-runtime.js', 'createCompilerBridge');
const createCodec = await load('value-runtime.js', 'createValueCodec');
const createGraph = await load('observable-runtime.js', 'createObservableGraph');
const fixtures = JSON.parse(await readFile(new URL('output/statistics.json', import.meta.url), 'utf8'));
const {instance, module} = await WebAssembly.instantiate(await readFile(new URL('output/statistics.wasm', import.meta.url)), {});
assert.deepEqual(WebAssembly.Module.imports(module), []);
const codec = createCodec(), bridge = createBridge(instance.exports);
let comparisons = 0, maximumAbsoluteError = 0;
for (const fixture of fixtures) {
    const graph = createGraph(fixture.wire, instance.exports, bridge, codec);
    for (const scenario of [...fixture.cases, ...fixture.cases.toReversed()]) {
        graph.set({rows: scenario.rows});
        for (const [name, expectedTree] of Object.entries(scenario.expected)) {
            const descriptor = fixture.wire.nodes[fixture.wire.outputs[name]].descriptor;
            const expected = codec.decode(descriptor, expectedTree), actual = graph.read(name);
            assert.equal(actual.length, expected.length);
            actual.forEach((value, index) => {
                const error = Math.abs(value - expected[index]);
                assert(error < 2e-12 || Object.is(value, expected[index]), `${fixture.name}.${name}[${index}]`);
                if (Number.isFinite(error)) maximumAbsoluteError = Math.max(error, maximumAbsoluteError);
                comparisons++;
            });
        }
    }
}
console.log(JSON.stringify({statistics: fixtures.map(f => f.name), comparisons, maximumAbsoluteError, reverseUpdates: true, imports: []}));
