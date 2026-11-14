import {readFile} from 'node:fs/promises';
import {strict as assert} from 'node:assert';
const load = async (name, result) => new Function(`${await readFile(new URL(name, import.meta.url),'utf8')}\nreturn ${result};`)();
const createBridge=await load('output/bridge-runtime.js','createCompilerBridge');
const createCodec=await load('value-runtime.js','createValueCodec');
const createPlayer=await load('motion-runtime.js','createMotionPlayer');
const fixture=JSON.parse(await readFile(new URL('output/motion-values.json',import.meta.url),'utf8'));
const {instance,module}=await WebAssembly.instantiate(await readFile(new URL('output/motion-values.wasm',import.meta.url)),{});
assert.deepEqual(WebAssembly.Module.imports(module),[]);
const bridge=createBridge(instance.exports),codec=createCodec();
const player=createPlayer(fixture.description,instance.exports,bridge,codec);
let comparisons=0;
for(const scenario of [...fixture.cases,...fixture.cases.toReversed()]) {
 const actual=player.sample(scenario.time);
 for(const channel of fixture.description.channels) {
  const expected=codec.decode(channel.descriptor,scenario.values[channel.name]);
  assert.deepEqual(actual[channel.name],expected,`${channel.name} at ${scenario.time}`);
  comparisons++;
 }
 assert.equal(actual.time,Math.min(player.duration,scenario.time));
}
assert.throws(()=>player.sample(NaN),/Time must be finite/);
console.log(JSON.stringify({typedMotionComparisons:comparisons,channels:fixture.description.channels.map(c=>c.name),reverseSeeking:true,imports:[]}));
