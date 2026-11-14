import {readFile, writeFile} from 'node:fs/promises';
import {performance} from 'node:perf_hooks';
const directory = new URL('.', import.meta.url);
const location = name => new URL(name, directory);
const load=async(name,result)=>new Function(`${await readFile(location(name),'utf8')}\nreturn ${result};`)();
const createBridge=await load('output/bridge-runtime.js','createCompilerBridge');
const createCodec=await load('value-runtime.js','createValueCodec');
const createGraph=await load('observable-runtime.js','createObservableGraph');
const fixture=JSON.parse(await readFile(location('output/native-reference.json'),'utf8'));
const {instance}=await WebAssembly.instantiate(await readFile(location('output/kernels.wasm')),{});
const graph=createGraph(fixture.graph_wire,instance.exports,createBridge(instance.exports),createCodec());
const result=[];
for(const count of [80,1024,4096,16384]) {
 const points=Array.from({length:count},(_,i)=>({x:.7*Math.cos(i/count*2*Math.PI),y:.5*Math.sin(i/count*2*Math.PI)}));
 graph.set({source:points});
 const computation=[],transport=[];
 for(let i=0;i<70;i++) {
  const start=performance.now();
  graph.set({angle:i*.037});
  const middle=performance.now();
  for(const binding of fixture.bindings)binding.format==='scalar'?graph.read(binding.output):graph.readBuffer(binding.output,binding,globalThis[binding.format]);
  const end=performance.now();
  if(i>=10){computation.push(middle-start);transport.push(end-middle);}
 }
 const summary=values=>({median:values.toSorted((a,b)=>a-b)[30],p95:values.toSorted((a,b)=>a-b)[56]});
 result.push({points:count,computationMs:summary(computation),readRendererValuesMs:summary(transport)});
}
await writeFile(location('output/performance.json'),JSON.stringify(result,null,2));
console.log(JSON.stringify({measurement:'Node CPU timing, excluding GPU drawing',result}));
