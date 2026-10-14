// @ts-check
/**
 * Remote switches (docs/launch-plan.md §4), with no database:
 *   - defaults live in code (DEFAULTS); the call limits start from MOKU_RATE_PER_MINUTE and MOKU_RATE_PER_DAY, as before;
 *   - MOKU_FLAGS (JSON) overrides them for everyone, one plan, or one install;
 *   - Vercel Global Config (formerly Edge Config), when GLOBAL_CONFIG or EDGE_CONFIG is set: its `flags` item, in the
 *     same shape, read at most every 30 s per instance and laid over MOKU_FLAGS. A change there needs no redeploy.
 *
 *   MOKU_FLAGS={"everyone":{"cloudJudging":false},"plans":{"trial":{"callsPerDay":2000}},"devices":{"a1b2c3d4e5f6":{"forceCalm":true}}}
 *
 * The most specific scope wins: everyone, then the plan (tester, trial or pro), then the device (its id as PostHog
 * shows it, 12 hex characters, or the whole 64). Within a scope Global Config wins over MOKU_FLAGS. A bad entry is
 * dropped and the rest still applies, so one typo can't stop a kill switch; /health counts the problems and the logs
 * name them (`npm run check-flags` checks a value before it goes in).
 *
 * newInstallsPerDay caps new trials a day, for everyone only (invites always get in). Without Upstash each function
 * instance counts on its own from its own start, so the real number can be the cap times the instances running, a
 * cold start forgets the count, and a reinstall counts as new. With Upstash the count is shared and exact per UTC day,
 * and a Mac seen before isn't counted.
 */

export const DEFAULTS = Object.freeze({
  /** Jev judges work or drift. Off: the relay refuses Jev and the brain judges by its rules alone. */
  cloudJudging: true,
  /** Luna writes Moku's lines. Off: the relay refuses Luna and Moku uses its built-in lines. */
  cloudVoice: true,
  /** The app never reacts to a drift (no sad face, no nudge); it's still glad when you come back. */
  forceCalm: false,
  /** Builds older than this ask Sparkle for an update. null: none. */
  minVersion: /** @type {string | null} */ (null),
  /** Model calls per install, per minute and per UTC day (the per-plan limits). */
  callsPerMinute: 60,
  callsPerDay: 3000,
  /** New trials a UTC day, for everyone. null: no cap; 0: closed. */
  newInstallsPerDay: /** @type {number | null} */ (null),
  /**
   * The governor (governor.js): what trial Macs may spend on the models a UTC day, shared among them. $1.60 is $48 a
   * month, under the AI Gateway's $50 stop. null: no governor (each trial keeps its callsPerDay). For everyone only.
   */
  dailyBudgetUsd: /** @type {number | null} */ (1.6),
  /** What one model call costs on average, Luna's share included (PostHog, 2026-10-09: Jev $0.000038). For everyone only. */
  costPerCall: 0.00004,
  /**
   * Apple App Attest at install (attest.js, docs/specs/app-attest.md), for everyone only. 'off': ignored. 'observe': a
   * trial is given either way, the result is logged and a verified one is marked `att`. 'require': a Mac not seen
   * before and without a verified attestation gets no trial (403 attestation_required); invites are never asked.
   */
  attestation: /** @type {'off' | 'observe' | 'require'} */ ('off'),
});

/**
 * A trial's model calls a UTC day before any MOKU_FLAGS entry, and never above MOKU_RATE_PER_DAY. A friend's day is
 * about 300 calls and the busiest any Mac has had is 2,978 (PostHog, 2026-10-09); anyone can mint a trial, so this is
 * what one can cost. Any MOKU_FLAGS entry for callsPerDay (everyone, the plan or the device) still wins.
 */
export const TRIAL_CALLS_PER_DAY = 3000;

/** @typedef {{ -readonly [K in keyof typeof DEFAULTS]: (typeof DEFAULTS)[K] }} Flags */
/** @typedef {Partial<Flags>} Overrides */
/** @typedef {{ everyone: Overrides, plans: Record<string, Overrides>, devices: Record<string, Overrides>, problems: string[] }} FlagsDoc */
/** @typedef {{ plan?: string | null, device?: string | null }} Who */

/** What the app gets from /v1/flags. The limits stay on the relay. */
export const APP_FLAGS = /** @type {const} */ (['cloudJudging', 'cloudVoice', 'forceCalm', 'minVersion']);
export const PLANS = ['tester', 'trial', 'pro'];
const VERSION = /^[0-9]{1,3}(\.[0-9]{1,3}){0,3}$/;
const DEVICE = /^[0-9a-f]{12,64}$/;
const isCount = (/** @type {unknown} */ v) => Number.isInteger(v) && /** @type {number} */ (v) >= 0;
const isAmount = (/** @type {unknown} */ v) => typeof v === 'number' && Number.isFinite(v) && v >= 0;

