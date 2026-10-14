import { plan, noteDownload } from './loading-plan.js';

const manifests = new Map();
const loaded = new Map();
export const DEFAULT_MANIFEST = '/motion/manifest.json';

// Each companion brings its own manifest of clips (companions.js).
function manifest(url) {
  if (!manifests.has(url)) {
    manifests.set(url, fetch(url).then((response) => {
      if (!response.ok) throw new Error('Motion unavailable');
      return response.json();
    }).catch((error) => { manifests.delete(url); throw error; }));
  }
  return manifests.get(url);
}

// The file this visit plays for a clip: the 640 px original, or its 320 px copy where
// the plan says so (loading-plan.js) and the export made one (export-motion.py).
export function clipFile(entry, clips = plan.clips) {
  return (clips !== 'full' && entry.variants?.[clips]) || entry;
}

// The clips the camera's close-up holds on (the sad loops, 2 s and more of a still camera): on a
// phone with a good connection they play full size, since the 320 px copies scaled 2.2x read soft
// (Charles's quality bar). About 67 KB more; the face falling and the comeback play while the
// camera moves and stay small, keeping the first loop under the phone's 1.5 MB budget. A light
// plan (Save-Data, a slow connection) keeps them all small.
const CLOSE_UP = /^disappointed-(idle|blink|slow-blink|pout)$/;
export function sizeFor(name, p = plan) {
  return p.clips !== 'full' && !p.light && CLOSE_UP.test(name) ? 'full' : p.clips;
}

// Only the clips the loop needs next (plan.ahead): a clip loaded to have it ready
// (a prefetch, in the order asked) waits its turn until fewer than `ahead` loaded
// clips of its companion are still to play. A clip asked for to play now (`play`)
// never waits, and counts as played. A clip marked for later (`later`) waits, too,
// until the loop has come round (a clip has played a second time). With `ahead` at
// Infinity (a desktop on a good connection) every clip loads at once, as before.
const windows = new Map();
function windowFor(manifestURL) {
  if (!windows.has(manifestURL)) windows.set(manifestURL, { started: 0, played: 0, plays: new Set(), round: false, later: new Set(), waiting: [] });
  return windows.get(manifestURL);
}
const due = (window, entry) => plan.ahead === Infinity || window.round || !window.later.has(entry.name);
function release(window) {
  for (let i = 0; i < window.waiting.length && window.started < plan.ahead + window.played;) {
    if (!due(window, window.waiting[i])) { i++; continue; }
    window.started++;
    window.waiting.splice(i, 1)[0].go();
  }
}
function turn(manifestURL, name, now) {
  const window = windowFor(manifestURL);
  if (now) {
    window.played++;
    if (window.plays.has(name)) window.round = true;
    window.plays.add(name);
    const queued = window.waiting.findIndex((entry) => entry.name === name);
    if (queued >= 0) { window.started++; window.waiting.splice(queued, 1)[0].go(); }
    release(window);
    return null;
  }
  const entry = { name };
  if (due(window, entry) && window.started < plan.ahead + window.played) { window.started++; return null; }
  return new Promise((go) => window.waiting.push(Object.assign(entry, { go })));
}

// Clips no loop plays (the hero's tab-leave moment, companions.js's awayClips): where
// clips load a few ahead, these wait until the loop has come round once.
export function later(manifestURL, names) {
  for (const name of names) windowFor(manifestURL).later.add(name);
}

// Set while NativeMotion.play asks for its clip: that load is for now, not ahead.
let playing = 0;

// A clip, as a blob ready to play, in the plan's size (or in `size`, for a part of the
// page that needs one: the friends' cards are bigger than the hero's corner). Asked in
// the plan's size, a clip already loaded in another size is used as it is: a plan that
// got lighter mid-visit never downloads a clip twice.
export async function loadMotion(name, manifestURL = DEFAULT_MANIFEST, size) {
  const variant = size ?? sizeFor(name);
  const key = `${manifestURL}#${name}@${variant}`;
  const now = playing > 0;
  if (!loaded.has(key) && size === undefined) {
    const other = [...loaded.keys()].find((each) => each.startsWith(`${manifestURL}#${name}@`));
    if (other) return loadMotion(name, manifestURL, other.slice(other.lastIndexOf('@') + 1));
  }
  if (!loaded.has(key)) {
    const pending = manifest(manifestURL).then(async (entries) => {
      const entry = entries[name];
      if (!entry) throw new Error(`Unknown motion: ${name}`);
      await turn(manifestURL, name, now);
      const response = await fetch(clipFile(entry, variant).url);
      if (!response.ok) throw new Error('Motion unavailable');
      const arrived = performance.now();
      const blob = await response.blob();
      noteDownload(blob.size, performance.now() - arrived);
      return { ...entry, blob };
    }).catch((error) => { loaded.delete(key); throw error; });
    loaded.set(key, pending);
  } else if (now) {
    manifest(manifestURL).then(() => turn(manifestURL, name, true)).catch(() => {});
  }
  return loaded.get(key);
}

