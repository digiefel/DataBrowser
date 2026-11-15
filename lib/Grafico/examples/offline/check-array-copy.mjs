import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
const path=name=>fileURLToPath(new URL(`output/${name}`,import.meta.url));
const {instance} = await WebAssembly.instantiate(readFileSync(path('array-copy.wasm')));
const {fixtures,strides}=JSON.parse(readFileSync(path('array-copy.json'),'utf8'));
for(const {name,count,expected} of fixtures) {
  const actual=instance.exports[name](BigInt(count));
  if(typeof actual==='bigint')assert.equal(actual,BigInt(expected),`${name}(${count})`);
  else assert.equal(actual,Number(expected),`${name}(${count})`);
}
console.log(JSON.stringify({nativeComparisons:fixtures.length,overlapBothDirections:true,elementStrides:strides}));
