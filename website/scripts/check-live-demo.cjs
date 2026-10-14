// Records the hero's live demo in headless Chromium and reports its smoothness.
//
//   node scripts/check-live-demo.cjs http://127.0.0.1:4173/ [loops]
//
// Pass 1 (three loops): every requestAnimationFrame interval, and Chromium's own
//   frame reporter from a trace (each frame presented, partial or dropped, and
//   whether a drop affected smoothness). The trace is streamed and deleted.
// Pass 2 (three more loops, with the tab-leave moment once): the compositor's
//   frames as a screencast, cropped to Moku and to the desk, with motion measured
//   per frame:
//   - held frames: Moku still between moving frames while his clip, decoded
//     from its WebP, changes visibly in that time (a still stretch in the clip
//     itself is not a hold);
//   - snaps: a change far larger than the changes just before and after it,
//     listed with the clip seam, loop seam, tab-leave moment or window
//     activation it falls near. Windows come to the front instantly, as on a Mac.
//   The screencast JPEG-encodes every frame on the CPU, so its own frame gaps are
//   capture artifacts, not the page's timing (pass 1 is).
// report.json and frames.csv land in review/live-demo/ (ignored by git). Set
// PLAYWRIGHT_MODULE when Playwright lives elsewhere (../melo-tab on Charles's Mac).
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');

const url = process.argv[2] || 'http://127.0.0.1:5186/';
const loops = Number(process.argv[3] || 3);
const VSYNC = 1000 / 60;
const NOISE = .05;
const output = path.resolve(__dirname, '../review/live-demo');
const framesDir = path.join(output, 'frames');

const round = (n, digits = 2) => Math.round(n * 10 ** digits) / 10 ** digits;
const stats = (values) => {
  const sorted = [...values].sort((a, b) => a - b);
  const at = (q) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))];
  return {
    frames: values.length, mean: round(values.reduce((a, b) => a + b, 0) / values.length),
    p50: round(at(.5)), p95: round(at(.95)), p99: round(at(.99)), max: round(sorted.at(-1)),
    over20ms: values.filter((v) => v > 20).length, over34ms: values.filter((v) => v > 34).length,
  };
};

async function open(browser) {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 });
  await page.addInitScript(() => {
    window.__raf = [];
    window.__clips = [];
    const tick = (now) => {
      const demo = document.querySelector('.live-demo')?.liveDemo;
      if (demo?.running) window.__raf.push([now, demo.elapsed]);
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
    new MutationObserver(() => {
      const moku = document.querySelector('.desk-moku');
      if (!moku || moku.__watched) return;
      moku.__watched = true;
      new MutationObserver(() => window.__clips.push([performance.timeOrigin + performance.now(), moku.dataset.motion || null]))
        .observe(moku, { attributes: true, attributeFilter: ['data-motion'] });
    }).observe(document, { childList: true, subtree: true });
  });
  await page.goto(url);
  await page.waitForFunction(() => document.querySelector('.live-demo').liveDemo?.running, null, { timeout: 30000 });
  return page;
}
const elapsed = (page) => page.evaluate(() => document.querySelector('.live-demo').liveDemo.elapsed);
async function waitFor(page, target) {
  while (await elapsed(page) < target) await page.waitForTimeout(40);
}

// Frames from Chromium's PipelineReporter, read a line at a time (one event per line).
async function frameReports(file) {
  const reports = [];
  let markTs = null;
  for await (const line of readline.createInterface({ input: fs.createReadStream(file) })) {
    if (markTs == null && line.includes('"live-demo-start"')) markTs = Number(/"ts":(\d+)/.exec(line)?.[1]) || null;
    if (!line.includes('"PipelineReporter"') || !line.includes('"ph":"b"')) continue;
    reports.push({ ts: Number(/"ts":(\d+)/.exec(line)?.[1]), state: /"state":"(\w+)"/.exec(line)?.[1], smoothness: line.includes('"affects_smoothness":true') });
  }
  return { reports, markTs };
}

