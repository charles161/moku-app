// Checks that the hero stays in sync: the companion's face, the state over the desk,
// the window in front and the camera, sampled every 100 ms of the live page in headless
// Chromium through two loops, for every kind of work and companion.
//
//   npm run check:sync                                   builds, serves dist/ on 127.0.0.1:5195, checks, stops
//   node scripts/check-sync.cjs [url]                    checks a running server instead
//   node scripts/check-sync.cjs --only writing:moku:light,code:tetsu:desktop
//
// Profiles:
//   desktop   1440×900, no throttling: every clip there before it's needed
//   light     1440×900 on slow 3G (400 kbps, 400 ms): the light plan, where clips arrive late
//             and stills stand in for them (loading-plan.js)
//   phone     390×844 on 4G: half-size clips, loaded a few ahead of the loop
//   cdn       1440×900 with hellomoku.com's timing for stills: they're served "max-age=0,
//             must-revalidate", and asking for one again took 60 ms to 5.1 s there on
//             2026-10-06; here every repeat request for a still waits 2.5 s
//   picks     1440×900, starting on writing, the visitor picks each other kind of work and
//             the other companion at different points of the loop (picks: a run per companion)
//
// What the face shows is read off the page: the clip on screen (data-motion), how far into
// it, or the still under it. It must agree with the loop (demo-timeline.js):
//   - content while working, sad only from the companion's notice until the work window is
//     back, happy from the comeback to the settle, never sad once "Back to focus" is up;
//   - sad while the "noticed" label is up;
//   - the label agrees with the window in front ("Back to focus" over the work, "Drifting"
//     over the feed) and the camera (the close-up only over the drift);
//   - the camera pulls back as the work comes back, the cheer starts with the piece landing;
//   - the still under a clip is the companion's mood, never a stale one.
// A mismatch exits 1 and names the kind of work, the companion, the loop and the time.
// Samples land in review/sync/<work>-<companion>-<profile>.json (ignored by git).
const fs = require('node:fs');
const path = require('node:path');
const { playwright, preview } = require('./preview.cjs');

const args = process.argv.slice(2);
const flag = (name) => { const i = args.indexOf(name); return i < 0 ? null : args.splice(i, 2)[1]; };
const only = flag('--only')?.split(',');
const parallel = Number(flag('--parallel') ?? 8);
const PORT = 5195;
const given = args.find((arg) => /^https?:/.test(arg));
const LOOPS = 2;

const kbps = (n) => n * 1000 / 8;
const profiles = {
  desktop: { context: { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 }, network: null },
  light: { context: { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 }, network: { downloadThroughput: kbps(400), uploadThroughput: kbps(400), latency: 400 } },
  phone: { context: { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true }, network: { downloadThroughput: kbps(9000), uploadThroughput: kbps(1500), latency: 165 } },
  cdn: { context: { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 }, network: null, stillAgain: 2500 },
};
// The picks: in the sad hold, mid-comeback, at the cheer, at the settle (the other
// companion), and mid-turn to sad; each pick starts the next loop just before its hello.
const picks = (other) => ({
  work: 'writing', profile: 'picks', loops: 10,
  steps: [{ at: 14.8, work: 'design' }, { at: 40, work: 'code' }, { at: 91.5, work: 'study' }, { at: 142.5, companion: other }, { at: 180, work: 'writing' }],
});

// In the page: a sample per 100 ms of the loop playing, read off what's on screen.
function sampler() {
  window.__samples = [];
  let last = -Infinity, clip = null, clipStart = 0;
  const tick = (now) => {
    requestAnimationFrame(tick);
    const root = document.querySelector('.live-demo');
    const demo = root?.liveDemo;
    const corner = document.querySelector('.desk-moku');
    if (!demo || !corner) return;
    // When the clip on screen changed, to the frame.
    const playing = corner.dataset.motion || null;
    if (playing !== clip) { clip = playing; clipStart = now; }
    if (!demo.running || now - last < 100) return;
    last = now;
    const label = document.querySelector('[data-state-label]');
    const opacity = Number(label?.style.opacity || 0);
    // The still's mood: a still kept in memory says it (data-mood); the page's first one by its address.
    const poster = corner.querySelector('.moku-art > img:first-child');
    window.__samples.push({
      now, elapsed: demo.elapsed, scene: demo.scene, companion: demo.companion, front: document.querySelector('.scene.is-active')?.dataset.front,
      label: opacity > .05 ? label.querySelector('[data-state-word]')?.textContent ?? '' : '', opacity,
      clip, clipAge: clip ? now - clipStart : 0, still: poster?.dataset.mood ?? /(\w+)-idle/.exec(poster?.getAttribute('src') ?? '')?.[1] ?? null,
      mood: demo.actor.mood, zoom: demo.zoom, held: demo.held, switching: root.classList.contains('is-switching'),
      landing: Boolean(document.querySelector('[data-piece-tag].is-landing')),
    });
  };
  requestAnimationFrame(tick);
}

