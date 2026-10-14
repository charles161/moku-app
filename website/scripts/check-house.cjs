// The house section shows the house you scrolled to, quickly, on any network (Charles, 2026-10-06: "i scrolled to 58%
// but still its not rendering … sometimes it works and it doesnt, im low on network").
//
//   npm run check:house                        builds, serves dist/ on 127.0.0.1:5196, checks, stops
//   node scripts/check-house.cjs [url]         checks a running server or the live site
//   node scripts/check-house.cjs --only desktop:slow-3g
//
// Each run is a first visit (a fresh profile, an empty cache) in headless Chromium. It waits for the hero, goes to the
// house section the way a person does (a quick reader: about 4 s from the hero to the house) and builds the house part
// way: on a desktop by scrolling (the section is pinned and the scroll builds it), on a phone by dragging the slider.
// Then it stops and measures, from that moment:
//   right     the house shown is the one the numbers say (its own render, or its thumbnail standing in)
//   sharp     the house shown is its full render
// and fails when either takes longer than its budget. The report lands in review/house/report.json (ignored by git).
const fs = require('node:fs');
const path = require('node:path');
const { playwright, preview } = require('./preview.cjs');

const PORT = 5196;
const devices = {
  phone: { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true },
  desktop: { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2, isMobile: false, hasTouch: false },
};
const kbps = (n) => n * 1000 / 8;
const networks = {
  fast: null,
  'slow-3g': { downloadThroughput: kbps(400), uploadThroughput: kbps(400), latency: 400 },
};
// From the moment the person stops: the right house (a thumbnail may stand in), then its full render. On slow 3G a
// render (about 50 KB) takes 1.4 s alone; the friends' cards just scrolled past are still loading in the same seconds.
// Before the fix (2026-10-06) the right house took 9 s on a desktop and never came on a phone; after it, at once, and
// sharp in about 5.4 s and 4.5 s (a run that meets the friends' hello clips takes up to 7 s).
const budgets = { fast: { right: 300, sharp: 1000 }, 'slow-3g': { right: 1000, sharp: 8000 } };
const runs = [['desktop', 'slow-3g'], ['phone', 'slow-3g'], ['desktop', 'fast'], ['phone', 'fast']];

const args = process.argv.slice(2);
const option = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1]?.split(',') : null; };
const only = option('--only');
const target = args.find((arg) => /^https?:/.test(arg));

// What the page shows: the minutes its numbers name, and the render on screen.
function shown() {
  const image = document.querySelector('#world-image');
  const pieces = Number(document.querySelector('#house-pieces')?.textContent.match(/^(\d+)/)?.[1]);
  const minutes = String(pieces * 10).padStart(3, '0');
  const src = image?.currentSrc || image?.getAttribute('src') || '';
  const loaded = Boolean(image?.complete && image.naturalWidth > 0);
  return {
    pieces, src,
    right: loaded && new RegExp(`/(thumb/)?${minutes}\\.webp$`).test(src),
    sharp: loaded && new RegExp(`/${minutes}\\.webp$`).test(src) && !src.includes('/thumb/') && image.naturalWidth >= 800,
  };
}

async function buildPartWay(page, device) {
  if (device === 'desktop') {
    // Down the page with the wheel like a quick reader (about 4 s from the hero to the house, through the friends),
    // then on into the pinned story, which the scroll builds, a notch at a time, to 58%.
    const start = await page.evaluate(() => { const story = document.querySelector('.world-story'); return story.getBoundingClientRect().top + scrollY; });
    await page.mouse.move(700, 450);
    const notches = Math.max(1, Math.round((start - 200) / 120));
    for (let i = 0; i < notches; i++) {
      await page.mouse.wheel(0, 120);
      await page.waitForTimeout(4000 / notches);
    }
    for (let i = 0; i < 200; i++) {
      const percent = await page.evaluate(() => parseInt(document.querySelector('#house-percent').textContent, 10));
      if (percent >= 58) return percent;
      await page.mouse.wheel(0, 90);
      await page.waitForTimeout(70);
    }
    throw new Error('the scroll never built the house to 58%');
  }
  // Phones: the slider, dragged from where it is to 2h 20m, a step at a time.
  await page.locator('#world-progress').scrollIntoViewIfNeeded();
  await page.waitForTimeout(600);
  await page.evaluate(async () => {
    const slider = document.querySelector('#world-progress');
    slider.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
    const step = Number(slider.value) > 140 ? -10 : 10;
    for (let value = Number(slider.value) + step; step > 0 ? value <= 140 : value >= 140; value += step) {
      slider.value = value;
      slider.dispatchEvent(new Event('input', { bubbles: true }));
      await new Promise((resolve) => setTimeout(resolve, 90));
    }
  });
  return page.evaluate(() => parseInt(document.querySelector('#house-percent').textContent, 10));
}

