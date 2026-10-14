// @ts-check
/**
 * The governor (docs/specs/governor.md, approved by Charles 2026-10-09): AI spend stays inside the budget however
 * many Macs install. Anyone who downloads Moku gets a trial, so the door stays open and the spend is held here.
 *
 *   - Each trial Mac may make an equal share of the day's budget in model calls (`dailyBudgetUsd` ÷ `costPerCall`).
 *     Macs in their first NEW_DAYS share a quarter of it, so a newcomer meets Moku at its best; the rest is shared by
 *     the established ones. A share the per-Mac cap (the trial's `callsPerDay`) leaves unused goes to the other group.
 *   - Past its share a Mac gets 429 `daily_limit` with Retry-After until UTC midnight, and its brain judges by its
 *     rules. Later calls that day are refused from this instance's memory, without Redis.
 *   - Testers (invites), static tokens and pro aren't governed: they keep their own `callsPerDay`.
 *   - The number of Macs to share among is the larger of yesterday's and today's so far, so a surge shrinks the share
 *     the same day. `dailyBudgetUsd: null` turns the governor off.
 *   - A hard pool on top, in dollars: the day's governed calls never spend past `dailyBudgetUsd`. Each call adds what
 *     the gateway says it cost, or `costPerCall` when it doesn't say (open-source review 2026-10-14: the pool counted
 *     calls at `costPerCall`, so dearer calls, Luna's or the largest a body allows, spent past the budget). On a first
 *     day of 100,000 Macs the shares alone spent twice the budget (each early Mac's share was set before the crowd
 *     came); the pool stops that, and the late arrivals of such a day get rules only. From the next day the shares are
 *     fair again.
 *
 * Redis, one command per call: a hash per UTC day and group (new, established, other) holds each holder's calls
 * (HINCRBY), so a group's active Macs are its length (HLEN). Each instance reads the lengths at most once a minute
 * (or after 200 calls or $0.008) and adds its spend since to the day's dollars (INCRBYFLOAT) in the same request,
 * counting the Macs it sees arrive in between. A call is held at `costPerCall` from when it's let through until the
 * gateway answers, so calls in flight count too. Without Redis (a local run), the same counts live in this instance's
 * memory. With Redis configured but failing (down, slow past REDIS_TIMEOUT_MS, or its quota used up), governed calls get
 * 503 `cloud_off` and the brain judges by its rules: each instance's memory would let every instance spend the whole
 * budget (open-source review 2026-10-14, finding 2). Calls that aren't governed keep counting in memory.
 *
 * Once a day one instance sends PostHog a `governor_day` event: yesterday's active Macs and dollars, today's shares.
 * Counts only, never a device.
 */
import { pipeline, TRIAL_DAYS } from './access.js';
import { DEFAULT_HOST } from './heartbeat.js';
import { vercelWaitUntil } from './usage.js';

const DAY_MS = 86_400_000;
/** A trial younger than this (at the start of the UTC day) is new. */
export const NEW_DAYS = 3;
/** The new Macs' part of the day's budget. */
export const NEW_SHARE = 0.25;
const REFRESH_MS = 60_000;
/**
 * An instance adds its governed spend to the day's dollars at least this often (and at each read): after this many
 * calls or this many dollars, so the pool is passed by about $0.008 per instance at most (plus calls in flight).
 */
const FLUSH_CALLS = 200;
const FLUSH_USD = 0.008;
const KEEP_SEC = String(3 * 86_400);

/** Seconds until the next UTC midnight (at least 1): when the day's counts start again. */
export const untilMidnight = (/** @type {number} */ now) => Math.max(1, Math.ceil((DAY_MS - (now % DAY_MS)) / 1000));

const dateOf = (/** @type {number} */ day) => new Date(day * DAY_MS).toISOString().slice(0, 10);
/** The day's governed dollars, from every instance. */
const dollarsKey = (/** @type {number} */ day) => `moku:spent-usd:${dateOf(day)}`;
/** Dollars as INCRBYFLOAT takes them: fixed point, never exponent notation. */
const dollars = (/** @type {number} */ usd) => usd.toFixed(9);