// The stills under the clips (<mood>-idle.webp), each fetched once and then kept in
// memory. The site serves them "max-age=0, must-revalidate", so asking the network again
// on every mood change waited on a round trip to the CDN (60 ms to 5.1 s on hellomoku.com,
// 2026-10-06), and the face fell behind the loop: sad after "Back to focus".
const stills = new Map();
export function loadStill(url) {
  if (!stills.has(url)) {
    stills.set(url, fetch(url).then(async (response) => {
      if (!response.ok) throw new Error('Still unavailable');
      return URL.createObjectURL(await response.blob());
    }).catch((error) => { stills.delete(url); throw error; }));
  }
  return stills.get(url);
}

// A clip is one-shot and holds its last frame, so a short tail guarantees that
// frame has been painted before the poster (the same pose) takes over. Clips fade
// in over the poster and back out into it; where a clip's first or last frame
// differs a little from the poster (the hello's eyes), that reads as motion, not a pop.
const TAIL_MS = 40;
export const FADE_MS = 120;

export class NativeMotion {
  constructor(root, loadClip = loadMotion, posterURL = (mood) => `/motion/${mood}-idle.webp`) {
    this.root = root;
    this.art = root.querySelector('.moku-art');
    this.poster = this.art.querySelector('img');
    this.generation = 0;
    this.busy = false;
    this.loadClip = loadClip;
    this.posterURL = posterURL;
  }

  // Loads each mood's still into memory ahead of its first mood change.
  prepare(moods) {
    for (const mood of moods) loadStill(this.posterURL(mood)).catch(() => {});
  }

  async setPoster(mood) {
    if (this.retired) return;
    const generation = this.posterGeneration = (this.posterGeneration || 0) + 1;
    try {
      const url = this.posterURL(mood);
      const image = new Image();
      // Should the fetch fail, the browser may still have the still by its address.
      image.src = await loadStill(url).catch(() => url);
      await image.decode();
      if (generation !== this.posterGeneration) return;
      // The page's first still may come as a choice of sizes (index.html); from now on
      // the plan's size (companions.js) is the one shown.
      this.poster.removeAttribute('srcset');
      this.poster.removeAttribute('sizes');
      this.poster.src = image.src;
      this.poster.dataset.mood = mood;
    } catch { /* Keep the existing still if motion assets are unavailable. */ }
  }

  // Another actor takes the corner: nothing this one started, a clip or a still on its
  // way, lands there after it.
  retire() {
    this.retired = true;
    this.posterGeneration = (this.posterGeneration || 0) + 1;
    this.cancel();
  }

  // Ends a clip by fading it into the poster beneath, which is the next pose.
  finish() {
    const overlay = this.overlay, url = this.objectURL;
    this.overlay = null;
    this.objectURL = null;
    this.cancel();
    if (!overlay) return;
    overlay.classList.add('is-leaving');
    setTimeout(() => { overlay.remove(); if (url) URL.revokeObjectURL(url); }, FADE_MS);
  }

  cancel() {
    this.generation++;
    clearTimeout(this.endTimer);
    this.overlay?.remove();
    this.overlay = null;
    if (this.objectURL) URL.revokeObjectURL(this.objectURL);
    this.objectURL = null;
    this.busy = false;
    this.name = null;
    this.root.classList.remove('is-playing');
    delete this.root.dataset.motion;
  }

  async play(name, { hold = false, onFinish } = {}) {
    // Keep the previous pose on screen while the next clip loads and decodes.
    // Removing it here flashes the neutral poster between hover-in/hover-out.
    const generation = ++this.generation;
    clearTimeout(this.endTimer);
    this.busy = true;
    this.name = name;
    let pendingURL;
    try {
      playing++;
      let loading;
      try { loading = this.loadClip(name); } finally { playing--; }
      const clip = await loading;
      if (generation !== this.generation) return false;
      // A fresh object URL restarts a cached, one-shot WebP without a network
      // cache-buster. Native browser decoding preserves alpha and frame timing.
      const url = URL.createObjectURL(clip.blob);
      pendingURL = url;
      const frame = new Image();
      frame.className = 'companion-motion';
      frame.alt = '';
      frame.setAttribute('aria-hidden', 'true');
      frame.draggable = false;
      frame.src = url;
      await frame.decode();
      if (generation !== this.generation) { URL.revokeObjectURL(url); return false; }
      this.overlay?.remove();
      if (this.objectURL) URL.revokeObjectURL(this.objectURL);
      this.objectURL = url;
      this.overlay = frame;
      this.art.append(frame);
      this.root.classList.add('is-playing');
      this.root.dataset.motion = name;
      // The clip's time is up: the companion is free for the loop's next moment at once.
      // Its last frame holds until the still beneath shows the same pose.
      this.endTimer = setTimeout(async () => {
        if (generation !== this.generation) return;
        this.busy = false;
        await onFinish?.();
        if (generation === this.generation && !hold) this.finish();
      }, clip.duration + TAIL_MS);
      return true;
    } catch {
      if (pendingURL && pendingURL !== this.objectURL) URL.revokeObjectURL(pendingURL);
      if (generation === this.generation) { this.cancel(); onFinish?.(); }
      return false; // The original still image remains usable on a slow connection.
    }
  }
}
