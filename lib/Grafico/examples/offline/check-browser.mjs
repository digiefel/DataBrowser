import { chromium } from 'playwright';
import { PNG } from 'pngjs';
import { strict as assert } from 'node:assert';
import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';

const directory = fileURLToPath(new URL('.', import.meta.url));
const reference = JSON.parse(await readFile(`${directory}/output/native-reference.json`, 'utf8'));
const browser = await chromium.launch({headless: true});
try {
    const context = await browser.newContext({offline: true, viewport: {width: 1000, height: 950}});
    const page = await context.newPage();
    const errors = [], requests = [], sockets = [], warnings = [];
    page.on('pageerror', error => errors.push(String(error).slice(0,500)));
    page.on('request', request => {if (/^https?:/.test(request.url())) requests.push(request.url())});
    page.on('websocket', socket => sockets.push(socket.url()));
    page.on('console', message => {
        if (message.type() === 'warning' || message.type() === 'error') warnings.push(message.text().split('\n')[0].slice(0,500));
    });
    await page.goto(pathToFileURL(`${directory}/output/offline.html`).href);
    await page.waitForFunction(() => !!window.graficoOffline, null, {timeout: 15000}).catch(async error => {console.error(JSON.stringify({errors,requests,sockets,warnings,body:(await page.locator('body').innerText()).slice(0,2000)})); throw error});
    const canvas = page.locator('canvas').first();
    await canvas.waitFor({state: 'visible'});
    await page.waitForTimeout(150);
    const initialCanvas = await canvas.elementHandle();
    const hash = async () => createHash('sha256').update(await canvas.screenshot()).digest('hex');
    const first = await hash();
    let comparisons = 0;
    for (const scenario of reference.cloud_cases.flat(Infinity)) {
        // Use real DOM input events, including coupled, off-grid control values.
        const actual = await page.evaluate(({angle, stretch}) => {
            for (const [name, value] of Object.entries({angle, stretch})) {
                const input = document.querySelector(`input[aria-label="${name}"]`);
                input.value = value;
                input.dispatchEvent(new Event('input', {bubbles: true}));
            }
            const p = window.graficoOffline;
            const geometry = p.plot.mesh.geometry;
            const attribute = geometry.attributes[p.positionKey] || geometry.interleaved_attributes[p.positionKey];
            return {values: Array.from(attribute.array), width: p.width};
        }, scenario);
        for (let i = 0; i < scenario.x.length; i++) {
            assert.equal(actual.values[i * actual.width], Math.fround(scenario.x[i]));
            assert.equal(actual.values[i * actual.width + 1], Math.fround(scenario.y[i]));
            comparisons += 2;
        }
    }
    const changed = await hash();
    assert.notEqual(changed, first);
    for (const scenario of [...reference.motion_cases].reverse()) {
        const state = await page.evaluate(({time}) => {
            const input = document.querySelector('input[aria-label="Animation time"]');
            input.value = time;
            input.dispatchEvent(new Event('input', {bubbles: true}));
            return {...window.graficoOffline.state};
        }, scenario);
        assert.equal(state.angle, scenario.angle);
        assert.equal(state.stretch, scenario.stretch);
        comparisons += 2;
    }
    const sourceFrames = [];
    for (const scenario of reference.source_cases) {
        const actual = await page.evaluate(scenario => {
            const p = window.graficoOffline;
            p.set({source: scenario.points, angle: scenario.angle, stretch: scenario.stretch});
            const geometry = p.plot.mesh.geometry;
            const attribute = geometry.attributes[p.positionKey] || geometry.interleaved_attributes[p.positionKey];
            return {values: Array.from(attribute.array), width: p.width, count: attribute.count,
                instances: geometry.instanceCount, attributes: Object.keys(geometry.attributes)};
        }, scenario);
        assert.equal(actual.count, scenario.points.length);
        assert(actual.instances === Infinity || actual.instances === scenario.points.length);
        const painted = PNG.sync.read(await canvas.screenshot());
        let blue = 0;
        for (let i = 0; i < painted.data.length; i += 4) {
            const [r, g, b] = painted.data.subarray(i, i + 3);
            if (r < 100 && g > 50 && g < 200 && b > 120 && b > g + 20) blue++;
        }
        sourceFrames.push({points: scenario.points.length, bluePixels: blue});
        if (scenario.points.length === 0) assert.equal(blue, 0, 'Empty data must clear the point instances');
        else assert(blue / scenario.points.length > 10, 'Every nonempty dataset must paint its point instances');
        for (let i = 0; i < scenario.x.length; i++) {
            assert.equal(actual.values[i * actual.width], Math.fround(scenario.x[i]));
            assert.equal(actual.values[i * actual.width + 1], Math.fround(scenario.y[i]));
            comparisons += 2;
        }
    }
    const inkPerPoint = sourceFrames.filter(frame => frame.points).map(frame => frame.bluePixels / frame.points);
    assert(Math.min(...inkPerPoint) / Math.max(...inkPerPoint) > 0.6, 'Growing data must render the added instances');
    await page.evaluate(points => window.graficoOffline.set({source: points}), reference.points);
    for (const scenario of reference.integral_cases) {
        const actual = await page.evaluate(({lower, upper}) => window.graficoOffline.set({lower, upper}).integral, scenario);
        assert.equal(actual, scenario.value);
        comparisons++;
    }
    await page.evaluate(() => window.graficoOffline.set({angle: 0, stretch: 1, lower: 0, upper: 1}));
    await page.waitForTimeout(100);
    assert.equal(await hash(), first);
    assert(await initialCanvas.evaluate(element => element === document.querySelector('canvas')));
    const bounds = await canvas.boundingBox();
    await page.mouse.move(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
    await page.mouse.down();
    await page.mouse.move(bounds.x + bounds.width / 2 + 100, bounds.y + bounds.height / 2, {steps: 10});
    await page.mouse.up();
    assert((await page.evaluate(() => window.graficoOffline.state.angle)) > 0.5);
    await page.evaluate(() => window.graficoOffline.seek(0));
    await page.getByRole('button', {name: 'Play', exact: true}).click();
    await page.waitForTimeout(200);
    await page.getByRole('button', {name: 'Pause', exact: true}).click();
    assert((await page.evaluate(() => window.graficoOffline.state.angle)) > 0);
    await page.evaluate(() => window.graficoOffline.seek(0));
    await page.waitForTimeout(100);
    assert.equal(await hash(), first);
    await page.screenshot({path: `${directory}/output/offline.png`});
    assert.deepEqual(errors, []);
    assert.deepEqual(requests, []);
    assert.deepEqual(sockets, []);
    assert(warnings.every(message => message.includes('GPU stall due to ReadPixels')), JSON.stringify(warnings));
    const result = {offline: true, nativeBufferComparisons: comparisons, retainedCanvas: true,
        changedPixels: changed !== first, restoredPixels: true, playback: true,
        backwardSeeking: true, pointerDrag: true, changingArrayLengths: true, pageErrors: errors,
        networkRequests: requests, webSockets: sockets, sourceFrames, warnings,
        wasmImports: await page.evaluate(() => window.graficoOffline.imports)};
    await writeFile(`${directory}/output/browser-check.json`, JSON.stringify(result, null, 2));
    console.log(JSON.stringify(result));
} finally {
    await browser.close();
}
