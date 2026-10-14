// The hero in sync, without a browser: the companion's real actor (demo-actor.js) and
// its real motion (native-motion.js) play the loop on a simulated clock, over a
// simulated network, and every frame the face on screen is checked against what the
// loop says then: the state over the desk, the window in front and the camera
// (demo-timeline.js). Every kind of work, both companions, the first loop and a later
// one, on two kinds of visit:
//   desktop  every clip arrives before it's needed;
//   light    no clip arrives during the first loop, so stills stand in (loading-plan.js).
// The network is hellomoku.com's as measured on 2026-10-06: a still (/motion/<mood>-idle.webp)
// is served "max-age=0, must-revalidate", so each time the page asks for it again it waits
// for a round trip to the CDN, which took from 60 ms to 5.1 s while the loop played.
// Here that round trip takes ROUND_TRIP; what's already in memory (a blob: URL) takes none.
import test, { mock } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { LOOP, cues, scenes, sceneOrder, captionAt, captionText, sceneAt, cameraAt, CAMERA, WORK_FRONT } from './demo-timeline.js';
import { companions } from './companions.js';
import { CompanionActor, LATE } from './demo-actor.js';
import { loadMotion } from './native-motion.js';

const ROUND_TRIP = 2.5;
const FRAME_MS = 10;
// Slack for a frame and the browser's timers.
const SLACK = .3;
const manifests = Object.fromEntries(Object.values(companions).map((companion) => [companion.motion.manifest, JSON.parse(readFileSync(new URL(`../public${companion.motion.manifest}`, import.meta.url)))]));
const seconds = (companion, clip) => manifests[companion.motion.manifest][clip].duration / 1000;

// The browser, as far as the actor and its motion use it.
let clock = 0;
const wait = (s) => new Promise((resolve) => (s > 0 ? setTimeout(resolve, s * 1000) : resolve()));
const costOf = (url) => (url.startsWith('blob:') ? 0 : /-idle(\.\d+)?\.webp/.test(url) ? ROUND_TRIP : .05);
const classes = () => {
  const names = new Set();
  return { add: (...n) => n.forEach((each) => names.add(each)), remove: (...n) => n.forEach((each) => names.delete(each)), toggle: (n, on = !names.has(n)) => (on ? names.add(n) : names.delete(n), on), contains: (n) => names.has(n) };
};
class FakeImage {
  constructor() { this.attributes = {}; this.dataset = {}; this.classList = classes(); this.loaded = Promise.resolve(); }
  set src(url) { this.attributes.src = url; this.loaded = wait(costOf(url)); }
  get src() { return this.attributes.src; }
  getAttribute(name) { return this.attributes[name] ?? null; }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  removeAttribute(name) { delete this.attributes[name]; }
  decode() { return this.loaded; }
  remove() { this.parent?.children.splice(this.parent.children.indexOf(this), 1); this.parent = null; }
}
let blobs = 0;
function installBrowser() {
  const saved = { Image: globalThis.Image, fetch: globalThis.fetch, create: URL.createObjectURL, revoke: URL.revokeObjectURL };
  globalThis.Image = FakeImage;
  globalThis.fetch = async (url) => {
    await wait(costOf(url));
    return { ok: true, json: async () => manifests[url], blob: async () => ({ size: 1000, url }) };
  };
  // A blob: URL that still says what it holds, so the face can be read off it.
  URL.createObjectURL = (blob) => `blob:${++blobs}#${blob.url}`;
  URL.revokeObjectURL = () => {};
  return () => { Object.assign(globalThis, { Image: saved.Image, fetch: saved.fetch }); URL.createObjectURL = saved.create; URL.revokeObjectURL = saved.revoke; };
}

// The companion's corner, as index.html has it, and what it shows.
function corner(companion) {
  const poster = new FakeImage();
  poster.src = companion.motion.poster(companion.restingMood);
  const art = { children: [poster], querySelector: () => poster, append(node) { node.parent = art; art.children.push(node); } };
  const shown = { clip: null, since: 0 };
  const dataset = new Proxy({}, {
    set(target, key, value) { if (key === 'motion') Object.assign(shown, { clip: value, since: clock }); target[key] = value; return true; },
    deleteProperty(target, key) { if (key === 'motion') shown.clip = null; delete target[key]; return true; },
  });
  const root = { classList: classes(), dataset, querySelector: () => art };
  // A clip's mood, or either end of a turn by how far it has got (null mid-turn); else the still's.
  const face = () => {
    if (!shown.clip) return /(\w+)-idle/.exec(poster.src)?.[1];
    const turn = /^(\w+)-to-(\w+)$/.exec(shown.clip);
    if (!turn) return shown.clip.split('-')[0];
    const progress = (clock - shown.since) / seconds(companion, shown.clip);
    return progress < .4 ? turn[1] : progress >= .6 ? turn[2] : null;
  };
  return { root, face, shown, still: () => /(\w+)-idle/.exec(poster.src)?.[1] };
}