/**
 * Each trial Mac's calls for the day: a quarter of the budget shared by the new Macs, the rest by the established
 * ones, each share whole calls and at most `cap`. What a capped share leaves goes to the other group; a group alone
 * takes the whole budget; a group with nobody in it is at the cap (the first to arrive is counted at once).
 * @param {{ budgetCalls: number, cap: number, activeNew: number, activeOld: number }} counts
 */
export function allowances({ budgetCalls, cap, activeNew, activeOld }) {
  const share = (/** @type {number} */ calls, /** @type {number} */ macs) => (macs > 0 ? Math.min(cap, Math.floor(Math.max(0, calls) / macs)) : cap);
  const fresh = share(activeOld > 0 ? budgetCalls * NEW_SHARE : budgetCalls, activeNew);
  const settled = share(budgetCalls - (activeNew > 0 ? fresh * activeNew : 0), activeOld);
  return { fresh, settled };
}

/**
 * @typedef {{ subject: string, plan: string, claims: { exp: number } | null }} Holder
 * @typedef {{ callsPerDay: number, dailyBudgetUsd: number | null, costPerCall: number }} Limits
 * @typedef {{ day: number, at: number, yNew: number, yOld: number, tNew: number, tOld: number, spentUsd: number }} Counts
 */

/**
 * @param {{ env: Record<string, string | undefined>, fetch: typeof fetch, now: () => number, log: (line: string) => void,
 *   waitUntil?: (promise: Promise<unknown>) => void }} deps
 */