// A scenario's steps run at loop times: another kind of work or companion picked as a
// visitor would, the tab hidden and shown, the pointer off the page and back.
async function act(page, step) {
  await page.waitForFunction((at) => document.querySelector('.live-demo').liveDemo.elapsed >= at, step.at, { timeout: 180000, polling: 'raf' });
  await page.evaluate(({ work, companion, tab, pointer }) => {
    if (work) [...document.querySelectorAll('.work-tab')].find((node) => node.dataset.work === work).click();
    if (companion) document.querySelector(`[data-companion="${companion}"]:not(html)`).click();
    if (tab) {
      const hidden = tab === 'hide';
      Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => (hidden ? 'hidden' : 'visible') });
      Object.defineProperty(document, 'hidden', { configurable: true, get: () => hidden });
      document.dispatchEvent(new Event('visibilitychange'));
    }
    if (pointer === 'out') document.dispatchEvent(new MouseEvent('mouseout', { relatedTarget: null, bubbles: true }));
    if (pointer === 'in') document.body.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
  }, step);
  if (step.wait) await page.waitForTimeout(step.wait);
}

async function run(browser, base, { work, companion, profile, steps = [], loops = LOOPS }) {
  const { context: options, network, stillAgain } = profiles[profile] ?? profiles.desktop;
  const context = await browser.newContext(options);
  if (stillAgain) {
    const asked = new Set();
    await context.route(/-idle(\.\d+)?\.webp/, async (route) => {
      const url = route.request().url();
      if (asked.has(url)) await new Promise((resolve) => setTimeout(resolve, stillAgain));
      asked.add(url);
      await route.continue().catch(() => {});
    });
  }
  const page = await context.newPage();
  const cdp = await context.newCDPSession(page);
  await cdp.send('Network.enable');
  if (network) await cdp.send('Network.emulateNetworkConditions', { offline: false, ...network });
  await page.addInitScript(sampler);
  let error = null;
  page.on('crash', () => { error ??= 'the page crashed'; });
  await page.goto(`${base}?work=${work}&companion=${companion}`, { waitUntil: 'load', timeout: 120000 });
  await page.waitForFunction(() => document.querySelector('.live-demo').liveDemo?.running, null, { timeout: 60000 });
  try {
    for (const step of steps) await act(page, step);
    await page.waitForFunction((end) => document.querySelector('.live-demo').liveDemo.elapsed >= end, loops * 24, { timeout: 180000, polling: 250 });
  } catch (caught) {
    error = caught.message.split('\n')[0];
  }
  const read = (fn, fallback) => page.evaluate(fn).catch(() => fallback);
  const samples = await read(() => window.__samples, []);
  const plan = await read(() => `${document.documentElement.dataset.loading}/${document.documentElement.dataset.clips}`, '?');
  await context.close().catch(() => {});
  return { work, companion, profile, plan, samples, error };
}