/** Each flag's shape, and how to say what it should be. */
const SHAPES = /** @type {Record<keyof Flags, [(v: unknown) => boolean, string]>} */ ({
  cloudJudging: [(v) => typeof v === 'boolean', 'true or false'],
  cloudVoice: [(v) => typeof v === 'boolean', 'true or false'],
  forceCalm: [(v) => typeof v === 'boolean', 'true or false'],
  minVersion: [(v) => v === null || (typeof v === 'string' && VERSION.test(v)), 'a version like "0.1.8", or null'],
  callsPerMinute: [isCount, 'a whole number, 0 or more'],
  callsPerDay: [isCount, 'a whole number, 0 or more'],
  newInstallsPerDay: [(v) => v === null || isCount(v), 'a whole number, 0 or more, or null'],
  dailyBudgetUsd: [(v) => v === null || isAmount(v), 'dollars, 0 or more, or null'],
  costPerCall: [(v) => isAmount(v) && /** @type {number} */ (v) > 0, 'dollars, more than 0'],
  attestation: [(v) => v === 'off' || v === 'observe' || v === 'require', '"off", "observe" or "require"'],
});
const EVERYONE_ONLY = new Set(['newInstallsPerDay', 'dailyBudgetUsd', 'costPerCall', 'attestation']);

const isObject = (/** @type {unknown} */ v) => Boolean(v) && typeof v === 'object' && !Array.isArray(v);

/** One scope's overrides: the entries that fit, and a problem for each that doesn't. */
function overrides(/** @type {unknown} */ raw, /** @type {string} */ where, /** @type {string[]} */ problems, everyone = false) {
  /** @type {Record<string, unknown>} */
  const out = {};
  if (!isObject(raw)) { problems.push(`${where}: expected an object of flags`); return /** @type {Overrides} */ (out); }
  for (const [name, value] of Object.entries(/** @type {Record<string, unknown>} */ (raw))) {
    // Own names only: `constructor` or `__proto__` would find Object's and crash the relay, losing the kill switch.
    const shape = Object.hasOwn(SHAPES, name) ? SHAPES[/** @type {keyof Flags} */ (name)] : undefined;
    if (!shape) problems.push(`${where}.${name}: not a flag (${Object.keys(SHAPES).join(', ')})`);
    else if (!everyone && EVERYONE_ONLY.has(name)) problems.push(`${where}.${name}: only for everyone`);
    else if (!shape[0](value)) problems.push(`${where}.${name}: expected ${shape[1]}`);
    else out[name] = value;
  }
  return /** @type {Overrides} */ (out);
}

/**
 * MOKU_FLAGS (a JSON string) or Global Config's item (already parsed) → the overrides per scope, and what was dropped.
 * @param {unknown} raw
 * @param {string} source
 * @returns {FlagsDoc}
 */
export function parseFlags(raw, source) {
  /** @type {FlagsDoc} */
  const doc = { everyone: {}, plans: {}, devices: {}, problems: [] };
  if (raw === undefined || raw === null || raw === '') return doc;
  let value = raw;
  if (typeof raw === 'string') {
    try { value = JSON.parse(raw); } catch { doc.problems.push(`${source}: not JSON`); return doc; }
  }
  if (!isObject(value)) { doc.problems.push(`${source}: expected {"everyone": …, "plans": …, "devices": …}`); return doc; }
  for (const [scope, entries] of Object.entries(/** @type {Record<string, unknown>} */ (value))) {
    if (scope === 'everyone') doc.everyone = overrides(entries, `${source}.everyone`, doc.problems, true);
    else if (scope === 'plans' || scope === 'devices') {
      if (!isObject(entries)) { doc.problems.push(`${source}.${scope}: expected an object`); continue; }
      for (const [key, flags] of Object.entries(/** @type {Record<string, unknown>} */ (entries))) {
        const id = key.toLowerCase();
        if (scope === 'plans' && !PLANS.includes(id)) doc.problems.push(`${source}.plans.${key}: not a plan (${PLANS.join(', ')})`);
        else if (scope === 'devices' && !DEVICE.test(id)) doc.problems.push(`${source}.devices.${key}: a device id is 12 to 64 hex characters`);
        else doc[scope][id] = overrides(flags, `${source}.${scope}.${key}`, doc.problems);
      }
    } else doc.problems.push(`${source}.${scope}: not a scope (everyone, plans, devices)`);
  }
  return doc;
}

/** Whether a device id in the overrides means this device: the same id, compared over the shorter of the two. */
export function sameDevice(/** @type {string} */ key, /** @type {string} */ device) {
  const length = Math.min(key.length, device.length);
  return length >= 12 && key.slice(0, length) === device.slice(0, length);
}

