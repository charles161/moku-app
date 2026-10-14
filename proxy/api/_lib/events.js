// @ts-check
/**
 * Usage events, always on (docs/specs/usage-analytics.md). Two routes:
 *   - POST /v1/events: a batch of the app's events. Only the events and properties listed in EVENTS pass, each with a
 *     strict shape (a boolean, a bounded whole number, one of a few fixed words, a version, or a code identifier), so
 *     no app name, window title, address, screen text or anything typed can reach PostHog. Unknown events and
 *     properties are dropped, not rejected, so an older relay never breaks a newer app.
 *   - GET /get: counts one download (with ?ref=, where the person came from), then redirects to /download.
 * Events go to PostHog keyed by the Mac's short device id (the first 12 characters of its hashed hardware id), with no
 * person profile. `app_error` (an error Moku carried on from) goes as an `$exception` with level "error", so PostHog's
 * error tracking groups it: its kind, its family and number, and its place in Moku's code (appException). PostHog never sees the person's IP address: requests come from the relay, and the country comes from
 * Vercel's own x-vercel-ip-country header.
 */
import { randomBytes } from 'node:crypto';
import { clientAddress } from './address.js';
import { DEFAULT_HOST } from './heartbeat.js';

const IDENTIFIER = /^[a-z][a-z0-9_]{0,31}$/;
const VERSION = /^[0-9]{1,3}(\.[0-9]{1,3}){0,3}$/;
const COUNTRY = /^[A-Z]{2}$/;
/** A place in Moku's own code: "BrainClient.swift:today", "app.go:NewHandler.func1" (MokuKit ErrorReports.isPlace). */
const PLACE = /^[A-Za-z0-9_+]{1,48}\.(?:swift|go):[A-Za-z_][A-Za-z0-9_.]{0,63}$/;
const DAY_MS = 86_400_000;

/** @typedef {{ type: 'bool' } | { type: 'int', min: number, max: number } | { type: 'enum', values: string[] } | { type: 'version' } | { type: 'identifier' } | { type: 'place' }} Shape */
const bool = /** @type {Shape} */ ({ type: 'bool' });
const int = (/** @type {number} */ min, /** @type {number} */ max) => /** @type {Shape} */ ({ type: 'int', min, max });
const oneOf = (/** @type {string[]} */ ...values) => /** @type {Shape} */ ({ type: 'enum', values });
const version = /** @type {Shape} */ ({ type: 'version' });
const identifier = /** @type {Shape} */ ({ type: 'identifier' });
const place = /** @type {Shape} */ ({ type: 'place' });

/** Every property any event may carry: the app's version, and the companion on show. */
const COMMON = { app_version: version, companion: oneOf('moku', 'tetsu') };

