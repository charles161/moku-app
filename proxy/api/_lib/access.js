// @ts-check
import { createHash, createHmac, timingSafeEqual } from 'node:crypto';

/**
 * Who may reach Jev and Luna through the relay, without a database of users:
 *   - a signed token per install, `moku1.<payload>.<hmac>`, made with MOKU_TOKEN_SECRET. The payload says whose it
 *     is (a device, or a tester), the plan (tester, trial or pro) and when a trial ends. The relay checks the
 *     signature and the date; nothing to look up.
 *   - POST /v1/install gives one to a device: with an invite code (MOKU_INVITES, "name:sha256(code)") it's a
 *     tester; otherwise it's a 21-day trial, dated from the first time that device was seen (kept in Redis when
 *     configured, so reinstalling doesn't restart it).
 * A trial that has ended gets 402: the brain's breaker pauses the cloud and Moku judges by its rules (release
 * builds carry no local model).
 * The device id is a hash the app makes of the Mac's hardware id; the relay never sees the id itself.
 *
 * Every token's `exp` is checked on every call (admit): a trial's is its end; a pro token must carry one (the end of
 * what was paid for; none has been minted yet); a tester's is checked when it has one. Tester tokens from /v1/install
 * still carry none (`exp: 0`), because the apps shipped so far (0.1.4–0.1.9) never renew: they keep working, and
 * taking the invite's name out of MOKU_INVITES still revokes them. POST /v1/renew is the way forward: a tester's token,
 * with or without an expiry, comes back with one TOKEN_DAYS out (its invite checked again), so an app that renews
 * holds a token that lapses unless renewed. A trial's or a pro token's end never moves there.
 */

export const TRIAL_DAYS = 21;
/** How long a renewed tester token lasts. An app that renews does it well before then. */
export const TOKEN_DAYS = 30;
/** How long after a tester token lapses it can still be renewed (a Mac asleep or offline for a while). */
export const RENEW_GRACE_DAYS = 30;
const DAY_MS = 86_400_000;
const b64 = (/** @type {Buffer | string} */ v) => Buffer.from(v).toString('base64url');

/** @typedef {{ sub: string, plan: 'tester' | 'trial' | 'pro', exp: number, iat: number, att?: 1 }} Claims `att`: Apple vouched for this Mac at install (attest.js). */

export function signToken(/** @type {Claims} */ claims, /** @type {string} */ secret) {
  const payload = b64(JSON.stringify(claims));
  return `moku1.${payload}.${b64(createHmac('sha256', secret).update(payload).digest())}`;
}

/** The claims of a genuine token, or null (malformed, or signed with another secret). */
export function readToken(/** @type {string} */ token, /** @type {string | undefined} */ secret) {
  if (!secret || !token.startsWith('moku1.')) return null;
  const [, payload, sig] = token.split('.');
  if (!payload || !sig) return null;
  const want = createHmac('sha256', secret).update(payload).digest(), got = Buffer.from(sig, 'base64url');
  if (want.length !== got.length || !timingSafeEqual(want, got)) return null;
  try {
    const claims = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
    return typeof claims.sub === 'string' && ['tester', 'trial', 'pro'].includes(claims.plan) && typeof claims.exp === 'number' ? /** @type {Claims} */ (claims) : null;
  } catch {
    return null;
  }
}

/** Invite codes are typed by people: case and dashes don't matter. */
export const normalizeInvite = (/** @type {string} */ code) => code.toUpperCase().replace(/[^A-Z0-9]/g, '');
export const hashInvite = (/** @type {string} */ code) => createHash('sha256').update(normalizeInvite(code)).digest('hex');

/** "name:hash,…" → the name whose code this is, or null (constant time per entry). */
export function inviteFor(/** @type {string} */ code, /** @type {string | undefined} */ raw) {
  const hash = Buffer.from(hashInvite(code), 'hex');
  let found = null;
  for (const entry of (raw ?? '').split(',').map((e) => e.trim()).filter(Boolean)) {
    const [name, hex] = entry.split(':');
    if (name && hex && /^[0-9a-f]{64}$/i.test(hex) && timingSafeEqual(hash, Buffer.from(hex, 'hex'))) found = name;
  }
  return found;
}