(async () => {
  fs.mkdirSync(framesDir, { recursive: true });
  const { scene, LOOP } = await import(path.resolve(__dirname, '../src/demo-timeline.js'));
  const browser = await chromium.launch();

  // Pass 1: the page's frames and Chromium's frame reporter.
  let page = await open(browser);
  const traceFile = path.join(output, 'trace.json');
  await browser.startTracing(page, { path: traceFile, categories: ['disabled-by-default-devtools.timeline.frame', 'blink.user_timing'] });
  const start = await page.evaluate(() => { performance.mark('live-demo-start'); return document.querySelector('.live-demo').liveDemo.elapsed; });
  await waitFor(page, start + loops * LOOP);
  await browser.stopTracing();
  const raf = await page.evaluate(() => window.__raf);
  const rafGaps = raf.slice(1).map(([now], i) => now - raf[i][0]);
  await page.close();
  const { reports, markTs } = await frameReports(traceFile);
  fs.rmSync(traceFile, { force: true });
  const zero = markTs ?? reports[0]?.ts ?? 0;
  const loopTime = (ts) => round((start + (ts - zero) / 1e6) % LOOP);
  const chromiumFrames = {
    presented: reports.filter(({ state }) => state === 'STATE_PRESENTED_ALL').length,
    presentedPartial: reports.filter(({ state }) => state === 'STATE_PRESENTED_PARTIAL').length,
    dropped: reports.filter(({ state }) => state === 'STATE_DROPPED').map(({ ts, smoothness }) => ({ t: loopTime(ts), affectsSmoothness: smoothness })),
    affectingSmoothness: reports.filter(({ smoothness }) => smoothness).length,
  };

  // Pass 2: the screencast, for motion per frame.
  page = await open(browser);
  const boxes = await page.evaluate(() => {
    const box = (selector) => { const r = document.querySelector(selector).getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height }; };
    // Moku's box overlaps the windows behind him; measure the part clear of them,
    // where the companion is, so a window or the feed moving isn't counted as his.
    const moku = box('.desk-moku');
    return { moku: { x: moku.x + moku.w * .36, y: moku.y + moku.h * .08, w: moku.w * .5, h: moku.h * .84 }, desk: box('.desk') };
  });
  const cdp = await page.context().newCDPSession(page);
  const frames = [];
  cdp.on('Page.screencastFrame', ({ data, metadata, sessionId }) => {
    const file = path.join(framesDir, `${String(frames.length).padStart(5, '0')}.jpg`);
    frames.push({ file, wall: metadata.timestamp * 1000 });
    fs.writeFile(file, Buffer.from(data, 'base64'), () => {});
    cdp.send('Page.screencastFrameAck', { sessionId }).catch(() => {});
  });
  const begin = Math.ceil(await elapsed(page) / LOOP) * LOOP;
  await waitFor(page, begin - .5);
  await cdp.send('Page.startScreencast', { format: 'jpeg', quality: 80, everyNthFrame: 1 });
  // The tab-leave moment, mid-drift in the second loop: the page is told it's
  // hidden, then visible again 0.6 s later (a headless page never really is).
  const switches = [];
  const visibility = (hidden) => page.evaluate((h) => {
    Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => (h ? 'hidden' : 'visible') });
    Object.defineProperty(document, 'hidden', { configurable: true, get: () => h });
    document.dispatchEvent(new Event('visibilitychange'));
  }, hidden);
  await waitFor(page, begin + LOOP + 8);
  // What changes while hidden is never seen in a real tab; headless still paints it.
  switches.push({ moment: 'hidden (unseen in a real tab)', at: await elapsed(page), wall: await page.evaluate(() => performance.timeOrigin + performance.now()) });
  await visibility(true);
  await page.waitForTimeout(600);
  await visibility(false);
  switches.push({ moment: 'back from another tab', at: await elapsed(page), wall: await page.evaluate(() => performance.timeOrigin + performance.now()) });
  await waitFor(page, begin + loops * LOOP + .5);
  await cdp.send('Page.stopScreencast');
  const log = await page.evaluate(() => ({ raf: window.__raf, clips: window.__clips, origin: performance.timeOrigin }));
  await page.waitForTimeout(500);

  // Decode each frame in a blank page on the same origin, crop, and compare.
  const lab = await browser.newPage();
  await lab.goto(new URL('privacy', url).href);
  const measure = await lab.evaluateHandle(({ moku, desk }) => {
    const crop = (w, h) => new OffscreenCanvas(w, h).getContext('2d', { willReadFrequently: true });
    const mc = crop(128, 128), dc = crop(192, 120);
    let previous = null;
    const gray = (context, w, h) => { const d = context.getImageData(0, 0, w, h).data; const g = new Float32Array(w * h); for (let i = 0; i < g.length; i++) g[i] = d[i * 4] * .3 + d[i * 4 + 1] * .59 + d[i * 4 + 2] * .11; return g; };
    const diff = (a, b) => { let s = 0; for (let i = 0; i < a.length; i++) s += Math.abs(a[i] - b[i]); return s / a.length; };
    return async (base64) => {
      const image = new Image();
      image.src = `data:image/jpeg;base64,${base64}`;
      await image.decode();
      mc.drawImage(image, moku.x, moku.y, moku.w, moku.h, 0, 0, 128, 128);
      dc.drawImage(image, desk.x, desk.y, desk.w, desk.h, 0, 0, 192, 120);
      const now = { moku: gray(mc, 128, 128), desk: gray(dc, 192, 120) };
      const result = previous ? { moku: diff(now.moku, previous.moku), desk: diff(now.desk, previous.desk) } : { moku: 0, desk: 0 };
      previous = now;
      return result;
    };
  }, boxes);
  for (const frame of frames) {
    Object.assign(frame, await lab.evaluate(([fn, data]) => fn(data), [measure, fs.readFileSync(frame.file).toString('base64')]));
  }
  const clipSpans = [];
  for (const [wall, name] of log.clips) {
    if (clipSpans.length && clipSpans.at(-1).end == null) clipSpans.at(-1).end = wall;
    if (name) clipSpans.push({ name, start: wall, end: null });
  }
  // Each clip's own frames: when each starts, and how much it changes from the last.
  const sources = {};
  for (const name of new Set(clipSpans.map(({ name: clip }) => clip))) {
    sources[name] = await lab.evaluate(async (src) => {
      const decoder = new ImageDecoder({ data: await (await fetch(src)).arrayBuffer(), type: 'image/webp' });
      await decoder.tracks.ready;
      const count = decoder.tracks.selectedTrack.frameCount;
      const context = new OffscreenCanvas(128, 128).getContext('2d', { willReadFrequently: true });
      const out = [];
      let previous = null, time = 0;
      for (let index = 0; index < count; index++) {
        const { image } = await decoder.decode({ frameIndex: index });
        context.fillStyle = '#c8d2b4';
        context.fillRect(0, 0, 128, 128);
        context.drawImage(image, 0, 0, 128, 128);
        const d = context.getImageData(0, 0, 128, 128).data, g = new Float32Array(128 * 128);
        for (let i = 0; i < g.length; i++) g[i] = d[i * 4] * .3 + d[i * 4 + 1] * .59 + d[i * 4 + 2] * .11;
        let change = 0;
        if (previous) { for (let i = 0; i < g.length; i++) change += Math.abs(g[i] - previous[i]); change /= g.length; }
        out.push({ at: time, change });
        time += image.duration / 1000;
        image.close();
        previous = g;
      }
      return out;
    }, `/motion/${name}.webp`);
  }
  await browser.close();

  // Wall time to the demo's clock, and to the clip playing then.
  const timeline = log.raf.map(([now, demo]) => [log.origin + now, demo]);
  const demoAt = (wall) => {
    let lo = 0, hi = timeline.length - 1;
    while (hi - lo > 1) { const mid = (lo + hi) >> 1; if (timeline[mid][0] <= wall) lo = mid; else hi = mid; }
    const [w0, d0] = timeline[lo], [w1, d1] = timeline[hi];
    return w1 === w0 ? d0 : d0 + (d1 - d0) * Math.min(1, Math.max(0, (wall - w0) / (w1 - w0)));
  };
  frames.forEach((frame) => {
    frame.t = demoAt(frame.wall);
    frame.clip = clipSpans.find(({ start, end }) => frame.wall >= start && (end == null || frame.wall < end));
  });

  const holds = [];
  for (let i = 1; i < frames.length; i++) {
    if (frames[i].moku > NOISE || frames[i - 1].moku <= NOISE || !frames[i].clip) continue;
    let j = i;
    while (j < frames.length && frames[j].moku <= NOISE && frames[j].clip === frames[i].clip) j++;
    if (j >= frames.length || frames[j].clip !== frames[i].clip) continue;
    const from = frames[i - 1].wall - frames[i].clip.start + 2 * VSYNC, to = frames[j].wall - frames[i].clip.start - 2 * VSYNC;
    const missed = sources[frames[i].clip.name].filter(({ at, change }) => change > NOISE * 2 && at > from && at < to);
    if (missed.length) holds.push({ t: round(frames[i].t % LOOP, 3), clip: frames[i].clip.name, heldMs: Math.round(frames[j].wall - frames[i - 1].wall), missedSourceFrames: missed.length });
    i = j;
  }

  // Window activations (instant on a Mac).
  const activations = scene.tracks.front.keys.slice(1).map(([time]) => time);
  const seams = clipSpans.flatMap(({ name, start, end }) => [{ kind: `${name} starts`, wall: start }, { kind: `${name} ends`, wall: end }]);
  for (let loop = 1; loop <= loops; loop++) {
    const at = timeline.find(([, demo]) => demo >= begin + loop * LOOP);
    if (at) seams.push({ kind: 'loop seam', wall: at[0] });
  }
  for (const { moment, wall } of switches) seams.push({ kind: moment, wall });

  // How much bigger a change looks on screen than in the source (scaling, background).
  const median = (values) => { const sorted = values.filter((v) => v > NOISE).sort((a, b) => a - b); return sorted[sorted.length >> 1] || 1; };
  const screenScale = median(frames.filter((f) => f.clip).map((f) => f.moku)) / median(Object.values(sources).flat().map(({ change }) => change));
  // The clip's own largest step around a moment, in screen terms.
  const ownStep = (frame) => {
    if (!frame.clip) return 0;
    const into = frame.wall - frame.clip.start;
    return screenScale * Math.max(0, ...sources[frame.clip.name].filter(({ at }) => Math.abs(at - into) < 70).map(({ change }) => change));
  };
  // A snap: a change three times bigger than the changes around it (within 150 ms)
  // and, for Moku, bigger than his clip moves at that moment.
  const snaps = [];
  for (const key of ['moku', 'desk']) {
    const floor = key === 'moku' ? 1 : 2.5;
    const changes = frames.filter((frame) => frame[key] > NOISE);
    changes.forEach((frame, k) => {
      const near = [changes[k - 1], changes[k + 1]].filter((other) => other && Math.abs(other.wall - frame.wall) < 150).map((other) => other[key]);
      const around = near.length ? Math.max(...near) : 0;
      if (frame[key] <= Math.max(floor, around * 3)) return;
      if (key === 'moku' && frame[key] <= ownStep(frame) * 1.6) return;  // the clip's own fastest step (a blink)
      const t = frame.t % LOOP;
      const what = seams.filter(({ wall }) => wall != null && Math.abs(wall - frame.wall) < 120).map(({ kind }) => kind);
      if (key === 'desk' && activations.some((time) => Math.abs(time - t) < .08)) what.push('window comes to the front');
      snaps.push({ t: round(t, 3), region: key, motion: round(frame[key]), around: round(around), near: what });
    });
  }
  const seamReport = seams.filter(({ kind, wall }) => wall != null && !/ends$/.test(kind)).map(({ kind, wall }) => {
    const i = frames.findIndex((frame) => frame.wall >= wall);
    if (i < 2) return null;
    const window = frames.slice(i - 2, i + 3);
    return { kind, t: round(frames[i].t % LOOP, 3), moku: window.map((f) => round(f.moku)), desk: window.map((f) => round(f.desk)) };
  }).filter(Boolean);

  const report = {
    url, loops,
    pageFrames: stats(rafGaps),
    chromiumFrames,
    screenToSourceMotion: round(screenScale),
    screencast: { ...stats(frames.slice(1).map((frame, i) => frame.wall - frames[i].wall)), note: 'capture timing, not the page’s' },
    heldFrames: holds,
    snaps,
    seams: seamReport,
    switches: switches.map(({ moment, at }) => ({ moment, t: round(at % LOOP) })),
  };
  fs.writeFileSync(path.join(output, 'report.json'), JSON.stringify(report, null, 2));
  fs.writeFileSync(path.join(output, 'frames.csv'), ['wall_ms,demo_t,moku_motion,desk_motion,clip']
    .concat(frames.map((f) => [f.wall.toFixed(1), (f.t % LOOP).toFixed(3), f.moku.toFixed(3), f.desk.toFixed(3), f.clip?.name || ''].join(','))).join('\n'));
  if (!process.env.KEEP_FRAMES) fs.rmSync(framesDir, { recursive: true, force: true });
  console.log(JSON.stringify({
    pageFrames: report.pageFrames,
    chromiumFrames: { ...chromiumFrames, dropped: chromiumFrames.dropped.length },
    heldFrames: holds.length,
    snaps: snaps.length,
    snapsAwayFromSeamsAndWindows: snaps.filter(({ near }) => !near.length).length,
  }, null, 2));
  console.log(`Details: ${path.relative(process.cwd(), output)}/report.json and frames.csv`);
})();