/** The only events that pass, and the only properties each may carry. */
export const EVENTS = /** @type {Record<string, Record<string, Shape>>} */ ({
  app_opened: {
    first_launch: bool, macos: int(11, 40), ram_gb: int(1, 1024), launched_by: oneOf('login', 'person', 'update'),
    screen_recording: bool, accessibility: bool, companion: oneOf('moku', 'tetsu'),
    displays: int(1, 16), reduce_motion: bool, low_power: bool, hidden: bool, previous_exit: oneOf('clean', 'unclean'),
  },
  update_installed: { from: version, to: version, hours_since_release: int(0, 100_000) },
  whats_new: { what: oneOf('shown', 'opened', 'closed'), seconds: int(0, 86_400) },
  update_check: { result: oneOf('up_to_date', 'found', 'error'), error: oneOf('download', 'signature', 'feed', 'install', 'no_permission', 'disk_image', 'network', 'other'),
    network_code: int(-4000, 0), http_status: int(100, 599), host: oneOf('relay', 'r2', 'other') },
  update_downloaded: { to: version },
  update_stuck: { why: oneOf('download_failed', 'signature_failed', 'waiting_for_away', 'no_permission', 'not_in_applications', 'sparkle_off'),
    network_code: int(-4000, 0), http_status: int(100, 599), host: oneOf('relay', 'r2', 'other') },
  welcome_step: {
    step: oneOf('opened', 'resumed', 'relaunch', 'hello', 'picked', 'reads', 'allow_screen', 'allow_accessibility', 'start', 'skip'),
  },
  welcome_left: {
    last_step: oneOf('opened', 'resumed', 'relaunch', 'hello', 'picked', 'reads', 'allow_screen', 'allow_accessibility', 'start', 'skip'),
    seconds: int(0, 86_400),
  },
  permission_answered: { kind: oneOf('screen', 'accessibility'), granted: bool, where: oneOf('welcome', 'settings', 'launch'), seconds: int(0, 86_400) },
  welcome_finished: { how: oneOf('completed', 'skipped'), seconds: int(0, 86_400) },
  popover_opened: { from: oneOf('menubar', 'moku'), ms: int(0, 60_000) },
  day_opened: { from: oneOf('popover', 'popover_house', 'popover_numbers', 'menu', 'link', 'card') },
  day_loaded: { ms: int(0, 600_000), ok: bool },
  day_closed: { seconds_open: int(0, 86_400), expanded: int(0, 1000) },
  popover_action: {
    action: oneOf('break', 'hide', 'show', 'put_back', 'settings', 'hi', 'feedback', 'quit'), from: oneOf('popover', 'menu'),
  },
  first_focus: { minutes_since_install: int(0, 10_000_000) },
  comeback: { drift_seconds: int(0, 86_400), first_today: bool },
  house_piece: { pieces_today: int(0, 1000) },
  break: { what: oneOf('started', 'ended', 'cancelled'), from: identifier, after_suggestion: bool, seconds: int(0, 86_400) },
  break_suggested: { kind: oneOf('water', 'stretch', 'look_away', 'walk') },
  correction: { kind: oneOf('pat', 'marked_work', 'marked_not_work') },
  setting_changed: { key: identifier, turned: oneOf('on', 'off') },
  settings_opened: { tab: oneOf('general', 'breaks', 'privacy'), how: oneOf('opened', 'switched') },
  setting_outcome: { key: identifier, outcome: oneOf('kept', 'changed_back'), seconds: int(0, 86_400) },
  companion_changed: { from: oneOf('moku', 'tetsu'), to: oneOf('moku', 'tetsu'), where: oneOf('welcome', 'settings') },
  hidden: { by: oneOf('person', 'call', 'screen_share') },
  shown: { by: oneOf('person', 'automatic', 'welcome'), after_seconds: int(0, 31_536_000) },
  numbers_disagree: { views: oneOf('tasks_header', 'rows_header', 'house_header', 'popover_header'), gap_minutes: int(0, 1440) },
  drift_step: { step: oneOf('sad', 'cross', 'long', 'tall', 'ask') },  // 'cross': builds before 0.1.11 (the angry face)
  ask_outcome: { outcome: oneOf('within_2_min', 'later', 'not_that_day'), seconds: int(0, 86_400) },
  resume_offered: { after: oneOf('drift', 'away'), already_there: bool },
  resume_used: { came_forward: bool, ms: int(0, 600_000) },
  day_card: { what: oneOf('shown', 'opened', 'closed', 'timed_out', 'missed'), yesterday: bool, farewell: bool },
  trouble: {
    kind: oneOf('brain_restarted', 'brain_down', 'relay_401', 'relay_402', 'relay_403', 'relay_429', 'relay_down', 'offline', 'cloud_off', 'stand_in', 'permission_lost', 'store_set_aside'),
    count: int(1, 100_000), seconds: int(0, 604_800),
  },
  app_quit: { uptime_minutes: int(0, 10_000_000), how: oneOf('menu', 'logout', 'update', 'relaunch', 'signal', 'other') },
  repeat: { action: oneOf('take_me_there', 'setting', 'day_open', 'hide', 'break', 'popover_blink'), count: int(2, 1000) },
  frustration: { signal: oneOf('rapid_clicks', 'hide_after_nudge', 'work_after_nudge', 'quit_after_nudge', 'delete_data') },
  launch_speed: { ms: int(0, 600_000), stand_in: bool },
  day_summary: {
    days_ago: int(0, 60), days_since_install: int(0, 100_000), macos: int(11, 40),
    active_minutes: int(0, 10_000_000), focused_minutes: int(0, 1440), returns: int(0, 100_000), longest_minutes: int(0, 1440),
    minutes_hidden: int(0, 1440), minutes_hidden_person: int(0, 1440), minutes_hidden_call: int(0, 1440), memory_mb: int(0, 100_000), core_permille: int(0, 1000),
    hovers: int(0, 10_000_000), drags: int(0, 10_000_000), tosses: int(0, 10_000_000), clicks: int(0, 10_000_000),
    icon_clicks: int(0, 10_000_000), popover_blinks: int(0, 10_000_000), pats: int(0, 10_000_000), corrections: int(0, 10_000_000),
    drifts_sad: int(0, 10_000_000), drifts_cross: int(0, 10_000_000), drifts_long: int(0, 10_000_000), drifts_tall: int(0, 10_000_000),
    drifts_ask: int(0, 10_000_000),
    verdicts_work: int(0, 10_000_000), verdicts_switched: int(0, 10_000_000), verdicts_drift: int(0, 10_000_000),
    verdicts_unknown: int(0, 10_000_000),
    talent_scan: int(0, 10_000_000), talent_hologram: int(0, 10_000_000), talent_petals: int(0, 10_000_000),
    talent_sniff: int(0, 10_000_000), water_reminders: int(0, 10_000_000), stalls: int(0, 10_000_000), frames_dropped: int(0, 10_000_000),
    brain_p50_ms: int(0, 600_000), brain_p95_ms: int(0, 600_000), jev_p50_ms: int(0, 600_000), jev_p95_ms: int(0, 600_000),
    luna_p50_ms: int(0, 600_000), luna_p95_ms: int(0, 600_000),
  },
  app_error: {
    kind: oneOf('brain_unreachable', 'brain_timeout', 'brain_5xx', 'brain_refused', 'brain_decode', 'relay_decode', 'attest_failed', 'sparkle', 'asset_load',
      'write_failed', 'brain_request', 'brain_task', 'brain_disk', 'brain_store'),
    domain: oneOf('url', 'http', 'decoding', 'cocoa', 'posix', 'osstatus', 'sparkle', 'moku', 'go', 'other'),
    code: int(-2_147_483_648, 2_147_483_647), where: place, count: int(1, 100_000),
  },
});

