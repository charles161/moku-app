// How this visit loads the heavy things: the companion's clips, the house's 3D and its
// renders (docs/specs/next-0-1-9.md §3). Decided from the screen and the connection:
// navigator.connection where the browser has it (Chrome, Edge, Android), elsewhere
// (Safari, Firefox) from what the first downloads measured. A plan only gets lighter
// during a visit, never heavier, so nothing already on screen is swapped for more.
//
// The hero's hook (live-demo.js reads it; nothing else is needed from the hero):
//   plan.light     Save-Data or a slow connection. Tell the story in stills first:
//                  start the loop at once rather than waiting for the first clips, and
//                  never hold a beat for a clip still on its way; clips take over as
//                  they arrive (the actor already shows a mood's still for a clip that
//                  isn't ready).
//   plan.clips     'full' (the 640 px originals) or '320' (the half-size copies).
//                  native-motion.js picks the file; the hero needs nothing for it.
//   plan.ahead     how many clips load ahead of the ones playing (native-motion.js
//                  keeps to it; Infinity loads them all at once, as before).
//   onPlanChange(fn)  runs fn(plan) when a measurement makes the plan lighter.

// Below this, a connection is slow: 1.5 Mbps is a fifth of a 4G link, about slow 3G's best.
export const SLOW_MBPS = 1.5;
const SLOW_TYPES = new Set(['slow-2g', '2g', '3g']);
// Clips ahead of the ones playing, when not all at once: the first beat's, and the next.
export const AHEAD = 3;
// A download smaller than this says more about the round trip than the bandwidth.
export const MEASURABLE_BYTES = 24 * 1024;
// The phones: the hero's companion shows about 320 device pixels in the wide shot.
export const PHONE_QUERY = '(max-width: 599px), (max-height: 499px)';

// The plan for a screen and a connection. `measuredMbps` counts only where the browser
// can't say (no navigator.connection).
export function choosePlan({ phone = false, saveData = false, effectiveType, downlink, measuredMbps } = {}) {
  const slow = Boolean(saveData) || SLOW_TYPES.has(effectiveType)
    || (downlink > 0 && downlink < SLOW_MBPS) || (measuredMbps > 0 && measuredMbps < SLOW_MBPS);
  return Object.freeze({
    clips: phone || slow ? '320' : 'full',
    light: slow,
    ahead: phone || slow ? AHEAD : Infinity,
    // The house's 3D (three.js) waits for a tap on a slow connection; elsewhere it loads near its section.
    house3d: slow ? 'tap' : 'auto',
    reason: saveData ? 'save-data' : slow ? 'slow' : phone ? 'phone' : 'full',
  });
}

// Megabits a second for `bytes` of a body that took `ms` from its first byte to its last
// (the round trip before the first byte says nothing about the bandwidth).
export const mbps = (bytes, ms) => bytes * 8 / 1000 / ms;

// The best rate the page's own early downloads (the CSS, the script, the fonts) showed,
// from Resource Timing, or undefined when none was big enough to say. A body that came
// in one burst (no time between its first and last byte) was fast.
export function earlyMbps(entries) {
  const rates = entries.filter((entry) => entry.encodedBodySize >= MEASURABLE_BYTES && entry.responseStart > 0)
    .map((entry) => entry.responseEnd > entry.responseStart ? mbps(entry.encodedBodySize, entry.responseEnd - entry.responseStart) : Infinity);
  return rates.length ? Math.max(...rates) : undefined;
}

const browser = typeof window !== 'undefined';
const connection = () => (browser ? navigator.connection : undefined);
const phone = browser && typeof matchMedia === 'function' && matchMedia(PHONE_QUERY).matches;
let measured = browser && !connection() && typeof performance !== 'undefined'
  ? earlyMbps(performance.getEntriesByType?.('resource') ?? [])
  : undefined;
const listeners = new Set();

function current() {
  const info = connection();
  return choosePlan(info
    ? { phone, saveData: info.saveData, effectiveType: info.effectiveType, downlink: info.downlink }
    : { phone, measuredMbps: measured });
}

const weight = (p) => [p.clips === 'full' ? 1 : 0, p.light ? 0 : 1, p.ahead === Infinity ? 1 : 0, p.house3d === 'auto' ? 1 : 0];
const lighter = (next, than) => {
  const a = weight(next), b = weight(than);
  return a.every((value, i) => value <= b[i]) && a.some((value, i) => value < b[i]);
};

export let plan = current();

function show() {
  if (!browser) return;
  document.documentElement.dataset.clips = plan.clips;
  document.documentElement.dataset.loading = plan.light ? 'light' : 'full';
}
show();

function update() {
  const next = current();
  if (!lighter(next, plan)) return;
  plan = next;
  show();
  for (const listener of listeners) listener(plan);
}

// A download's size and the time its body took: where the browser can't say what its
// connection is, a slow one lowers the plan for what's still to come.
export function noteDownload(bytes, ms) {
  if (connection() || bytes < MEASURABLE_BYTES || !(ms > 0)) return;
  const rate = mbps(bytes, ms);
  measured = measured === undefined ? rate : Math.min(measured, rate);
  update();
}

export function onPlanChange(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

connection()?.addEventListener?.('change', update);
