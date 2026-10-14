// Vercel's Web Analytics and Speed Insights for hellomoku.com (privacy.html, "This website"). Web Analytics counts page
// views in Vercel's dashboard; Speed Insights measures how fast pages load and answer for real visitors. Both scripts
// come from hellomoku.com itself (/_vercel/…), so the CSP's 'self' covers them, and they start only once the page has
// loaded, so the hero never waits on them (Speed Insights still reads the load's timings, which the browser keeps).
// The visit counter's rule applies: only on hellomoku.com, and nothing at all when the browser asks not to be tracked.

import { inject } from '@vercel/analytics';
import { injectSpeedInsights } from '@vercel/speed-insights';
import { optedOut, SITES } from './visits.js';

// The script and intake addresses Vercel picks for a build (its Resilient Intake), when its build sets them
// (vite.config.js). Without them both packages use the standard /_vercel/ addresses.
const CONFIG = typeof __VERCEL_OBSERVABILITY__ === 'string' ? __VERCEL_OBSERVABILITY__ : undefined;

function injectBoth() {
  inject({ mode: 'production' }, CONFIG);
  injectSpeedInsights({}, CONFIG);
}

/** Vercel measures this page: it's hellomoku.com, and the browser hasn't asked not to be tracked. */
export function measured(win) {
  return SITES.has(win.location.hostname) && !optedOut(win.navigator);
}

/** Starts both once the page has loaded. Returns whether they will start. */
export function startVercelInsights(win, start = injectBoth) {
  if (!measured(win)) return false;
  if (win.document.readyState === 'complete') start();
  else win.addEventListener('load', () => start(), { once: true });
  return true;
}

if (typeof window !== 'undefined') startVercelInsights(window);
