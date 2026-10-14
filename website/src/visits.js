// Counting visits to hellomoku.com without cookies (privacy.html, "This website"). Each page view gets a new random id,
// kept only in the page's memory: no cookie, no storage, nothing that ties one visit to another. Four events, each one
// beacon to the relay (proxy/api/_lib/web-visits.js), which checks every field and passes them on to PostHog: the page
// view (the page, the link's ?ref= or utm_source, the site that linked here, and phone, tablet or computer), leaving
// it (seconds on it, seconds it was in view, how far down it was read), a download button pressed (which one), and a
// companion picked. Only on hellomoku.com, and nothing at all when the browser asks not to be tracked (Global Privacy
// Control or Do Not Track). The download buttons carry the visit's ref to /download, where the relay counts downloads.

export const ENDPOINT = 'https://moku-proxy.vercel.app/v1/web-visit';
export const SITES = new Set(['hellomoku.com', 'www.hellomoku.com']);
export const MAX_PER_PAGE = 20;

/** A UUIDv7 (the time in milliseconds, then random bits): PostHog reads sessions only from one. */
export function viewId(now = Date.now(), random = crypto.getRandomValues(new Uint8Array(10))) {
  const time = now.toString(16).padStart(12, '0').slice(-12);
  const hex = Array.from(random, (byte) => byte.toString(16).padStart(2, '0')).join('');
  const variant = ((parseInt(hex[3], 16) & 0x3) | 0x8).toString(16);
  return `${time.slice(0, 8)}-${time.slice(8)}-7${hex.slice(0, 3)}-${variant}${hex.slice(4, 7)}-${hex.slice(7, 19)}`;
}

/** The word a link brought (?ref= or ?utm_source=), in lower-case letters, digits and _: "x.com" is "x_com". */
export function refOf(search) {
  const params = new URLSearchParams(search);
  const word = (params.get('ref') || params.get('utm_source') || '').toLowerCase()
    .replace(/[^a-z0-9_]+/g, '_').replace(/^[^a-z]+/, '').slice(0, 32);
  return word || undefined;
}

/** The site that linked here, by its host name; none for no referrer, our own site, or anything not a web address. */
export function fromOf(referrer, ownHost) {
  try {
    const { protocol, hostname } = new URL(referrer);
    return /^https?:$/.test(protocol) && hostname !== ownHost && !SITES.has(hostname) ? hostname : undefined;
  } catch {
    return undefined;
  }
}

/** Phone, tablet or computer: a touch screen is a phone when its shorter side is under 600 points. */
export function screenOf(win) {
  if (!win.matchMedia?.('(pointer: coarse)').matches) return 'computer';
  return Math.min(win.screen.width, win.screen.height) < 600 ? 'phone' : 'tablet';
}

/** The browser asks sites not to track it. */
export function optedOut(nav) {
  return nav.globalPrivacyControl === true || nav.doNotTrack === '1' || nav.doNotTrack === 'yes';
}

/**
 * Counts this page view, and returns `track(event, fields)` for the page's own moments (a companion picked).
 * `send` takes the beacon's body; `clock` gives milliseconds.
 */
export function startVisits(win, send = (body) => win.navigator.sendBeacon?.(ENDPOINT, body), clock = () => win.performance.now()) {
  const doc = win.document;
  const view = viewId();
  const page = win.location.pathname.replace(/\.html$|\/+$/g, '') || '/';
  const screen = screenOf(win);
  let sent = 0;
  const track = (event, fields = {}) => {
    if (sent >= MAX_PER_PAGE) return;
    sent += 1;
    try { send(JSON.stringify({ event, view, page, screen, ...fields })); } catch { /* the page carries on regardless */ }
  };

  const ref = refOf(win.location.search);
  track('pageview', { ref, from: fromOf(doc.referrer, win.location.hostname) });
  for (const link of doc.querySelectorAll('a[href="/download"]')) link.setAttribute('href', `/download?ref=${ref ?? 'site'}`);
  doc.addEventListener('click', (event) => {
    const link = event.target?.closest?.('a[href^="/download"]');
    if (link) track('download_clicked', { where: link.dataset.download || 'other' });
  }, { capture: true });

  // How far down it was read: the lowest the window's bottom edge reached, as a share of the page when it's left.
  // Only scrollY is read while scrolling, so counting never makes the browser lay the page out again.
  let lowest = win.scrollY;
  win.addEventListener('scroll', () => { lowest = Math.max(lowest, win.scrollY); }, { passive: true });
  const started = clock();
  let inView = 0;
  let shownSince = doc.visibilityState === 'hidden' ? null : started;
  doc.addEventListener('visibilitychange', () => {
    if (doc.visibilityState === 'hidden' && shownSince !== null) { inView += clock() - shownSince; shownSince = null; }
    else if (doc.visibilityState === 'visible' && shownSince === null) shownSince = clock();
  });
  let left = false;
  win.addEventListener('pagehide', () => {
    if (left) return;
    left = true;
    const now = clock();
    const height = doc.documentElement.scrollHeight;
    track('pageleave', {
      seconds: Math.round((now - started) / 1000),
      visible: Math.round((inView + (shownSince === null ? 0 : now - shownSince)) / 1000),
      scroll: height > 0 ? Math.min(100, Math.round(((lowest + win.innerHeight) / height) * 100)) : 100,
    });
  });
  return track;
}

let tracker = () => {};
/** One of the page's moments, counted when visits are (on hellomoku.com, unless the browser opted out). */
export function track(event, fields) {
  tracker(event, fields);
}

if (typeof window !== 'undefined' && SITES.has(window.location.hostname) && !optedOut(window.navigator)) tracker = startVisits(window);
