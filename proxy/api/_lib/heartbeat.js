// @ts-check
import { clientAddress } from './address.js';

/**
 * POST /v1/heartbeat: one Mac's day in numbers, sent by the app once a day when the person has turned on
 * "Share daily counts" (off by default). The relay keeps nothing and passes it on as one PostHog event,
 * `daily_counts`, keyed by the device hash (POSTHOG_KEY; POSTHOG_HOST defaults to PostHog EU). Without a key it
 * logs one line instead, so the counts can be read with `vercel logs`.
 *
 * Counts only, enforced here as well as in the app: a nested object of numbers and booleans (keys are short
 * identifiers, three levels deep, 200 at most), plus a handful of strings with strict shapes (the day, the app and
 * macOS versions, the chip, the plan). Anything else is dropped, so no screen text, title or name can pass.
 */

export const DEFAULT_HOST = 'https://eu.i.posthog.com';
const MAX_PROPERTIES = 200;
const KEY = /^[A-Za-z][A-Za-z0-9]{0,31}$/;
/** The only strings that pass, and the shape each must have. */
const STRINGS = {
  version: /^[0-9A-Za-z.+-]{1,24}$/,
  build: /^[0-9A-Za-z.+-]{1,24}$/,
  macos: /^[0-9]{1,2}(\.[0-9]{1,3}){0,2}$/,
  chip: /^(arm64|x86_64)$/,
  plan: /^(trial|tester|pro|ownKey|none)$/,
};

/**
 * `{ a: 1, b: { c: true } }` → `{ a: 1, b_c: true }`: numbers (finite, rounded to 3 places, within ±1e9) and
 * booleans only, keys that are identifiers, at most three levels. Returns null past MAX_PROPERTIES.
 * @param {unknown} value
 * @returns {Record<string, number | boolean> | null}
 */
export function flattenCounts(value, prefix = '', depth = 0, out = /** @type {Record<string, number | boolean>} */ ({})) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return out;
  for (const [key, v] of Object.entries(value)) {
    if (!KEY.test(key)) continue;
    const name = prefix ? `${prefix}_${key}` : key;
    if (typeof v === 'boolean') out[name] = v;
    else if (typeof v === 'number' && Number.isFinite(v)) out[name] = Math.round(Math.max(-1e9, Math.min(1e9, v)) * 1000) / 1000;
    else if (v && typeof v === 'object' && !Array.isArray(v) && depth < 2) flattenCounts(v, name, depth + 1, out);
    if (Object.keys(out).length > MAX_PROPERTIES) return null;
  }
  return out;
}

/**
 * `allowAddress` is for the per-address limit: it counts in the instance's memory before Redis (proxy.js allowHereFirst).
 * @param {{ env: Record<string, string | undefined>, fetch: typeof fetch, allow: (key: string, limit: number, windowSec: number) => Promise<boolean>,
 *           allowAddress?: (key: string, limit: number, windowSec: number) => Promise<boolean>,
 *           log: (line: string) => void, json: (status: number, body: unknown, headers?: Record<string, string>) => Response }} deps
 */
export function createHeartbeat({ env, fetch, allow, allowAddress = allow, log, json }) {
  return async (/** @type {Request} */ request) => {
    // The body is checked before any limit is counted: junk costs no Redis command (security review 2026-10-09).
    if (Number(request.headers.get('content-length') ?? 0) > 16 * 1024) return json(413, { error: 'body too large' });
    const text = await request.text();
    if (text.length > 16 * 1024) return json(413, { error: 'body too large' });
    /** @type {Record<string, unknown>} */
    let body;
    try { body = JSON.parse(text); } catch { return json(400, { error: 'body must be JSON' }); }
    const device = typeof body?.device === 'string' ? body.device.toLowerCase() : '';
    if (!/^[0-9a-f]{64}$/.test(device)) return json(400, { error: 'device must be a 64-character hex hash' });
    const day = typeof body.day === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(body.day) && !Number.isNaN(Date.parse(`${body.day}T12:00:00Z`)) ? body.day : null;
    if (!day) return json(400, { error: 'day must be YYYY-MM-DD' });
    const ip = clientAddress(request);
    if (!(await allowAddress(`heartbeat-ip:${ip}`, Number(env.MOKU_HEARTBEATS_PER_IP || 100), 86_400))) return json(429, { error: 'too many heartbeats' }, { 'retry-after': '3600' });
    // A Mac sends each finished day once (up to three, catching up after a few days off); a little room for retries.
    if (!(await allow(`heartbeat:${device}`, 8, 86_400))) return json(429, { error: 'too many heartbeats' }, { 'retry-after': '3600' });

    const counts = flattenCounts(body.counts);
    if (!counts) return json(400, { error: `at most ${MAX_PROPERTIES} counts` });
    /** @type {Record<string, string>} */
    const strings = {};
    for (const [key, shape] of Object.entries(STRINGS)) if (typeof body[key] === 'string' && shape.test(body[key])) strings[key] = body[key];
    const properties = { ...counts, ...strings, day, $lib: 'moku-relay', $geoip_disable: true };

    if (!env.POSTHOG_KEY) {
      log(`moku-proxy heartbeat ${device.slice(0, 12)} ${day} ${JSON.stringify(properties)}`);
      return json(202, { ok: true, forwarded: false });
    }
    try {
      const res = await fetch(`${(env.POSTHOG_HOST || DEFAULT_HOST).replace(/\/$/, '')}/i/v0/e/`, {
        method: 'POST', headers: { 'content-type': 'application/json' }, signal: AbortSignal.timeout(10_000),
        body: JSON.stringify({ api_key: env.POSTHOG_KEY, event: 'daily_counts', distinct_id: device, timestamp: `${day}T12:00:00Z`, properties }),
      });
      if (!res.ok) throw new Error(`posthog ${res.status}`);
    } catch (error) {
      log(`moku-proxy heartbeat ${device.slice(0, 12)} ${day} posthog-error ${/** @type {Error} */ (error).message}`);
      return json(502, { error: 'analytics unreachable' });
    }
    log(`moku-proxy heartbeat ${device.slice(0, 12)} ${day} forwarded`);
    return json(202, { ok: true, forwarded: true });
  };
}