/** The friends' names in MOKU_INVITES ("name:hash,…"): taking a name out revokes every token its invite gave. */
export const inviteNames = (/** @type {string | undefined} */ raw) =>
  new Set((raw ?? '').split(',').map((entry) => entry.trim().split(':')[0]).filter(Boolean));

/** How many Macs one invite may be used on (MOKU_INVITE_MACS moves it): a friend's own Mac or two, not a crowd. */
export const INVITE_MACS = 2;

/** @typedef {{ url?: string, token?: string, fetch?: typeof fetch, now: number }} Redis */

/**
 * How long a request to Redis may take. Past it Redis counts as failing, as an error does: a Redis that hangs would
 * otherwise hold every request that asks it until the function times out.
 */
export const REDIS_TIMEOUT_MS = 2000;

/** Upstash's REST pipeline: one result per command, or null without Redis or when it fails. */
export async function pipeline(/** @type {Redis} */ redis, /** @type {string[][]} */ commands) {
  if (!redis.url || !redis.token) return null;
  try {
    const res = await (redis.fetch ?? fetch)(`${redis.url.replace(/\/$/, '')}/pipeline`, {
      method: 'POST', headers: { authorization: `Bearer ${redis.token}`, 'content-type': 'application/json' },
      body: JSON.stringify(commands), signal: AbortSignal.timeout(REDIS_TIMEOUT_MS),
    });
    if (!res.ok) throw new Error(`redis ${res.status}`);
    return /** @type {{ result?: string | null }[]} */ (await res.json());
  } catch {
    return null;
  }
}

/**
 * When this device was first seen (ms): Redis SET NX, so the first install's date sticks; without Redis, now.
 * @param {string} device
 * @param {Redis} redis
 */
export async function firstSeen(device, redis) {
  const key = `moku:device:${device}`;
  const [, got] = (await pipeline(redis, [['SET', key, String(redis.now), 'NX'], ['GET', key]])) ?? [];
  const seen = Number(got?.result);
  return Number.isFinite(seen) && seen > 0 ? seen : redis.now;
}

/**
 * Whether invite `name` may take this Mac: yes if the Mac already holds one of its `limit` places, or it can claim a
 * free one; a place is never given back.
 *
 * With Redis each place is a key of its own, `moku:invite:<name>:place:<n>`, claimed with SET NX, which Redis runs
 * atomically: of two Macs at the same moment only one gets the last place, whichever relay instance each reaches.
 * (Before, the check, SISMEMBER and SCARD, and the add, SADD, were two requests, so redemptions at the same moment all
 * passed the check: security review 2026-10-05.) The Macs already in that earlier set, `moku:invite:<name>`, keep the
 * first places; nothing adds to it any more, so its size can't change under a claim.
 *
 * Without Redis, or when it fails, `places` (this instance's memory) holds them: exact within the instance (the check
 * and the add are one synchronous step), but each instance counts on its own and forgets at a cold start, so across
 * instances an invite can reach more Macs than `limit`.
 * @param {string} name
 * @param {string} device
 * @param {number} limit
 * @param {Redis} redis
 * @param {Map<string, Set<string>>} places
 */
export async function inviteTakes(name, device, limit, redis, places) {
  const legacy = `moku:invite:${name}`;
  const keys = Array.from({ length: limit }, (_, i) => `${legacy}:place:${i + 1}`);
  const seen = await pipeline(redis, [['SISMEMBER', legacy, device], ['SCARD', legacy], ...keys.map((key) => ['GET', key])]);
  const answered = seen?.length === keys.length + 2 && seen.every((reply) => reply && !('error' in reply));
  const taken = answered ? await claimPlace(redis, device, keys, seen) : null;
  if (typeof taken === 'boolean') return taken;
  const macs = places.get(name) ?? new Set();
  if (!macs.has(device)) {
    if (macs.size >= limit) return false;
    macs.add(device);
    places.set(name, macs);
  }
  return true;
}

/**
 * The Redis half of inviteTakes, from one read of the legacy set and every place: whether the Mac holds or claims a
 * place, or null when Redis failed on the way. Places are tried in order, so two requests from one Mac at once claim
 * the same place, and the second finds the Mac there.
 * @param {Redis} redis
 * @param {string} device
 * @param {string[]} keys
 * @param {{ result?: string | number | null }[]} seen
 */