(async () => {
  const timeline = await import(path.resolve(__dirname, '../src/demo-timeline.js'));
  const { companions, momentsFor } = await import(path.resolve(__dirname, '../src/companions.js'));
  const { LATE } = await import(path.resolve(__dirname, '../src/demo-actor.js'));
  const { LOOP, cues, cueRuns, scenes, sceneOrder, CAMERA, WORK_FRONT, PIECE_LANDS } = timeline;
  const manifests = Object.fromEntries(Object.values(companions).map((c) => [c.id, JSON.parse(fs.readFileSync(path.resolve(__dirname, `../public${c.motion.manifest}`), 'utf8'))]));
  const seconds = (companion, clip) => manifests[companion][clip].duration / 1000;

  // Slack for timers, a frame and the 100 ms between samples.
  const TOLERANCE = .3;
  // What the face shows: a clip's mood, its start or end mood by how far a turn has got
  // (null mid-turn, when it's both), or the still's.
  function faceOf(sample) {
    if (!sample.clip) return sample.still;
    const turn = /^(\w+)-to-(\w+)$/.exec(sample.clip);
    if (!turn) return sample.clip.split('-')[0];
    const progress = sample.clipAge / 1000 / seconds(sample.companion, sample.clip);
    return progress < .4 ? turn[1] : progress >= .6 ? turn[2] : null;
  }
  // The moods the loop allows at t: its mood, and either side of a turn while it plays.
  function moodsAt(companion, t) {
    let mood = companions[companion].restingMood;
    const allowed = new Set();
    for (const cue of cues) {
      const moment = companions[companion].moments[cue.moment];
      if (!moment?.to) continue;
      const end = cue.at + seconds(companion, moment.clip);
      if (t >= cue.at - .05 && t < end + TOLERANCE) allowed.add(moment.from).add(moment.to);
      if (t >= cue.at + (end - cue.at) / 2) mood = moment.to;
    }
    return allowed.add(mood);
  }
  const cheer = cues.find((cue) => cue.moment === 'cheer').at;

  // Every mismatch in a run's samples, as spans of time.
  function mismatches(samples, end) {
    const found = [];
    const flag = (sample, rule) => found.push({ loop: sample.loop, t: sample.t, rule });
    let stale = null, previous = null, jumped = -Infinity;
    const cheered = new Set(), landed = new Set();
    for (const sample of samples) {
      sample.loop = Math.floor(sample.elapsed / LOOP);
      sample.t = sample.elapsed - sample.loop * LOOP;
      // Held (the visitor has gone) or mid-pick (the screen and the corner faded out), the loop isn't on show.
      if (sample.elapsed >= end || sample.held || sample.switching) { previous = null; continue; }
      // A pick or a welcome back moves the loop on: the camera eases to it on its own.
      if (!previous || Math.abs(sample.elapsed - previous.elapsed) > 1 || sample.companion !== previous.companion) jumped = sample.now;
      const { t, label, front, companion } = sample, face = sample.face = faceOf(sample);
      const scene = scenes[sample.scene], name = companions[companion].name, settled = sample.now - jumped > 1000;
      const say = `${face ?? 'mid-turn'} face, "${label || 'no label'}" up, ${front} in front`;
      // The face against the loop.
      const allowed = moodsAt(companion, t);
      if (face && !allowed.has(face)) flag(sample, `${say}: the loop has it ${[...allowed].join(' or ')}`);
      if (face === 'disappointed' && label === 'Back to focus') flag(sample, 'sad while "Back to focus" is up');
      if (label === `${name} noticed` && face !== 'disappointed') flag(sample, `${say}: not sad while "${name} noticed" is up`);
      // The label against the window in front and the camera.
      if (label === 'Working' && front === 'browser') flag(sample, '"Working" over the feed');
      if (label === 'Drifting' && front !== 'browser') flag(sample, `"Drifting" over ${front}`);
      if (label === `${name} noticed` && (front !== 'browser' || sample.zoom < .99)) flag(sample, `"${name} noticed" outside the drift's close-up`);
      if (label === 'Back to focus' && front !== scene.work) flag(sample, `"Back to focus" over ${front}`);
      if (settled && sample.zoom > .999 && front !== 'browser' && !(t >= WORK_FRONT && t < WORK_FRONT + TOLERANCE)) flag(sample, `the close-up holds over ${front}`);
      if (settled && t > WORK_FRONT + TOLERANCE && t < CAMERA.pullBack[1] && sample.zoom > .999) flag(sample, 'the camera hasn’t pulled back after the return');
      if (settled && previous && previous.zoom > .999 && sample.zoom <= .999 && t > CAMERA.pushIn[1] && Math.abs(t - WORK_FRONT) > TOLERANCE) flag(sample, `the camera pulls back at ${t.toFixed(2)} s, not with the return (${WORK_FRONT} s)`);
      // The cheer with the piece.
      if (sample.clip === 'happy-head' && !cheered.has(sample.loop)) {
        cheered.add(sample.loop);
        const start = t - sample.clipAge / 1000;
        if (Math.abs(start - cheer) > LATE) flag(sample, `the cheer starts at ${start.toFixed(2)} s, not with the piece (${cheer}–${PIECE_LANDS} s)`);
      }
      if (sample.landing && !landed.has(sample.loop)) {
        landed.add(sample.loop);
        if (face !== 'happy') flag(sample, `the piece lands with a ${face ?? 'mid-turn'} face`);
      }
      // The still under the clips is the companion's mood, within a moment.
      if (!sample.clip && sample.still !== sample.mood) {
        stale ??= sample;
        if (sample.now - stale.now > TOLERANCE * 1000) flag(sample, `the still shows ${sample.still}, ${name} is ${sample.mood}`);
      } else stale = null;
      previous = sample;
    }
    // Consecutive samples with the same rule read as one span.
    const spans = [];
    for (const each of found) {
      const span = spans.find((s) => s.rule === each.rule && s.loop === each.loop && each.t - s.to <= .25);
      if (span) span.to = each.t; else spans.push({ loop: each.loop, from: each.t, to: each.t, rule: each.rule });
    }
    return spans;
  }

  const ids = Object.keys(companions);
  const runs = sceneOrder.flatMap((work) => ids.flatMap((companion) => Object.keys(profiles).map((profile) => ({ work, companion, profile }))))
    .concat(ids.map((companion) => ({ companion, ...picks(ids.find((id) => id !== companion)) })))
    .filter(({ work, companion, profile }) => !only || only.some((pick) => {
      const [w, c, p] = pick.split(':');
      return (!w || w === work) && (!c || c === companion) && (!p || p === profile);
    }));
  const scenario = flag('--scenario');
  if (scenario) runs.forEach((each) => Object.assign(each, JSON.parse(scenario)));

  const server = given ? null : await preview(PORT);
  const base = given ?? server.url;
  const { chromium } = playwright();
  const browser = await chromium.launch();
  const results = [];
  try {
    for (let i = 0; i < runs.length; i += parallel) {
      results.push(...await Promise.all(runs.slice(i, i + parallel).map((each) => run(browser, base, each))));
    }
  } finally {
    await browser.close();
    await server?.close();
  }

  const output = path.resolve(__dirname, '../review/sync');
  fs.mkdirSync(output, { recursive: true });
  const failures = [];
  results.forEach(({ work, companion, profile, plan, samples, error }, i) => {
    const spans = mismatches(samples, (runs[i].loops ?? LOOPS) * LOOP);
    if (error) spans.unshift({ loop: 0, from: 0, to: 0, rule: `the run stopped: ${error}` });
    fs.writeFileSync(path.join(output, `${work}-${companion}-${profile}.json`), JSON.stringify({ ...runs[i], plan, spans, samples }, null, 1));
    console.log(`${`${work} ${companion} ${profile}`.padEnd(24)} ${plan.padEnd(11)} ${String(samples.length).padStart(4)} samples  ${spans.length ? `${spans.length} mismatch${spans.length === 1 ? '' : 'es'}` : 'in sync'}`);
    for (const span of spans) {
      const sample = samples.find((each) => each.loop === span.loop && each.t === span.from) ?? { scene: work, companion };
      const line = `${sample.scene} × ${sample.companion} (${profile}), loop ${span.loop + 1}, ${span.from.toFixed(1)}${span.to > span.from ? `–${span.to.toFixed(1)}` : ''} s: ${span.rule}`;
      console.log(`  ${line}`);
      failures.push(line);
    }
  });
  console.log(`\nSamples: ${path.relative(process.cwd(), output)}/`);
  if (failures.length) {
    console.log(`\n${failures.length} mismatch${failures.length === 1 ? '' : 'es'}.`);
    process.exitCode = 1;
  } else console.log('\nEverything in sync.');
})().catch((error) => { console.error(error); process.exitCode = 1; });