export function createGovernor({ env, fetch, now, log, waitUntil = vercelWaitUntil }) {
  const url = env.UPSTASH_REDIS_REST_URL || env.KV_REST_API_URL;
  const token = env.UPSTASH_REDIS_REST_TOKEN || env.KV_REST_API_TOKEN;
  const redis = () => ({ url, token, fetch, now: now() });
  /** Whether Redis is configured: then a failure refuses governed calls instead of counting in memory. */
  const shared = Boolean(url && token);
  /** Without Redis: each day's and group's holders and their calls, in this instance's memory. */
  const memory = /** @type {Map<string, Map<string, number>>} */ (new Map());
  /** Holders refused for the rest of a day (their day), so their later calls cost nothing. */
  const refused = /** @type {Map<string, number>} */ (new Map());
  /** @type {Counts | null} */
  let counts = null;
  /** @type {Promise<Counts> | null} */
  let reading = null;
  const expiring = new Set();
  let reportedDay = -1;
  /** Governed calls this instance let through, and their dollars, not yet added to the day's dollars. */
  let pending = { day: -1, calls: 0, usd: 0 };
  /** Without Redis: the day's dollars in this instance. */
  const spentHere = /** @type {Map<number, number>} */ (new Map());

  const hashKey = (/** @type {number} */ day, /** @type {string} */ group) => `moku:calls:${dateOf(day)}:${group}`;

  /** Whether a holder is a trial Mac in its first NEW_DAYS (new), an established trial (old), or not governed (other). */
  function groupOf(/** @type {Holder} */ who, /** @type {number} */ day) {
    if (who.plan !== 'trial' || !who.claims) return 'other';
    const start = who.claims.exp - TRIAL_DAYS * DAY_MS;
    return day * DAY_MS - start < NEW_DAYS * DAY_MS ? 'new' : 'old';
  }

  /**
   * Counts this call: the holder's calls today, this one included. Null when Redis is configured but failing and
   * `inMemory` is off; with it on (or without Redis) the call is counted in this instance's memory instead.
   */
  async function countCall(/** @type {number} */ day, /** @type {string} */ group, /** @type {string} */ field, /** @type {boolean} */ inMemory) {
    const key = hashKey(day, group);
    const [got] = (await pipeline(redis(), [['HINCRBY', key, field, '1']])) ?? [];
    const n = Number(got?.result);
    if (Number.isFinite(n) && n > 0) return n;
    if (shared && !inMemory) return null;
    const hash = memory.get(key) ?? new Map();
    memory.set(key, hash);
    const mine = (hash.get(field) ?? 0) + 1;
    hash.set(field, mine);
    return mine;
  }

  /**
   * Yesterday's and today's active Macs per group, and the day's governed dollars with this instance's added: read at
   * most once a minute, or after FLUSH_CALLS calls or FLUSH_USD (a new day reads at once). Null when Redis is configured
   * but failing: this instance's spend then waits for the next read.
   * @returns {Promise<Counts | null>}
   */
  async function read(/** @type {number} */ day) {
    // A new day: what this instance spent yesterday and hadn't added yet goes to yesterday's dollars (governor_day).
    const leftover = pending.day === day - 1 ? pending.usd : 0;
    if (pending.day !== day) pending = { day, calls: 0, usd: 0 };
    const flushed = { calls: pending.calls, usd: pending.usd };
    const keys = [hashKey(day - 1, 'new'), hashKey(day - 1, 'old'), hashKey(day, 'new'), hashKey(day, 'old')];
    const spentKey = dollarsKey(day);
    const commands = [...keys.map((key) => ['HLEN', key]), ['INCRBYFLOAT', spentKey, dollars(flushed.usd)]];
    if (leftover) commands.push(['INCRBYFLOAT', dollarsKey(day - 1), dollars(leftover)]);
    const got = await pipeline(redis(), commands);
    if (shared && !(got?.length === commands.length && got.every((reply) => reply && !('error' in reply)))) return null;
    pending.calls -= flushed.calls;
    pending.usd -= flushed.usd;
    const sizes = keys.map((key, i) => (got ? Number(got[i]?.result) || 0 : memory.get(key)?.size ?? 0));
    let spentUsd;
    if (got) {
      spentUsd = Number(got[4]?.result) || 0;
      // Each day's hashes and dollars are kept three days; once per instance, after they exist.
      const late = [...keys.slice(2).filter((key, i) => sizes[i + 2] > 0), spentKey].filter((key) => !expiring.has(key));
      if (late.length) { await pipeline(redis(), late.map((key) => ['EXPIRE', key, KEEP_SEC])); late.forEach((key) => expiring.add(key)); }
    } else {
      spentUsd = (spentHere.get(day) ?? 0) + flushed.usd;
      spentHere.set(day, spentUsd);
    }
    if (day !== counts?.day) {
      for (const key of memory.keys()) if (!key.includes(dateOf(day)) && !key.includes(dateOf(day - 1))) memory.delete(key);
      for (const d of spentHere.keys()) if (d !== day) spentHere.delete(d);
    }
    return { day, at: now(), yNew: sizes[0], yOld: sizes[1], tNew: sizes[2], tOld: sizes[3], spentUsd };
  }

  /** The day's counts, read again when they're stale; null when Redis is configured but failing. */
  async function current(/** @type {number} */ day) {
    if (counts && counts.day === day && now() - counts.at < REFRESH_MS && pending.calls < FLUSH_CALLS && pending.usd < FLUSH_USD) return { counts, fresh: false };
    reading ??= read(day).finally(() => { reading = null; });
    const got = await reading;
    if (!got) return null;
    counts = got;
    return { counts: got, fresh: true };
  }

  /**
   * Once a day, one instance (Redis SET NX) tells PostHog yesterday's active Macs and dollars, and today's shares.
   * Yesterday's dollars are what every instance had added by then (each adds its last at its first read of the day).
   */
  async function report(/** @type {Counts} */ c, /** @type {Limits} */ limits) {
    if (reportedDay === c.day || !url || !token) return;
    reportedDay = c.day;
    if (c.yNew + c.yOld === 0) return; // nobody yesterday (the first day): nothing to tell
    const [claim, spent] = (await pipeline(redis(), [['SET', `moku:governor:reported:${dateOf(c.day - 1)}`, '1', 'NX', 'EX', KEEP_SEC], ['GET', dollarsKey(c.day - 1)]])) ?? [];
    if (claim?.result !== 'OK') return;
    const share = shares(c, limits);
    const properties = {
      day: dateOf(c.day - 1), active_new: c.yNew, active_old: c.yOld, budget_usd: limits.dailyBudgetUsd, cost_per_call: limits.costPerCall,
      spent_usd: Math.round((Number(spent?.result) || 0) * 1e6) / 1e6,
      allowance_new: share.fresh, allowance_old: share.settled, $process_person_profile: false, $geoip_disable: true,
    };
    log(`moku-proxy governor ${properties.day} active new=${c.yNew} old=${c.yOld} spent $${properties.spent_usd} today's share new=${share.fresh} old=${share.settled}`);
    if (!env.POSTHOG_KEY) return;
    const host = (env.POSTHOG_HOST || DEFAULT_HOST).replace(/\/$/, '');
    waitUntil(fetch(`${host}/i/v0/e/`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, signal: AbortSignal.timeout(3000),
      body: JSON.stringify({ api_key: env.POSTHOG_KEY, event: 'governor_day', distinct_id: 'moku-relay', properties }),
    }).then((res) => { if (!res.ok) log(`moku-proxy governor posthog-error ${res.status}`); })
      .catch((/** @type {Error} */ error) => log(`moku-proxy governor posthog-error ${error.message}`)));
  }

  const budgetCalls = (/** @type {Limits} */ limits) => Math.floor((limits.dailyBudgetUsd ?? 0) / limits.costPerCall + 1e-6);

  function shares(/** @type {Counts} */ c, /** @type {Limits} */ limits) {
    return allowances({ budgetCalls: budgetCalls(limits), cap: limits.callsPerDay, activeNew: Math.max(c.yNew, c.tNew), activeOld: Math.max(c.yOld, c.tOld) });
  }

  return {
    /**
     * Counts one model call and says whether it may go to the gateway. Once the gateway has answered, `settle` takes
     * what the call cost (null when the gateway didn't say: costPerCall is counted).
     * @param {Holder} who
     * @param {Limits} limits the holder's flags
     * @returns {Promise<{ ok: true, settle: (cost: number | null) => void } | { ok: false, status: number, body: object, headers: Record<string, string> }>}
     */
    async admit(who, limits) {
      const at = now();
      const day = Math.floor(at / DAY_MS);
      const refusal = { ok: /** @type {const} */ (false), status: 429, body: { error: 'daily limit reached', code: 'daily_limit' }, headers: { 'retry-after': String(untilMidnight(at)) } };
      if (refused.get(who.subject) === day) return refusal;
      const group = groupOf(who, day);
      const governed = group !== 'other' && limits.dailyBudgetUsd !== null;
      // Redis configured but failing: a governed call rests (the brain judges by its rules, as for the kill switch)
      // rather than each instance spending the whole budget from its own memory.
      const resting = () => {
        log(`moku-proxy ${who.subject.slice(0, 22)} governor redis-down`);
        return { ok: /** @type {const} */ (false), status: 503, body: { error: 'cloud off', code: 'cloud_off' }, headers: { 'retry-after': '60' } };
      };
      const calls = await countCall(day, group, who.subject, !governed);
      if (calls === null) return resting();
      let limit = limits.callsPerDay, why = '';
      if (governed) {
        const known = await current(day);
        if (!known) return resting();
        const { counts: c, fresh } = known;
        // A Mac's first call today, seen between two reads: count it here at once, so a surge shrinks the share now.
        if (calls === 1 && !fresh) { if (group === 'new') c.tNew++; else c.tOld++; }
        void report(c, limits);
        const share = shares(c, limits);
        limit = Math.min(limit, group === 'new' ? share.fresh : share.settled);
        // The pool: the day's governed dollars never pass the budget, whatever the shares say.
        if (calls <= limit && c.spentUsd + pending.usd >= /** @type {number} */ (limits.dailyBudgetUsd)) { limit = calls - 1; why = ' budget-spent'; }
      }
      if (calls <= limit) {
        if (!governed) return { ok: true, settle: () => {} };
        // Held at costPerCall until the gateway says what it cost, so calls in flight count against the pool too.
        pending.calls++;
        pending.usd += limits.costPerCall;
        return { ok: true, settle: (cost) => { if (pending.day === day) pending.usd += (cost ?? limits.costPerCall) - limits.costPerCall; } };
      }
      if (refused.size > 200_000) refused.clear();
      refused.set(who.subject, day);
      log(`moku-proxy ${who.subject.slice(0, 22)} daily-limit ${calls - 1}/${limit}${why}`);
      return refusal;
    },
  };
}