async function run(browser, base, device, network) {
  const context = await browser.newContext(devices[device]);
  const page = await context.newPage();
  const cdp = await context.newCDPSession(page);
  await cdp.send('Network.enable');
  if (networks[network]) await cdp.send('Network.emulateNetworkConditions', { offline: false, ...networks[network] });
  // What downloads after the person stops, for --why.
  const loads = [];
  cdp.on('Network.requestWillBeSent', ({ requestId, request }) => loads.push({ requestId, url: request.url.replace(/^https?:\/\/[^/]+/, ''), at: Date.now(), bytes: 0 }));
  cdp.on('Network.loadingFinished', ({ requestId, encodedDataLength }) => { const l = loads.find((x) => x.requestId === requestId); if (l) { l.done = Date.now(); l.bytes = encodedDataLength; } });
  await page.goto(base, { waitUntil: 'commit' });
  await page.waitForFunction(() => document.querySelector('.live-demo')?.liveDemo?.running, null, { timeout: 60000 });
  await page.waitForTimeout(2000);  // a moment with the hero, as a person has
  const percent = await buildPartWay(page, device);
  const stopped = Date.now();
  const at = { right: null, sharp: null };
  let last;
  while (Date.now() - stopped < 15000 && at.sharp === null) {
    last = await page.evaluate(shown);
    const ms = Date.now() - stopped;
    if (last.right && at.right === null) at.right = ms;
    if (last.sharp && at.sharp === null) { at.sharp = ms; at.right ??= ms; }
    await page.waitForTimeout(50);
  }
  await context.close();
  if (args.includes('--why')) {
    const busy = loads.filter((l) => (l.done ?? Infinity) > stopped - 2000).map((l) => `${((l.at - stopped) / 1000).toFixed(1).padStart(6)} → ${l.done ? ((l.done - stopped) / 1000).toFixed(1).padStart(5) : '  ...'} s ${String(Math.round(l.bytes / 1024)).padStart(4)} KB ${l.url}`);
    console.log(`  downloading around the stop (${device} ${network}):\n  ${busy.join('\n  ')}`);
  }
  const budget = budgets[network];
  const problems = [];
  if (at.right === null || at.right > budget.right) problems.push(`the right house showed ${at.right === null ? 'never (15 s)' : `after ${at.right} ms`}, budget ${budget.right} ms`);
  if (at.sharp === null || at.sharp > budget.sharp) problems.push(`its full render ${at.sharp === null ? 'never (15 s)' : `after ${at.sharp} ms`}, budget ${budget.sharp} ms`);
  return { device, network, percent, at, shownAtEnd: last?.src.replace(/^https?:\/\/[^/]+/, ''), problems };
}

(async () => {
  const server = target ? null : await preview(PORT);
  const base = target ?? server.url;
  const { chromium } = playwright();
  const browser = await chromium.launch();
  const report = [];
  try {
    for (const [device, network] of runs) {
      if (only && !only.includes(`${device}:${network}`)) continue;
      const result = await run(browser, base, device, network).catch((error) => ({ device, network, problems: [String(error.message ?? error).split('\n')[0]] }));
      report.push(result);
      const t = (ms) => (ms === null || ms === undefined ? '   –   ' : `${(ms / 1000).toFixed(2)} s`).padStart(7);
      console.log(`${device.padEnd(8)} ${network.padEnd(8)} ${String(result.percent ?? '?').padStart(3)}%  right ${t(result.at?.right)}  sharp ${t(result.at?.sharp)}  ${result.problems.length ? result.problems.join('; ') : 'ok'}`);
    }
  } finally {
    await browser.close();
    await server?.close();
  }
  const out = path.resolve(__dirname, '../review/house');
  fs.mkdirSync(out, { recursive: true });
  fs.writeFileSync(path.join(out, 'report.json'), JSON.stringify(report, null, 2));
  const failed = report.filter((r) => r.problems.length);
  console.log(failed.length ? `\n${failed.length} of ${report.length} runs over budget.` : '\nThe right house, in time, on every run.');
  process.exit(failed.length ? 1 : 0);
})();