const flush = () => new Promise((resolve) => setImmediate(resolve));
async function advance(s) {
  for (let ms = 0; ms < s * 1000; ms += FRAME_MS) {
    clock += FRAME_MS / 1000;
    mock.timers.tick(FRAME_MS);
    await flush();
  }
}

// The moods the loop allows at t: its mood, and either side of a turn while it plays.
function moodsAt(companion, t) {
  let mood = companion.restingMood;
  const allowed = new Set();
  for (const cue of cues) {
    const moment = companion.moments[cue.moment];
    if (!moment?.to) continue;
    const end = cue.at + seconds(companion, moment.clip);
    if (t >= cue.at - .05 && t < end + SLACK) allowed.add(moment.from).add(moment.to);
    if (t >= (cue.at + end) / 2) mood = moment.to;
  }
  return allowed.add(mood);
}

// Plays two loops of one kind of work with one companion, frame by frame, and returns
// every moment the face, the state over the desk, the window and the camera disagree.
async function play(work, companion, visit) {
  const scene = scenes[work], loops = ['first', 'later'];
  const { root, face, shown, still } = corner(companion);
  // The page opens: the clips load in the loop's order, and the loop starts a moment later.
  const arrived = new Set();
  for (const clip of Object.keys(manifests[companion.motion.manifest]).filter((name) => !/-idle$/.test(name))) {
    loadMotion(clip, companion.motion.manifest).then(() => arrived.add(clip));
  }
  const actor = new CompanionActor(root, companion, {
    // On a light visit no clip arrives during the first loop: its stills stand in.
    isReady: (clip) => !clip || (arrived.has(clip) && (visit === 'desktop' || clock - start >= LOOP)),
  });
  await advance(3);
  const start = clock;
  const found = [];
  let stale = null, cheered = new Set();
  for (let elapsed = 0; elapsed < loops.length * LOOP; elapsed = clock - start) {
    actor.update(elapsed);
    const loop = Math.floor(elapsed / LOOP), t = elapsed - loop * LOOP;
    const shows = face(), caption = captionAt(t), front = sceneAt(scene, t).values.front, zoom = cameraAt(t);
    const label = caption && caption.opacity > .05 ? captionText(caption.id, { companion, scene }).word : '';
    const flag = (rule) => found.push({ loop: loops[loop], t, rule });
    const say = `${shows ?? 'mid-turn'} face, "${label || 'no label'}" up, ${front} in front`;
    const allowed = moodsAt(companion, t);
    if (shows && !allowed.has(shows)) flag(`${say}: the loop has it ${[...allowed].join(' or ')}`);
    if (shows === 'disappointed' && label === 'Back to focus') flag('sad while "Back to focus" is up');
    if (label === `${companion.name} noticed` && shows !== 'disappointed') flag(`${say}: not sad while "${companion.name} noticed" is up`);
    if (label === 'Back to focus' && front !== scene.work) flag(`"Back to focus" over ${front}`);
    if (label === 'Drifting' && front !== 'browser') flag(`"Drifting" over ${front}`);
    if (zoom > .999 && front !== 'browser' && !(t >= WORK_FRONT && t < WORK_FRONT + SLACK)) flag(`the close-up holds over ${front}`);
    if (t > WORK_FRONT + SLACK && t < CAMERA.pullBack[1] && zoom > .999) flag('the camera hasn’t pulled back with the return');
    if (shown.clip === 'happy-head' && !cheered.has(loop)) {
      cheered.add(loop);
      const late = shown.since - start - loop * LOOP - cues.find((cue) => cue.moment === 'cheer').at;
      if (Math.abs(late) > LATE) flag(`the cheer starts ${late.toFixed(2)} s off the piece`);
    }
    if (!shown.clip && still() !== actor.mood) {
      stale ??= clock;
      if (clock - stale > SLACK) flag(`the still shows ${still()}, ${companion.name} is ${actor.mood}`);
    } else stale = null;
    await advance(FRAME_MS / 1000);
  }
  actor.freeze();
  // Consecutive frames with the same rule read as one span.
  const spans = [];
  for (const each of found) {
    const span = spans.find((s) => s.rule === each.rule && s.loop === each.loop && each.t - s.to <= .05);
    if (span) span.to = each.t; else spans.push({ loop: each.loop, from: each.t, to: each.t, rule: each.rule });
  }
  return spans.map(({ loop, from, to, rule }) => `${work} × ${companion.id} (${visit}), ${loop} loop, ${from.toFixed(2)}–${to.toFixed(2)} s: ${rule}`);
}

for (const visit of ['desktop', 'light']) {
  test(`the hero in sync on a ${visit} visit: the face, the state over the desk, the window and the camera, every frame`, async () => {
    mock.timers.enable({ apis: ['setTimeout', 'setInterval'] });
    const restore = installBrowser();
    try {
      const failures = [];
      for (const work of sceneOrder) {
        for (const companion of Object.values(companions)) failures.push(...await play(work, companion, visit));
      }
      assert.deepEqual(failures, [], `${failures.length} moments out of sync:\n  ${failures.join('\n  ')}`);
    } finally {
      restore();
      mock.timers.reset();
    }
  });
}
