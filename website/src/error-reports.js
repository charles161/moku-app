// When the site breaks in someone's browser, it tells me what broke, so I can fix it before anyone has to write in
// (privacy.html, "This website"). One error is one beacon to the relay (proxy/api/_lib/web-errors.js), which passes it
// on to PostHog: the error's name and message (a web address in it cut to its origin and path), where in the site's own
// script, the page, and whether it was thrown or a promise nobody caught. No cookie, no id, no query string. Errors from
// anyone else's script (an extension, another site's frame) aren't ours and aren't sent. Only on hellomoku.com, and at
// most five a page.

export const ENDPOINT = 'https://moku-proxy.vercel.app/v1/web-error';
export const SITES = new Set(['hellomoku.com', 'www.hellomoku.com']);
export const MAX_PER_PAGE = 5;

/** A message with any web address cut to its origin and path, on one line, 300 characters at most. */
export function cleanMessage(text) {
  return String(text ?? '')
    .replace(/[\x00-\x1f\x7f]+/g, ' ')
    .replace(/\b([a-z][a-z0-9+.-]*:\/\/[^\s?#'"<>]*)[?#][^\s'"<>]*/gi, '$1')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 300);
}

/** `url` as a path on our own site ("/assets/index-a1b2.js"), or null when it's someone else's. */
export function ownPath(url, origin) {
  try {
    const parsed = new URL(url, origin);
    return parsed.origin === origin ? parsed.pathname : null;
  } catch {
    return null;
  }
}

/** The first frame of a stack that's in our own script: { file, line, col }, or null. Chrome, Safari and Firefox alike. */
export function ownFrame(stack, origin) {
  for (const match of String(stack ?? '').matchAll(/(https?:\/\/[^\s()]+?):(\d+):(\d+)/g)) {
    const file = ownPath(match[1], origin);
    if (file) return { file, line: Number(match[2]), col: Number(match[3]) };
  }
  return null;
}

/**
 * What an `error` or `unhandledrejection` event becomes, or null when it isn't ours to send.
 * @param {{ kind: 'error' | 'rejection', error?: unknown, message?: string, filename?: string, lineno?: number, colno?: number }} what
 * @param {{ origin: string, page: string }} where
 */
export function reportOf({ kind, error, message, filename, lineno, colno }, { origin, page }) {
  const thrown = error instanceof Error ? error : null;
  let place = null;
  if (kind === 'error') {
    // Our scripts are files on our site, so their errors always name one. None ("Script error." from another origin,
    // code run from the developer tools or injected by an extension) or someone else's file: not ours.
    const file = filename ? ownPath(filename, origin) : null;
    if (!file) return null;
    place = { file, line: lineno ?? 0, col: colno ?? 0 };
  } else {
    if (!thrown) return null;  // a bare value rejected: nothing to say what broke
    const stack = thrown.stack ?? '';
    place = ownFrame(stack, origin);
    // Frames, none of them ours: someone else's. No frames at all (a failed fetch in Safari or Firefox): ours, no place.
    if (!place && stack.split('\n').some((line) => /^\s*at\s|@/.test(line))) return null;
  }
  const text = cleanMessage(thrown?.message ?? message);
  if (!text) return null;
  return {
    kind, type: /^[A-Za-z][A-Za-z0-9_]{0,39}$/.test(thrown?.name ?? '') ? thrown.name : 'Error', message: text,
    ...place, page: /^\/[a-z0-9\-/]{0,40}$/.test(page) ? page : 'other',
  };
}

/** Listens for the page's uncaught errors and sends each one (five a page at most). `send` takes the URL and the body. */
export function startErrorReports(win, send = (url, body) => win.navigator.sendBeacon?.(url, body)) {
  let sent = 0;
  const report = (what) => {
    if (sent >= MAX_PER_PAGE) return;
    const found = reportOf(what, { origin: win.location.origin, page: win.location.pathname });
    if (!found) return;
    sent += 1;
    try { send(ENDPOINT, JSON.stringify(found)); } catch { /* the page carries on regardless */ }
  };
  win.addEventListener('error', (event) => {
    if (!event.message && !event.error) return;  // a picture or a clip that didn't load: the page shows its still
    report({ kind: 'error', error: event.error, message: event.message, filename: event.filename, lineno: event.lineno, colno: event.colno });
  });
  win.addEventListener('unhandledrejection', (event) => report({ kind: 'rejection', error: event.reason }));
}

if (typeof window !== 'undefined' && SITES.has(window.location.hostname)) startErrorReports(window);
