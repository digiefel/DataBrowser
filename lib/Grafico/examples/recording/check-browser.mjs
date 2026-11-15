import {chromium} from 'playwright';
import {PNG} from 'pngjs';
import {strict as assert} from 'node:assert';
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';
const filename = process.argv[2] || new URL('./output/native.html', import.meta.url).pathname;
const browser = await chromium.launch({headless:true});
try {
 const context = await browser.newContext({offline:true,viewport:{width:1050,height:900}});
 const page = await context.newPage();
 const errors=[],requests=[],sockets=[],warnings=[];
 page.on('pageerror',e=>errors.push(String(e).split('\n')[0].slice(0,300)));
 page.on('request',r=>{if(/^https?:/.test(r.url())) requests.push(r.url());});
 page.on('websocket',s=>sockets.push(s.url()));
 page.on('console',m=>{if(['warning','error'].includes(m.type())) warnings.push(m.text().split('\n')[0].slice(0,300));});
 await page.goto(pathToFileURL(filename).href);
 await page.waitForFunction(()=>window.graficoRecording || window.graficoRecordingError,null,{timeout:30000});
 assert.equal(await page.evaluate(()=>window.graficoRecordingError),undefined);
 const canvas=page.locator('canvas').first(), original=await canvas.elementHandle();
 await page.waitForTimeout(150);
 const size=await canvas.boundingBox();
 const duration=await page.evaluate(()=>window.graficoRecording.data.duration);
 const hash=async()=>createHash('sha256').update(await canvas.screenshot()).digest('hex');
 const hashes=[];
 for(let i=0;i<=12;i++) {
  await page.evaluate(t=>window.graficoRecording.seek(t),duration*i/12);
  await page.waitForTimeout(40);
  const painted=PNG.sync.read(await canvas.screenshot());
  let ink=0;for(let j=0;j<painted.data.length;j+=4) if(Math.min(...painted.data.subarray(j,j+3))<200)ink++;
  assert(ink>300,`A native frame was blank at ${duration*i/12}`);
  hashes.push(await hash());
 }
 for(let i=12;i>=0;i--) {
  await page.evaluate(t=>window.graficoRecording.seek(t),duration*i/12);
  await page.waitForTimeout(40);
  assert.equal(await hash(),hashes[i],`Reverse seeking changed the recorded state at frame ${i}`);
 }
 assert(await original.evaluate(c=>c===document.querySelector('canvas')));
 assert(new Set(hashes).size>3);
 await page.getByRole('button',{name:'Play',exact:true}).click();
 await page.waitForTimeout(250);
 await page.getByRole('button',{name:'Pause',exact:true}).click();
 assert(await page.evaluate(()=>window.graficoRecording.time>0));
 await page.evaluate(()=>window.graficoRecording.seek(window.graficoRecording.data.duration));
 await page.waitForTimeout(100);
 await page.screenshot({path:filename.replace('.html','.png')});
 assert.deepEqual(errors,[]);assert.deepEqual(requests,[]);assert.deepEqual(sockets,[]);
 assert(warnings.every(w=>w.includes('GPU stall due to ReadPixels')),JSON.stringify(warnings));
 console.log(JSON.stringify({file:filename,retainedCanvas:true,independentBackwardSeeking:true,nonblankStates:13,
  distinctStates:new Set(hashes).size,playback:true,offline:true,size,errors,requests,sockets}));
} finally {await browser.close();}