/** A value in its shape, or undefined when it doesn't fit. */
function fit(/** @type {Shape} */ shape, /** @type {unknown} */ value) {
  switch (shape.type) {
    case 'bool': return typeof value === 'boolean' ? value : undefined;
    case 'int': return Number.isInteger(value) && /** @type {number} */ (value) >= shape.min && /** @type {number} */ (value) <= shape.max ? value : undefined;
    case 'enum': return typeof value === 'string' && shape.values.includes(value) ? value : undefined;
    case 'version': return typeof value === 'string' && VERSION.test(value) ? value : undefined;
    case 'identifier': return typeof value === 'string' && IDENTIFIER.test(value) ? value : undefined;
    case 'place': return typeof value === 'string' && PLACE.test(value) ? value : undefined;
  }
}

/**
 * An `app_error`'s properties as PostHog's `$exception`: the kind is the exception's type, its family and number the
 * value ("url -1004"), and its place in Moku's code the one frame, so each kind at each place is one issue.
 * @param {Record<string, unknown>} properties
 */
export function appException(properties) {
  const [file, fn] = typeof properties.where === 'string' ? properties.where.split(':') : ['unknown.swift', 'unknown'];
  const brain = file.endsWith('.go');
  return {
    $exception_list: [{
      type: typeof properties.kind === 'string' ? properties.kind : 'app_error',
      value: `${properties.domain ?? 'other'} ${properties.code ?? 0}`,
      mechanism: { handled: true, synthetic: false, type: 'generic' },
      stacktrace: { type: 'raw', frames: [{ platform: 'custom', lang: brain ? 'go' : 'swift', filename: file, function: fn, in_app: true, resolved: true }] },
    }],
    $exception_level: 'error', process: brain ? 'moku-brain' : 'Moku',
  };
}

/**
 * One event as the app sent it → its name, time and allowed properties, or null when the event isn't on the list.
 * @param {unknown} raw
 * @param {number} now
 */
export function cleanEvent(raw, now) {
  if (!raw || typeof raw !== 'object') return null;
  const { name, ts, props } = /** @type {{ name?: unknown, ts?: unknown, props?: unknown }} */ (raw);
  if (typeof name !== 'string' || !Object.hasOwn(EVENTS, name)) return null;
  const at = typeof ts === 'number' && ts > now - 7 * DAY_MS && ts < now + 5 * 60_000 ? ts : now;
  /** @type {Record<string, unknown>} */
  const properties = {};
  const given = props && typeof props === 'object' && !Array.isArray(props) ? /** @type {Record<string, unknown>} */ (props) : {};
  for (const [key, shape] of Object.entries({ ...COMMON, ...EVENTS[name] })) {
    const value = fit(shape, given[key]);
    if (value !== undefined) properties[key] = value;
  }
  return { name, at, properties };
}

const BOT = /bot|crawl|spider|preview|slurp|curl|wget|python|headless|httpclient|okhttp|go-http|whatsapp|facebookexternalhit/i;

/**
 * `allowAddress` is for the per-address limits: it counts in the instance's memory before Redis (proxy.js allowHereFirst).
 * @param {{ env: Record<string, string | undefined>, fetch: typeof fetch, allow: (key: string, limit: number, windowSec: number) => Promise<boolean>,
 *   allowAddress?: (key: string, limit: number, windowSec: number) => Promise<boolean>,
 *   log: (line: string) => void, json: (status: number, body: unknown, headers?: Record<string, string>) => Response, now: () => number,
 *   whoIs: (request: Request) => { plan: string, friend: string } | null }} deps
 */