/**
 * The flags for one install: `base`, then each doc's everyone, then each doc's plan, then each doc's device.
 * @param {Flags} base
 * @param {FlagsDoc[]} docs
 * @param {Who} who
 * @returns {Flags}
 */
export function resolveFlags(base, docs, { plan, device } = {}) {
  const flags = { ...base };
  for (const doc of docs) Object.assign(flags, doc.everyone);
  if (plan) for (const doc of docs) Object.assign(flags, doc.plans[plan]);
  if (device) {
    for (const doc of docs) {
      for (const [key, overrides] of Object.entries(doc.devices)) if (sameDevice(key, device)) Object.assign(flags, overrides);
    }
  }
  return flags;
}

/** The fields the app reads. */
export const appFlags = (/** @type {Flags} */ flags) => Object.fromEntries(APP_FLAGS.map((name) => [name, flags[name]]));

/**
 * Reads the `flags` item from a Global Config (Edge Config) store over HTTP, keeping it for `ttlMs`. A failure keeps
 * the last value it read (or none), so a hiccup there never flips a switch.
 * @param {{ connection: string, fetch: typeof fetch, now: () => number, log: (line: string) => void, ttlMs?: number }} options
 * @returns {() => Promise<unknown>}
 */
export function globalConfigReader({ connection, fetch, now, log, ttlMs = 30_000 }) {
  /** @type {{ at: number, value: unknown } | null} */
  let cached = null;
  let url = '', token = '';
  try {
    const parsed = new URL(connection);
    token = parsed.searchParams.get('token') ?? '';
    url = `${parsed.origin}${parsed.pathname.replace(/\/$/, '')}/item/flags?version=1`;
  } catch { /* a malformed connection string: logged on first read */ }
  return async () => {
    if (cached && now() - cached.at < ttlMs) return cached.value;
    if (!url || !token) {
      if (!cached) log('moku-proxy flags global-config-error the connection string has no token');
      cached = { at: now(), value: null };
      return null;
    }
    try {
      const res = await fetch(url, { headers: { authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(2000) });
      if (res.status !== 404 && !res.ok) throw new Error(`status ${res.status}`);
      // 404: the store has no `flags` item (yet).
      cached = { at: now(), value: res.status === 404 ? null : await res.json() };
    } catch (error) {
      log(`moku-proxy flags global-config-error ${/** @type {Error} */ (error).message}`);
      cached = { at: now(), value: cached?.value ?? null };
    }
    return cached.value;
  };
}

/**
 * @param {{ env: Record<string, string | undefined>, fetch: typeof fetch, now: () => number, log: (line: string) => void }} deps
 */
export function createFlags({ env, fetch, now, log }) {
  const base = /** @type {Flags} */ ({
    ...DEFAULTS, callsPerMinute: Number(env.MOKU_RATE_PER_MINUTE || DEFAULTS.callsPerMinute), callsPerDay: Number(env.MOKU_RATE_PER_DAY || DEFAULTS.callsPerDay),
  });
  const fromEnv = parseFlags(env.MOKU_FLAGS, 'MOKU_FLAGS');
  if (fromEnv.problems.length) log(`moku-proxy flags dropped: ${fromEnv.problems.join('; ')}`);
  const connection = env.GLOBAL_CONFIG || env.EDGE_CONFIG;
  const readRemote = connection ? globalConfigReader({ connection, fetch, now, log }) : null;
  /** @type {{ text: string, doc: FlagsDoc } | null} */
  let remote = null;

  /** MOKU_FLAGS, then Global Config's item when there is one (parsed again only when it changes). */
  async function docs() {
    if (!readRemote) return [fromEnv];
    const value = await readRemote();
    const text = JSON.stringify(value);
    if (!remote || remote.text !== text) {
      remote = { text, doc: parseFlags(value, 'global-config') };
      if (remote.doc.problems.length) log(`moku-proxy flags dropped: ${remote.doc.problems.join('; ')}`);
    }
    return [fromEnv, remote.doc];
  }

  return {
    /** The flags for one install (its plan and device, when known). */
    forWho: async (/** @type {Who} */ who) => resolveFlags(
      // Pro has the trial's cap too: a heavy day is about 400 calls (PostHog, 2026-10-14), and 3,000 cost about $0.12.
      who.plan === 'trial' || who.plan === 'pro' ? { ...base, callsPerDay: Math.min(base.callsPerDay, TRIAL_CALLS_PER_DAY) } : base, await docs(), who),
    /** For /health: where the flags come from and how many entries were dropped, never the flags themselves. */
    health: async () => {
      const all = await docs();
      const source = env.MOKU_FLAGS ? (readRemote ? 'MOKU_FLAGS+global-config' : 'MOKU_FLAGS') : readRemote ? 'global-config' : 'code';
      return { source, problems: all.reduce((n, doc) => n + doc.problems.length, 0) };
    },
  };
}
