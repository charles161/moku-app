// What a first visit to the site costs on slow networks, with budgets that fail.
//
//   npm run check:network                       builds, serves dist/ on 127.0.0.1:5194, checks, stops
//   node scripts/check-network.cjs [url]        checks a running server (default: starts the preview itself)
//   node scripts/check-network.cjs --only phone:slow-3g,desktop:fast
//
// Each run is a first visit (a fresh profile, so an empty cache) in headless Chromium, on a phone (390×844 at 3×, touch)
// or a desktop (1440×900 at 2×, a Retina Mac), on one network:
//   fast        no throttling
//   4g          9 Mbps down, 1.5 Mbps up, 165 ms (Chrome DevTools' "Fast 4G")
//   slow-3g     400 kbps down and up, 400 ms (WebPageTest's "3G Slow")
//   save-data   4G with Save-Data on (the header and navigator.connection.saveData)
// The page sees each network through navigator.connection, as a real phone's would.
//
// It measures, from the navigation's start:
//   first paint     the first contentful paint
//   text            the headline and the download button painted, opaque and in place
//   hero            that, and the demo's stage showing the companion (its still decoded)
//   playing         the demo's loop running
//   clip            the first native clip on screen
//   loop            the first loop (18 s) played through
// and the bytes on the wire before the hero showed, by the end of the first loop, and in all.
//
// Budgets (docs/specs/next-0-1-9.md §3): under 400 KB before the hero shows, everywhere; under
// 1.5 MB by the end of the first loop on a phone; the text and the download button usable within
// 3 s on slow 3G, and the hero showing its story in stills by then too. A missed budget exits 1.
// "serif" is when the headline's font is in place: after "text" would be a visible swap.
// The report lands in review/network/report.json (ignored by git).
const fs = require('node:fs');
const path = require('node:path');
const { playwright, preview: serve } = require('./preview.cjs');

const args = process.argv.slice(2);
const flag = (name) => { const i = args.indexOf(name); return i < 0 ? null : args.splice(i, 2)[1]; };
const only = flag('--only')?.split(',');
const PORT = 5194;
const given = args.find((arg) => /^https?:/.test(arg));

const KB = 1024;
const devices = {
  phone: { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true },
  desktop: { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2, isMobile: false, hasTouch: false },
};
const kbps = (n) => n * 1000 / 8;
const networks = {
  fast: null,
  '4g': { downloadThroughput: kbps(9000), uploadThroughput: kbps(1500), latency: 165 },
  'slow-3g': { downloadThroughput: kbps(400), uploadThroughput: kbps(400), latency: 400 },
  'save-data': { downloadThroughput: kbps(9000), uploadThroughput: kbps(1500), latency: 165, saveData: true },
};
const LOOP_SECONDS = 18;
// How long a run may take: a slow network gets time for its first loop and a little more.
const patience = { fast: 30000, '4g': 32000, 'slow-3g': 60000, 'save-data': 32000 };

const budgets = [
  { name: 'under 400 KB before the hero shows', applies: () => true, value: (r) => r.bytes.beforeHero, limit: 400 * KB, unit: 'bytes' },
  { name: 'under 1.5 MB for the first loop on a phone', applies: (r) => r.device === 'phone', value: (r) => r.bytes.firstLoop, limit: 1.5 * KB * KB, unit: 'bytes' },
  { name: 'the text and the download button usable within 3 s on slow 3G', applies: (r) => r.network === 'slow-3g', value: (r) => r.ms.text, limit: 3000, unit: 'ms' },
  { name: 'the hero tells its story in stills within 3 s on slow 3G', applies: (r) => r.network === 'slow-3g', value: (r) => r.ms.hero, limit: 3000, unit: 'ms' },
  // The demo itself plays everywhere: a page that loads light but never starts its loop has failed (it happened once).
  { name: 'the demo plays within 6 s', applies: () => true, value: (r) => r.ms.playing, limit: 6000, unit: 'ms' },
];

