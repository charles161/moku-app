// @ts-check
/**
 * POST /v1/web-visit: a visit to hellomoku.com, counted without cookies (website/src/visits.js sends it with
 * navigator.sendBeacon; privacy.html, "This website"). One event a request, from a fixed list, each field checked
 * against a fixed shape: the page, a random id for this one page view (a UUIDv7, so PostHog's Web analytics can read
 * it as a session), whether it's a phone, a tablet or a computer, and the event's own few fields. The relay adds the
 * browser's and the system's family from the User-Agent and the country from Vercel's header, then forgets both, and
 * passes it on to PostHog under PostHog's own property names (so its Web analytics view works), with no person
 * profile and no location lookup. The IP address never leaves the relay. Only from the site's own pages (Origin).
 *
 * Limits live in this instance's memory, not Redis: the PostHog key is public anyway, and every Redis command counts
 * against the Upstash quota (ACTIONS.md B5). 300 a day per address, MOKU_WEB_VISITS_PER_DAY (50,000) in all.
 */
import { createHash } from 'node:crypto';
import { clientAddress } from './address.js';
import { family } from './web-errors.js';
import { DEFAULT_HOST } from './heartbeat.js';

const ORIGINS = new Set(['https://hellomoku.com', 'https://www.hellomoku.com']);
const MAX_BYTES = 1024;
const VIEW = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const PAGE = /^\/[a-z0-9\-/]{0,40}$/;
const WORD = /^[a-z][a-z0-9_]{0,31}$/;
const HOST = /^(?=.{3,100}$)[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/;
const COUNTRY = /^[A-Z]{2}$/;
const BOT = /bot|crawl|spider|preview|slurp|curl|wget|python|headless|httpclient|okhttp|go-http|lighthouse|pagespeed/i;

/** @typedef {(value: unknown) => unknown} Shape  a value in its allowed shape, or undefined */
const oneOf = (/** @type {string[]} */ ...words) => /** @type {Shape} */ ((v) => (typeof v === 'string' && words.includes(v) ? v : undefined));
const whole = (/** @type {number} */ most) => /** @type {Shape} */ ((v) => (Number.isInteger(v) && /** @type {number} */ (v) >= 0 ? Math.min(/** @type {number} */ (v), most) : undefined));
const word = /** @type {Shape} */ ((v) => (typeof v === 'string' && WORD.test(v) ? v : undefined));
const host = /** @type {Shape} */ ((v) => (typeof v === 'string' && HOST.test(v) ? v : undefined));

/** What the site may send: each event's fields and their shapes. Anything else is dropped. */
export const VISIT_EVENTS = /** @type {Record<string, Record<string, Shape>>} */ ({
  pageview: { ref: word, from: host },
  pageleave: { seconds: whole(86_400), visible: whole(86_400), scroll: whole(100) },
  download_clicked: { where: oneOf('header', 'hero', 'faq', 'closing', 'other') },
  companion_picked: { companion: word, where: oneOf('hero', 'friends') },
});
const SCREENS = /** @type {Record<string, string>} */ ({ phone: 'Mobile', tablet: 'Tablet', computer: 'Desktop' });

/** The beacon as the site sent it → { event, view, page, screen, fields }, or null when it isn't one. */
export function cleanVisit(/** @type {unknown} */ raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const given = /** @type {Record<string, unknown>} */ (raw);
  const event = typeof given.event === 'string' && Object.hasOwn(VISIT_EVENTS, given.event) ? given.event : null;
  if (!event || typeof given.view !== 'string' || !VIEW.test(given.view)) return null;
  /** @type {Record<string, unknown>} */
  const fields = {};
  for (const [key, shape] of Object.entries(VISIT_EVENTS[event])) {
    const value = shape(given[key]);
    if (value !== undefined) fields[key] = value;
  }
  return {
    event, view: given.view, fields,
    page: typeof given.page === 'string' && PAGE.test(given.page) ? given.page : '/other',
    screen: typeof given.screen === 'string' && Object.hasOwn(SCREENS, given.screen) ? given.screen : 'computer',
  };
}

const BROWSERS = /** @type {Record<string, string>} */ ({ chrome: 'Chrome', safari: 'Safari', firefox: 'Firefox', edge: 'Microsoft Edge', opera: 'Opera', other: 'Other' });
const SYSTEMS = /** @type {Record<string, string>} */ ({ macos: 'Mac OS X', ios: 'iOS', android: 'Android', windows: 'Windows', chromeos: 'Chrome OS', linux: 'Linux', other: 'Other' });

/** A clean visit → the PostHog event, under the names PostHog's Web analytics reads. */
export function postHogEvent(/** @type {NonNullable<ReturnType<typeof cleanVisit>>} */ visit, /** @type {{ agent: string, country?: string, at: number }} */ about) {
  const { browser, os } = family(about.agent);
  const { event, view, page, screen, fields } = visit;
  const shared = {
    $session_id: view, $current_url: `https://hellomoku.com${page}`, $host: 'hellomoku.com', $pathname: page,
    $device_type: SCREENS[screen], $browser: BROWSERS[browser], $os: SYSTEMS[os],
    ...(about.country ? { $geoip_country_code: about.country } : {}),
    $lib: 'moku-web', $process_person_profile: false, $geoip_disable: true,
  };
  /** @type {Record<string, unknown>} */
  let own = fields;
  if (event === 'pageview') {
    const from = /** @type {string | undefined} */ (fields.from);
    own = { $referrer: from ? `https://${from}/` : '$direct', $referring_domain: from ?? '$direct', ...(fields.ref ? { utm_source: fields.ref } : {}) };
  } else if (event === 'pageleave') {
    const scroll = typeof fields.scroll === 'number' ? fields.scroll / 100 : undefined;
    own = {
      $prev_pageview_pathname: page, $prev_pageview_duration: fields.seconds, seconds_visible: fields.visible,
      $prev_pageview_max_scroll_percentage: scroll, $prev_pageview_max_content_percentage: scroll,
    };
  }
  return {
    event: event === 'pageview' || event === 'pageleave' ? `$${event}` : event, distinct_id: `web-${view}`,
    timestamp: new Date(about.at).toISOString(), properties: { ...shared, ...own },
  };
}

/**
 * @param {{ env: Record<string, string | undefined>, fetch: typeof fetch, allow: (key: string, limit: number, windowSec: number) => Promise<boolean>,
 *   log: (line: string) => void, json: (status: number, body: unknown, headers?: Record<string, string>) => Response, now: () => number }} deps
 */
export function createWebVisits({ env, fetch, allow, log, json, now }) {
  const posthog = (env.POSTHOG_HOST || DEFAULT_HOST).replace(/\/$/, '');
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
    const visit = cleanVisit(body);
    if (!visit) return json(400, { error: 'not a visit' });
    const address = createHash('sha256').update(clientAddress(request)).digest('hex').slice(0, 16);
    if (!(await allow(`web-visit-ip:${address}`, 300, 86_400)) || !(await allow('web-visits', Number(env.MOKU_WEB_VISITS_PER_DAY || 50_000), 86_400))) {
      return json(429, { error: 'too many' }, { 'retry-after': '3600' });
    }
    const country = request.headers.get('x-vercel-ip-country') ?? '';
    const event = postHogEvent(visit, { agent, country: COUNTRY.test(country) ? country : undefined, at: now() });
    if (!env.POSTHOG_KEY) { log(`moku-proxy web-visit ${JSON.stringify(event)}`); return json(202, { ok: true, forwarded: false }); }
    try {
      const res = await fetch(`${posthog}/batch/`, {
        method: 'POST', headers: { 'content-type': 'application/json' }, signal: AbortSignal.timeout(5000),
        body: JSON.stringify({ api_key: env.POSTHOG_KEY, batch: [event] }),
      });
      if (!res.ok) log(`moku-proxy web-visit ${visit.event} posthog-error ${res.status}`);
      return json(202, { ok: true, forwarded: res.ok });
    } catch (failure) {
      log(`moku-proxy web-visit posthog-error ${/** @type {Error} */ (failure).message}`);
      return json(202, { ok: true, forwarded: false });
    }
  };
}