async function claimPlace(redis, device, keys, seen) {
  const [member, count, ...held] = seen;
  if (Number(member?.result) === 1 || held.some((place) => place?.result === device)) return true;
  for (let i = Number(count?.result) || 0; i < keys.length; i++) {
    if (held[i]?.result) continue;
    const claim = await pipeline(redis, [['SET', keys[i], device, 'NX'], ['GET', keys[i]]]);
    // After SET NX the place holds someone, this Mac or another: no answer means Redis failed.
    const holder = claim?.[1]?.result;
    if (holder === undefined || holder === null) return null;
    if (holder === device) return true;
  }
  return false;
}

/** Whether this device has installed before (Redis only: without it, or when it fails, every device is new). */
export async function seenBefore(/** @type {string} */ device, /** @type {Redis} */ redis) {
  const [got] = (await pipeline(redis, [['GET', `moku:device:${device}`]])) ?? [];
  return Boolean(got?.result);
}

/** The device id inside a token's subject: a trial's whole hash, or the 12 characters after a tester's name. */
export function deviceOf(/** @type {Claims | null} */ claims) {
  const id = claims?.sub.split('/').at(-1) ?? '';
  return /^[0-9a-f]{12,64}$/.test(id) ? id : null;
}

/**
 * What a token lets through right now: `{ ok: true, subject }`, or a status to answer with.
 * @returns {{ ok: true, subject: string, plan: string } | { ok: false, status: number, error: string }}
 */
export function admit(/** @type {Claims | null} */ claims, /** @type {number} */ now, /** @type {Set<string> | undefined} */ invites = undefined) {
  if (!claims) return { ok: false, status: 401, error: 'unknown token' };
  if (claims.plan === 'trial' && now >= claims.exp) return { ok: false, status: 402, error: 'trial ended' };
  // Pro is paid for a while: a token without an end would be pro for good.
  if (claims.plan === 'pro' && !(claims.exp > 0)) return { ok: false, status: 401, error: 'token has no expiry' };
  if (claims.plan === 'pro' && now >= claims.exp) return { ok: false, status: 402, error: 'pro ended' };
  // A tester's token is its invite's: once the name is out of MOKU_INVITES, the token stops working.
  if (claims.plan === 'tester' && invites && !invites.has(claims.sub.split('/')[0])) return { ok: false, status: 401, error: 'invite revoked' };
  if (claims.plan === 'tester' && claims.exp > 0 && now >= claims.exp) return { ok: false, status: 401, error: 'token expired' };
  return { ok: true, subject: `${claims.plan}:${claims.sub}`, plan: claims.plan };
}

/**
 * POST /v1/renew's answer for a genuine token: the claims of its fresh token, or a status to answer with. A tester's
 * gets TOKEN_DAYS from now while its invite is still listed (even a token without an expiry, or one that lapsed less
 * than RENEW_GRACE_DAYS ago); a live trial or pro token is signed again with the same end, which only the first day
 * seen (a trial) or a payment (pro, later) sets.
 * @returns {{ ok: true, claims: Claims } | { ok: false, status: number, error: string }}
 */
export function renewal(/** @type {Claims | null} */ claims, /** @type {number} */ now, /** @type {Set<string>} */ invites) {
  if (!claims) return { ok: false, status: 401, error: 'unknown token' };
  if (claims.plan === 'tester') {
    if (!invites.has(claims.sub.split('/')[0])) return { ok: false, status: 401, error: 'invite revoked' };
    if (claims.exp > 0 && now >= claims.exp + RENEW_GRACE_DAYS * DAY_MS) return { ok: false, status: 401, error: 'token expired' };
    return { ok: true, claims: { sub: claims.sub, plan: 'tester', exp: now + TOKEN_DAYS * DAY_MS, iat: now } };
  }
  const admitted = admit(claims, now, invites);
  if (!admitted.ok) return admitted;
  return { ok: true, claims: { sub: claims.sub, plan: claims.plan, exp: claims.exp, iat: now, ...(claims.att ? { att: /** @type {const} */ (1) } : {}) } };
}

/** A 21-day trial from `start`. */
export const trialClaims = (/** @type {string} */ device, /** @type {number} */ start, /** @type {number} */ now, /** @type {boolean} */ attested = false) =>
  /** @type {Claims} */ ({ sub: device, plan: 'trial', exp: start + TRIAL_DAYS * DAY_MS, iat: now, ...(attested ? { att: 1 } : {}) });
