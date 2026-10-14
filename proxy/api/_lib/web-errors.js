// @ts-check
/**
 * POST /v1/web-error: hellomoku.com breaking in someone's browser (website/src/error-reports.js sends it with
 * navigator.sendBeacon). One error a request, its fields checked against fixed shapes: the error's name and message,
 * where in the site's own script, the page, and whether it was thrown or an unhandled rejection. The relay adds the
 * browser's and the system's family from the User-Agent (then forgets it) and passes it to PostHog as an `$exception`
 * with level "error", a new random id each time, no person profile and no location. No cookie is read or set, the IP
 * address is never stored (the per-IP limit keys on a hash of it), and a message keeps a web address's origin and path
 * only. Only from the site's own pages (Origin), 20 a day per address and 2,000 a day in all.
 */
import { createHash, randomBytes } from 'node:crypto';
import { clientAddress } from './address.js';
import { DEFAULT_HOST } from './heartbeat.js';

const ORIGINS = new Set(['https://hellomoku.com', 'https://www.hellomoku.com']);
const MAX_BYTES = 4 * 1024;
const TYPE = /^[A-Za-z][A-Za-z0-9_]{0,39}$/;
const FILE = /^\/[A-Za-z0-9._\-/]{1,120}\.m?js$/;
const PAGE = /^\/[a-z0-9\-/]{0,40}$/;
const BOT = /bot|crawl|spider|preview|slurp|curl|wget|python|headless|httpclient|okhttp|go-http|lighthouse|pagespeed/i;

/** A message without what could say who someone is: addresses keep their origin and path, emails go, at most 300 characters. */
export function cleanMessage(/** @type {unknown} */ text) {
  if (typeof text !== 'string') return '';
  return text
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/\b([a-z][a-z0-9+.-]*:\/\/[^\s?#'"<>]*)[?#][^\s'"<>]*/gi, '$1')
    .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, '[email]')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 300);
}

/** The error as the site sent it → its allowed fields, or null when it isn't one. */
export function cleanWebError(/** @type {unknown} */ raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const given = /** @type {Record<string, unknown>} */ (raw);
  const message = cleanMessage(given.message);
  if (!message) return null;
  const whole = (/** @type {unknown} */ n) => (Number.isInteger(n) && /** @type {number} */ (n) >= 0 && /** @type {number} */ (n) <= 10_000_000 ? /** @type {number} */ (n) : undefined);
  const file = typeof given.file === 'string' && FILE.test(given.file) && !given.file.includes('..') ? given.file : undefined;
  return {
    kind: given.kind === 'rejection' ? 'rejection' : 'error',
    type: typeof given.type === 'string' && TYPE.test(given.type) ? given.type : 'Error',
    message,
    ...(file ? { file, line: whole(given.line), col: whole(given.col) } : {}),
    page: typeof given.page === 'string' && PAGE.test(given.page) ? given.page : 'other',
  };
}

/** A User-Agent → the browser's and the system's family, in a word each. */
export function family(/** @type {string} */ agent) {
  const browser = /Edg(e|A|iOS)?\//.test(agent) ? 'edge' : /OPR\/|Opera/.test(agent) ? 'opera' : /Firefox\/|FxiOS\//.test(agent) ? 'firefox'
    : /Chrome\/|CriOS\//.test(agent) ? 'chrome' : /Safari\//.test(agent) ? 'safari' : 'other';
  const os = /iPhone|iPad|iPod/.test(agent) ? 'ios' : /Android/.test(agent) ? 'android' : /Mac OS X|Macintosh/.test(agent) ? 'macos'
    : /Windows/.test(agent) ? 'windows' : /CrOS/.test(agent) ? 'chromeos' : /Linux/.test(agent) ? 'linux' : 'other';
  return { browser, os };
}

/**
 * `allowAddress` is for the per-address limit: it counts in the instance's memory before Redis (proxy.js allowHereFirst).
 * @param {{ env: Record<string, string | undefined>, fetch: typeof fetch, allow: (key: string, limit: number, windowSec: number) => Promise<boolean>,
 *   allowAddress?: (key: string, limit: number, windowSec: number) => Promise<boolean>,
 *   log: (line: string) => void, json: (status: number, body: unknown, headers?: Record<string, string>) => Response, now: () => number }} deps
 */
export function createWebErrors({ env, fetch, allow, allowAddress = allow, log, json, now }) {
  const host = (env.POSTHOG_HOST || DEFAULT_HOST).replace(/\/$/, '');
  return async (/** @type {Request} */ request) => {
    if (!ORIGINS.has(request.headers.get('origin') ?? '')) return json(403, { error: 'not from the site' });
    const agent = request.headers.get('user-agent') ?? '';
    if (!agent || BOT.test(agent)) return json(202, { ok: true, forwarded: false });
    if (Number(request.headers.get('content-length') ?? 0) > MAX_BYTES) return json(413, { error: 'body too large' });
    const text = await request.text();
    if (text.length > MAX_BYTES) return json(413, { error: 'body too large' });
    /** @type {unknown} */
    let body;
    try { body = JSON.parse(text); } catch { return json(400, { error: 'body must be JSON' }); }
    const error = cleanWebError(body);
    if (!error) return json(400, { error: 'not an error report' });
    const ip = clientAddress(request);
    const address = createHash('sha256').update(ip).digest('hex').slice(0, 16);
    if (!(await allowAddress(`web-error-ip:${address}`, 20, 86_400)) || !(await allow('web-errors', Number(env.MOKU_WEB_ERRORS_PER_DAY || 2000), 86_400))) {
      return json(429, { error: 'too many' }, { 'retry-after': '3600' });
    }
    const { browser, os } = family(agent);
    const event = {
      event: '$exception', distinct_id: `web-${randomBytes(6).toString('hex')}`, timestamp: new Date(now()).toISOString(),
      properties: {
        $exception_list: [{
          type: error.type, value: error.message,
          mechanism: { handled: false, synthetic: false, type: error.kind === 'rejection' ? 'onunhandledrejection' : 'onerror' },
          stacktrace: { type: 'raw', frames: error.file ? [{ platform: 'custom', lang: 'javascript', filename: error.file, lineno: error.line, colno: error.col, function: '?', in_app: true }] : [] },
        }],
        $exception_level: 'error', kind: error.kind, page: error.page, ...(error.file ? { file: error.file, line: error.line, col: error.col } : {}),
        browser, os, process: 'website', $lib: 'moku-web', $process_person_profile: false, $geoip_disable: true,
      },
    };
    if (!env.POSTHOG_KEY) { log(`moku-proxy web-error ${JSON.stringify(event)}`); return json(202, { ok: true, forwarded: false }); }
    try {
      const res = await fetch(`${host}/batch/`, {
        method: 'POST', headers: { 'content-type': 'application/json' }, signal: AbortSignal.timeout(5000),
        body: JSON.stringify({ api_key: env.POSTHOG_KEY, batch: [event] }),
      });
      log(`moku-proxy web-error ${error.page} ${error.type} ${res.ok ? 'forwarded' : `posthog-error ${res.status}`}`);
      return json(202, { ok: true, forwarded: res.ok });
    } catch (failure) {
      log(`moku-proxy web-error posthog-error ${/** @type {Error} */ (failure).message}`);
      return json(202, { ok: true, forwarded: false });
    }
  };
}
