import {readFile, writeFile} from 'node:fs/promises';
import {strict as assert} from 'node:assert';
import {fileURLToPath} from 'node:url';
const directory = fileURLToPath(new URL('.', import.meta.url));

const reference = JSON.parse(await readFile(`${directory}/output/native-reference.json`, 'utf8'));
const bytes = await readFile(`${directory}/output/kernels.wasm`);
const {module, instance} = await WebAssembly.instantiate(bytes, {});
assert.deepEqual(WebAssembly.Module.imports(module), []);
const kernel = instance.exports;

function vector(values) {
  const result = kernel.vector_new(values.length);
  values.forEach((value, index) => kernel.vector_set(result, index + 1, value));
  return result;
}

const time = vector(reference.time), signal = vector(reference.signal);
let comparisons = 0, maximumError = 0;
function compare(actual, expected) {
  assert(Number.isFinite(actual));
  const error = Math.abs(actual - expected);
  maximumError = Math.max(maximumError, error);
  assert(error <= 1e-10 * Math.max(1, Math.abs(expected)), `${actual} != ${expected}`);
  comparisons++;
}

for (const test of reference.cloud_cases.flat(Infinity)) {
  reference.points.forEach((point, i) => {
    compare(kernel.cloud_x(test.angle, test.stretch, point.x, point.y), test.x[i]);
    compare(kernel.cloud_y(test.angle, test.stretch, point.x, point.y), test.y[i]);
  });
}
for (const test of reference.integral_cases) {
  compare(kernel.interval_integral(time, signal, test.lower, test.upper), test.value);
}
for (const test of reference.swing_cases) {
  compare(kernel.swing(test.start, test.progress), test.value);
}
for (const i of [0, 147, 1024]) compare(kernel.vector_get(signal, i + 1), reference.signal[i]);
assert.throws(() => kernel.vector_get(signal, 0));
const result = {comparisons, maximumAbsoluteError: maximumError,
  wasmBytes: bytes.length, moduleImports: [], boundsErrorPreserved: true,
  compilerVersion: reference.compiler_version, compilerPatch: reference.compiler_patch};
await writeFile(`${directory}/output/kernel-check.json`, JSON.stringify(result, null, 2));
console.log(JSON.stringify(result));