export function createEvents({ env, fetch, allow, allowAddress = allow, log, json, now, whoIs }) {
  const host = (env.POSTHOG_HOST || DEFAULT_HOST).replace(/\/$/, '');
  const country = (/** @type {Request} */ request) => {
    const c = request.headers.get('x-vercel-ip-country') ?? '';
    return COUNTRY.test(c) ? c : undefined;
  };
  /** Sends PostHog events; true when they were accepted (or there's no key, and they were logged instead). */
  async function send(/** @type {object[]} */ batch, /** @type {string} */ what) {
    if (!env.POSTHOG_KEY) { log(`moku-proxy ${what} ${JSON.stringify(batch)}`); return false; }
    try {
      const res = await fetch(`${host}/batch/`, {
        method: 'POST', headers: { 'content-type': 'application/json' }, signal: AbortSignal.timeout(10_000),
        body: JSON.stringify({ api_key: env.POSTHOG_KEY, batch }),
      });
      if (!res.ok) log(`moku-proxy ${what} posthog-error ${res.status}`);
      return res.ok;
    } catch (error) {
      log(`moku-proxy ${what} posthog-error ${/** @type {Error} */ (error).message}`);
      return false;
    }
  }

  /** POST /v1/events { device, events: [{ name, ts, props }] }, with the install's token when it has one. */
  async function events(/** @type {Request} */ request) {
    // The body is checked before any limit is counted: junk costs no Redis command (security review 2026-10-09).
    if (Number(request.headers.get('content-length') ?? 0) > 32 * 1024) return json(413, { error: 'body too large' });
    const text = await request.text();
    if (text.length > 32 * 1024) return json(413, { error: 'body too large' });
    /** @type {any} */
    let body;
    try { body = JSON.parse(text); } catch { return json(400, { error: 'body must be JSON' }); }
    const device = typeof body?.device === 'string' ? body.device.toLowerCase() : '';
    if (!/^[0-9a-f]{64}$/.test(device)) return json(400, { error: 'device must be a 64-character hex hash' });
    if (!Array.isArray(body.events) || body.events.length > 50) return json(400, { error: 'events must be a list of at most 50' });
    const ip = clientAddress(request);
    if (!(await allowAddress(`events-ip:${ip}`, Number(env.MOKU_EVENT_BATCHES_PER_IP || 1000), 86_400))) return json(429, { error: 'too many events' }, { 'retry-after': '3600' });
    if (!(await allow(`events:${device}`, 2000, 86_400))) return json(429, { error: 'too many events' }, { 'retry-after': '3600' });

    const at = now();
    const short = device.slice(0, 12);
    const who = whoIs(request);
    const where = country(request);
    const clean = body.events.map((/** @type {unknown} */ e) => cleanEvent(e, at)).filter(Boolean);
    const batch = clean.map((/** @type {NonNullable<ReturnType<typeof cleanEvent>>} */ e) => ({
      event: e.name === 'app_error' ? '$exception' : e.name, distinct_id: short, timestamp: new Date(e.at).toISOString(),
      properties: {
        ...e.properties, ...(e.name === 'app_error' ? appException(e.properties) : {}),
        device: short, plan: who?.plan ?? 'none', friend: who?.friend ?? 'none', ...(where ? { country: where } : {}),
        $lib: 'moku-app', $process_person_profile: false, $geoip_disable: true,
      },
    }));
    const forwarded = batch.length ? await send(batch, 'events') : false;
    return json(202, { ok: true, accepted: batch.length, dropped: body.events.length - batch.length, forwarded });
  }

  /** GET /get?ref=x: one download, counted unless it's a bot or a link preview, then on to the DMG (a HEAD too, uncounted). */
  async function download(/** @type {Request} */ request) {
    const url = new URL(request.url);
    const ref = (url.searchParams.get('ref') ?? '').toLowerCase();
    const agent = request.headers.get('user-agent') ?? '';
    const ip = clientAddress(request);
    // A HEAD only looks (a previewer, a download manager first): redirected, never counted.
    if (request.method === 'GET' && agent && !BOT.test(agent) && (await allowAddress(`download-ip:${ip}`, 20, 86_400))) {
      const where = country(request);
      const id = `download-${randomBytes(6).toString('hex')}`;
      const counting = send([{
        event: 'download', distinct_id: id, timestamp: new Date(now()).toISOString(),
        properties: { ref: IDENTIFIER.test(ref) ? ref : 'direct', ...(where ? { country: where } : {}), $lib: 'moku-relay', $process_person_profile: false, $geoip_disable: true },
      }], 'download');
      // The person shouldn't wait on PostHog: give it a moment, then redirect regardless.
      await Promise.race([counting, new Promise((resolve) => setTimeout(resolve, 800))]);
    }
    return new Response(null, { status: 302, headers: { location: '/download', 'cache-control': 'no-store' } });
  }

  return { events, download };
}