// In the page, from its first frame: when the text, the hero, the loop and the first clip show.
function watch() {
  const marks = window.__marks = {};
  const mark = (name) => { if (!(name in marks)) marks[name] = Math.round(performance.now()); };
  const opaque = (node) => {
    for (let at = node; at && at.nodeType === 1; at = at.parentElement) {
      const style = getComputedStyle(at);
      if (style.visibility === 'hidden' || style.display === 'none' || Number(style.opacity) < .95) return false;
    }
    const box = node.getBoundingClientRect();
    return box.width > 0 && box.height > 0;
  };
  const tick = () => {
    const title = document.querySelector('#hero-title');
    const button = [...document.querySelectorAll('.hero-get .button')].find(opaque);
    // A transform still moving the text in counts as not yet in place.
    const settled = title && !title.getAnimations({ subtree: true }).some((a) => a.playState === 'running');
    if (title && opaque(title) && button && settled) mark('text');
    const still = document.querySelector('.live-demo .moku-art img');
    const stage = document.querySelector('.live-demo .desk-frame');
    if ('text' in marks && still?.complete && still.naturalWidth > 0 && stage && opaque(stage)) mark('hero');
    const demo = document.querySelector('.live-demo')?.liveDemo;
    if (demo?.running && demo.elapsed > .5) mark('playing');
    if (document.querySelector('.live-demo .companion-motion')) mark('clip');
    // The headline's serif in place (before or after the text first showed: after is a visible swap).
    if (document.fonts?.check('400 1em "Instrument Serif"') && document.fonts.check('italic 400 1em "Instrument Serif"') && [...document.fonts].some((f) => f.family.includes('Instrument') && f.status === 'loaded')) mark('serif');
    if (demo && demo.elapsed >= 18) mark('loop');
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}

async function run(browser, base, device, network) {
  const conditions = networks[network];
  const context = await browser.newContext({ ...devices[device], ...(conditions?.saveData ? { extraHTTPHeaders: { 'Save-Data': 'on' } } : {}) });
  const page = await context.newPage();
  const cdp = await context.newCDPSession(page);
  await cdp.send('Network.enable');
  if (conditions) await cdp.send('Network.emulateNetworkConditions', { offline: false, ...conditions, saveData: undefined });
  if (conditions?.saveData) await cdp.send('Emulation.setDataSaverOverride', { dataSaverEnabled: true });
  await page.addInitScript(watch);

  // Bytes on the wire as they arrive (headers and bodies, compressed), with when they arrived.
  const requests = new Map();
  const arrivals = [];
  cdp.on('Network.requestWillBeSent', ({ requestId, request, type }) => {
    if (/^(blob|data):/.test(request.url)) return;
    requests.set(requestId, { url: request.url, type, bytes: 0, at: Date.now() });
  });
  cdp.on('Network.responseReceived', ({ requestId, type, response }) => {
    const r = requests.get(requestId);
    if (!r) return;
    r.type = type;
    r.cache = Object.entries(response.headers).find(([key]) => key.toLowerCase() === 'cache-control')?.[1];
  });
  cdp.on('Network.dataReceived', ({ requestId, encodedDataLength }) => {
    const r = requests.get(requestId);
    if (!r || !encodedDataLength) return;
    r.bytes += encodedDataLength;
    arrivals.push([Date.now(), encodedDataLength]);
  });
  cdp.on('Network.loadingFinished', ({ requestId, encodedDataLength }) => {
    const r = requests.get(requestId);
    if (!r) return;
    const rest = encodedDataLength - r.bytes;
    if (rest > 0) arrivals.push([Date.now(), rest]);
    r.bytes = Math.max(r.bytes, encodedDataLength);
    r.done = true;
  });

  await page.goto(base, { waitUntil: 'load', timeout: 120000 });
  const origin = await page.evaluate(() => performance.timeOrigin);
  const deadline = Date.now() + patience[network];
  while (Date.now() < deadline) {
    const marks = await page.evaluate(() => window.__marks);
    if ('loop' in marks) break;
    await page.waitForTimeout(250);
  }
  const marks = await page.evaluate(() => window.__marks);
  const paints = await page.evaluate(() => Object.fromEntries(performance.getEntriesByType('paint').map((e) => [e.name, Math.round(e.startTime)])));
  const connection = await page.evaluate(() => navigator.connection ? { effectiveType: navigator.connection.effectiveType, downlink: navigator.connection.downlink, saveData: navigator.connection.saveData } : null);
  const clipSize = await page.evaluate(() => document.documentElement.dataset.clips ?? null);
  await context.close();

  const upTo = (ms) => ms == null ? null : arrivals.filter(([at]) => at - origin <= ms).reduce((sum, [, n]) => sum + n, 0);
  const all = [...requests.values()].filter((r) => r.bytes > 0);
  const byType = {};
  for (const r of all) byType[r.type ?? 'Other'] = (byType[r.type ?? 'Other'] || 0) + r.bytes;
  const largest = [...all].sort((a, b) => b.bytes - a.bytes).slice(0, 6).map((r) => [new URL(r.url).pathname, r.bytes]);
  return {
    device, network, connection, clipSize,
    ms: { firstPaint: paints['first-contentful-paint'] ?? null, serif: marks.serif ?? null, text: marks.text ?? null, hero: marks.hero ?? null, playing: marks.playing ?? null, clip: marks.clip ?? null, loop: marks.loop ?? null },
    bytes: { beforeHero: upTo(marks.hero), firstLoop: upTo(marks.loop ?? null) ?? upTo(Infinity), total: upTo(Infinity), byType },
    largest,
    requests: [...requests.values()].sort((a, b) => a.at - b.at).map((r) => ({ path: new URL(r.url).pathname + new URL(r.url).search, type: r.type, bytes: r.bytes, at: Math.round(r.at - origin), done: Boolean(r.done), cache: r.cache })),
  };
}

const kb = (bytes) => bytes == null ? '–' : `${Math.round(bytes / KB)} KB`;
const s = (ms) => ms == null ? '–' : `${(ms / 1000).toFixed(1)} s`;

(async () => {
  if (!given && !fs.existsSync(path.resolve(__dirname, '../dist/index.html'))) throw new Error('No dist/: run npm run build first (npm run check:network does both).');
  const server = given ? null : await serve(PORT);
  const base = given ?? server.url;
  const { chromium } = playwright();
  const browser = await chromium.launch();
  const results = [];
  try {
    for (const device of Object.keys(devices)) {
      for (const network of Object.keys(networks)) {
        if (only && !only.includes(`${device}:${network}`)) continue;
        const result = await run(browser, base, device, network);
        results.push(result);
        const { ms, bytes } = result;
        console.log(`${`${device} ${network}`.padEnd(18)} paint ${s(ms.firstPaint).padStart(6)}  serif ${s(ms.serif).padStart(6)}  text ${s(ms.text).padStart(6)}  hero ${s(ms.hero).padStart(6)}  playing ${s(ms.playing).padStart(6)}  clip ${s(ms.clip).padStart(6)}  loop ${s(ms.loop).padStart(6)} │ before hero ${kb(bytes.beforeHero).padStart(7)}  first loop ${kb(bytes.firstLoop).padStart(8)}  all ${kb(bytes.total).padStart(8)}${result.clipSize ? `  clips ${result.clipSize}` : ''}`);
      }
    }
  } finally {
    await browser.close();
    await server?.close();
  }

  const failures = [];
  for (const budget of budgets) {
    for (const result of results.filter(budget.applies)) {
      const value = budget.value(result);
      if (value == null || value > budget.limit) failures.push(`${result.device} ${result.network}: ${budget.name} (${value == null ? 'never' : budget.unit === 'ms' ? s(value) : kb(value)})`);
    }
  }
  const output = path.resolve(__dirname, '../review/network');
  fs.mkdirSync(output, { recursive: true });
  fs.writeFileSync(path.join(output, 'report.json'), JSON.stringify({ at: new Date().toISOString(), base, results, failures }, null, 2));
  console.log(`\nReport: ${path.relative(process.cwd(), path.join(output, 'report.json'))}`);
  if (failures.length) {
    console.log(`\n${failures.length} budget${failures.length === 1 ? '' : 's'} missed:\n  ${failures.join('\n  ')}`);
    process.exitCode = 1;
  } else {
    console.log('\nEvery budget met.');
  }
})().catch((error) => { console.error(error); process.exitCode = 1; });
