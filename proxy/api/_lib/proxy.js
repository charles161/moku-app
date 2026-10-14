// @ts-check
import { createHash, timingSafeEqual } from 'node:crypto';
import { admit, deviceOf, firstSeen, INVITE_MACS, inviteFor, inviteNames, inviteTakes, pipeline, readToken, REDIS_TIMEOUT_MS, renewal, seenBefore, signToken, trialClaims } from './access.js';
import { clientAddress } from './address.js';
import { challengeIsFresh, newChallenge, verifyAttestation } from './attest.js';
import { createEvents } from './events.js';
import { appFlags, createFlags } from './flags.js';
import { createHeartbeat } from './heartbeat.js';
import { createPayments } from './payments.js';
import { createGovernor } from './governor.js';
import { MAX_BODY_BYTES, MAX_OUTPUT_TOKENS, requestProblem } from './shape.js';
import { createUsage, readUsage, who } from './usage.js';
import { createWebErrors } from './web-errors.js';
import { createWebVisits } from './web-visits.js';

/**
 * The Moku gateway proxy: testers' brains call the Vercel AI Gateway through here, with their own
 * token, so no tester ever holds the gateway key. Per request:
 *   1. a token: an install's signed token (moku1.…, access.js: a tester, a live trial or pro; an ended trial
 *      gets 402), or a tester's static token hashing (SHA-256) to an entry in MOKU_TESTER_TOKENS
 *      ("name:hexsha256,name:hexsha256"); the proxy never stores a token;
 *   2. only the two endpoints the brain uses (evaluation-model for Jev, language-model for Luna), each with its own
 *      models only (MOKU_JUDGE_MODELS, MOKU_VOICE_MODELS), and only the requests the brain makes, in its own sizes
 *      (shape.js: bodies up to 24 KB, Luna asked for 600 tokens at most);
 *   3. the remote switches (flags.js): with cloudJudging or cloudVoice off for this install, 503 "cloud off";
 *   4. per-token rate limits, per minute and per day, from the flags (Upstash Redis when configured, otherwise
 *      per instance, best effort);
 *   5. forwarded to the gateway with AI_GATEWAY_API_KEY, server-side, as the relay rebuilds it (upstreamRequest:
 *      only the brain's own headers and fields, zero data retention, never streamed); an answer comes back as is, an
 *      error as its status and a code word (gatewayError).
 * POST /v1/install gives a device its signed token and POST /v1/renew a fresh one for it (access.js); POST /v1/flags tells
 * the app its switches; POST /v1/attest/challenge gives an installing Mac the challenge its Apple App Attest statement
 * is made over (attest.js; the `attestation` flag says whether install asks for one);
 * POST /v1/heartbeat passes an opted-in Mac's daily counts on to PostHog (heartbeat.js); POST /v1/web-error passes an
 * error in hellomoku.com's own script on to PostHog (web-errors.js), and POST /v1/web-visit a visit to it (web-visits.js).
 * Logs one line per request
 * (who, model, status, time), never a body or a credential.
 */

export const UPSTREAM = 'https://ai-gateway.vercel.sh/v4/ai';
const ENDPOINTS = new Set(['evaluation-model', 'language-model']);
/**
 * Each endpoint's models, and the variable that moves the list: Jev judges, Luna writes (brain-go env.go ModelIDs). A
 * model is allowed on its own endpoint only: Luna asked on Jev's endpoint would write without Luna's output cap
 * (security review 2026-10-05).
 */
const MODELS = {
  'evaluation-model': { variable: 'MOKU_JUDGE_MODELS', defaults: 'typesafe-ai/jev' },
  'language-model': { variable: 'MOKU_VOICE_MODELS', defaults: 'openai/gpt-6-luna' },
};
const DAY_MS = 86_400_000;
const DEVICE = /^[0-9a-f]{64}$/;
const VERSION = /^[0-9]{1,3}(\.[0-9]{1,3}){0,3}$/;
/**
 * What goes on to the gateway is built here, never passed through: anyone can mint a trial token, and the gateway takes
 * options in headers and in the body (fallback models, provider tools such as web search, streaming) that would spend
 * the key on more than Moku asks, or turn zero data retention off.
 *   - Headers: only these, as the brain sends them (brain-go gateway.go); Luna's answer is never streamed (a stream
 *     can't be read for what it cost, so it would also hide the spend).
 *   - Body: only the fields the brain sends for that endpoint; providerOptions are the relay's own (zero data
 *     retention, and low reasoning effort for OpenAI's models), whatever the caller put there.
 */
const UPSTREAM_HEADERS = {
  'evaluation-model': ['content-type', 'user-agent', 'ai-gateway-protocol-version', 'ai-evaluation-model-specification-version', 'ai-model-id'],
  'language-model': ['content-type', 'user-agent', 'ai-gateway-protocol-version', 'ai-language-model-specification-version', 'ai-language-model-id'],
};
const UPSTREAM_FIELDS = {
  'evaluation-model': ['state', 'questions'],
  'language-model': ['prompt', 'maxOutputTokens', 'responseFormat', 'toolChoice'],
};

/** A body as a JSON object, or null when it isn't one. */
export function jsonObject(/** @type {ArrayBuffer} */ body) {
  try {
    const parsed = JSON.parse(new TextDecoder().decode(body));
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? /** @type {Record<string, any>} */ (parsed) : null;
  } catch {
    return null;
  }
}

/** The headers and body the gateway gets for a caller's request (its body already read: jsonObject). */
export function upstreamRequest(/** @type {string} */ endpoint, /** @type {string} */ model, /** @type {Headers} */ given, /** @type {Record<string, any>} */ parsed) {
  const kind = /** @type {'evaluation-model' | 'language-model'} */ (endpoint);
  const headers = new Headers();
  for (const name of UPSTREAM_HEADERS[kind]) {
    const value = given.get(name);
    if (value !== null) headers.set(name, value);
  }
  /** @type {Record<string, unknown>} */
  const out = {};
  for (const field of UPSTREAM_FIELDS[kind]) if (Object.hasOwn(parsed, field)) out[field] = parsed[field];
  /** @type {Record<string, unknown>} */
  const providerOptions = { gateway: { zeroDataRetention: true } };
  if (kind === 'language-model') {
    headers.set('ai-language-model-streaming', 'false');
    if (model.startsWith('openai/')) providerOptions.openai = { reasoningEffort: 'low' };
    const agent = parsed.headers?.['user-agent'];
    if (typeof agent === 'string' && agent.length <= 200) out.headers = { 'user-agent': agent };
  }
  out.providerOptions = providerOptions;
  headers.set('content-type', 'application/json');
  return { headers, body: new TextEncoder().encode(JSON.stringify(out)) };
}

/**
 * @typedef {{ get(name: string): string | undefined }} Env
 * @typedef {(key: string, limit: number, windowSec: number) => Promise<boolean>} Allow
 * @typedef {{ env: Record<string, string | undefined>, fetch?: typeof fetch, allow?: Allow, log?: (line: string) => void, now?: () => number,
 *   waitUntil?: (promise: Promise<unknown>) => void, attestRoot?: string }} Options `attestRoot`: tests' stand-in for Apple's root.
 */

/** SHA-256 of a token, hex: what goes in MOKU_TESTER_TOKENS. */
export const hashToken = (/** @type {string} */ token) => createHash('sha256').update(token, 'utf8').digest('hex');

/** "alice:ab12…,bob:cd34…" → [{ name, hash }]; malformed entries are skipped. */
export function parseAllowlist(/** @type {string | undefined} */ raw) {
  return (raw ?? '').split(',').map((entry) => entry.trim()).filter(Boolean).flatMap((entry) => {
    const [name, hash] = entry.split(':');
    return name && hash && /^[0-9a-f]{64}$/i.test(hash) ? [{ name, hash: Buffer.from(hash.toLowerCase(), 'hex') }] : [];
  });
}

/** The tester a token belongs to, or null. Compares every entry in constant time. */
export function testerFor(/** @type {string} */ token, /** @type {{ name: string, hash: Buffer }[]} */ allowlist) {
  const hash = Buffer.from(hashToken(token), 'hex');
  let found = null;
  for (const entry of allowlist) if (timingSafeEqual(hash, entry.hash)) found = entry.name;
  return found;
}

/** Fixed-window counters in this instance's memory (best effort: instances don't share it). */
export function memoryLimiter(now = () => Date.now()) {
  /** @type {Map<string, { window: number, windowSec: number, count: number }>} */
  const counters = new Map();
  /** @type {Allow} */
  return async (key, limit, windowSec) => {
    const window = Math.floor(now() / 1000 / windowSec);
    const counter = counters.get(key);
    const count = counter && counter.window === window ? counter.count + 1 : 1;
    counters.set(key, { window, windowSec, count });
    // Only counters whose own window is over go: a minute's sweep once deleted every day's count (new installs,
    // installs per IP, calls per day), so 10,000 cheap requests reset them all.
    if (counters.size > 10_000) {
      for (const [k, c] of counters) if (c.window !== Math.floor(now() / 1000 / c.windowSec)) counters.delete(k);
    }
    return count <= limit;
  };
}

/** Fixed-window counters in Upstash Redis (REST), shared by every instance. Fails open to `fallback`. */
export function redisLimiter(/** @type {string} */ url, /** @type {string} */ token, /** @type {Allow} */ fallback, fetchImpl = fetch, now = () => Date.now()) {
  /** @type {Allow} */
  return async (key, limit, windowSec) => {
    const window = Math.floor(now() / 1000 / windowSec);
    const counterKey = `moku:rate:${key}:${windowSec}:${window}`;
    try {
      const res = await fetchImpl(`${url.replace(/\/$/, '')}/pipeline`, {
        method: 'POST',
        headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
        body: JSON.stringify([['INCR', counterKey], ['EXPIRE', counterKey, String(windowSec * 2)]]), signal: AbortSignal.timeout(REDIS_TIMEOUT_MS),
      });
      if (!res.ok) throw new Error(`redis ${res.status}`);
      const [incr] = /** @type {{ result?: number }[]} */ (await res.json());
      return Number(incr?.result) <= limit;
    } catch {
      return fallback(key, limit, windowSec);
    }
  };
}

const json = (/** @type {number} */ status, /** @type {unknown} */ body, /** @type {Record<string, string>} */ headers = {}) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', ...headers } });

/**
 * What the brain gets when the gateway answers with an error: the same status (the brain decides by it: a pause on 401,
 * 402 or 403, a retry on 408, 429 or 5xx) and a code word, never the gateway's own body, which can name the provider
 * or the gateway account, or quote the request back (security review 2026-10-05). The brain reads nothing else from
 * an error but its message, as a log line, and Retry-After (brain-go gateway.go), which is kept.
 */
export function gatewayError(/** @type {number} */ status) {
  const word = status === 400 ? 'bad_request' : status === 401 || status === 403 ? 'refused' : status === 402 ? 'no_credit'
    : status === 404 ? 'not_found' : status === 408 || status === 504 ? 'timeout' : status === 413 ? 'too_large'
    : status === 429 ? 'rate_limited' : status >= 500 ? 'down' : 'error';
  return { error: `the model gateway answered ${status}`, code: `gateway_${word}` };
}

/**
 * The kind of a gateway error, for the relay's log line: its `type` or `code` when that is a short identifier
 * ("invalid_request_error"), else null. Never its message, which can quote the request: the relay keeps none of it.
 */
export function upstreamErrorKind(/** @type {string} */ text) {
  try {
    const error = JSON.parse(text)?.error;
    const kind = [error?.type, error?.code].find((word) => typeof word === 'string' && /^[A-Za-z0-9_.-]{1,48}$/.test(word));
    return kind ?? null;
  } catch {
    return null;
  }
}

/** The App ID Apple's statements name: the team, a dot, and Moku's signing identifier (on macOS, not the bundle id's role). */
const DEFAULT_APP_ID = 'HTM2272E7P.ai.lightslips.moku';

/** The request handler. `options.env` is process.env on Vercel; the rest is injectable for tests. */
export function createProxy(/** @type {Options} */ options) {
  const { env } = options;
  const fetchImpl = options.fetch ?? fetch;
  const log = options.log ?? ((line) => console.log(line));
  const now = options.now ?? (() => Date.now());
  const allowlist = parseAllowlist(env.MOKU_TESTER_TOKENS);
  const models = Object.fromEntries(Object.entries(MODELS).map(([endpoint, { variable, defaults }]) =>
    [endpoint, new Set((env[variable] || defaults).split(',').map((m) => m.trim()).filter(Boolean))]));
  // The one list for both endpoints before the review's fix: still set, it would no longer do what it says.
  if (env.MOKU_ALLOWED_MODELS) log('moku-proxy MOKU_ALLOWED_MODELS is no longer read: MOKU_JUDGE_MODELS and MOKU_VOICE_MODELS name each endpoint\'s models');
  const redisUrl = env.UPSTASH_REDIS_REST_URL || env.KV_REST_API_URL;
  const redisToken = env.UPSTASH_REDIS_REST_TOKEN || env.KV_REST_API_TOKEN;
  const memory = memoryLimiter(now);
  const allow = options.allow ?? (redisUrl && redisToken ? redisLimiter(redisUrl, redisToken, memory, fetchImpl, now) : memory);
  /**
   * A limit per address or per token, counted in this instance's memory first and in Redis only while this instance's
   * own count is under it: a request already past its limit costs no Redis command. Refused requests used to spend
   * Upstash commands, so about 250K of them used up the month's free 500K, and then every cap fell back to each
   * instance's memory (open-source review 2026-10-14, finding 2). The limit is the same in both, and this instance sees
   * only some of an address's requests, so a real Mac or network meets the count in Redis first, as before.
   * Per-device and global limits stay in Redis alone: they come after one of these, so they can't be flooded.
   */
  const here = memoryLimiter(now);
  /** @type {Allow} */
  const allowHereFirst = async (key, limit, windowSec) => (await here(key, limit, windowSec)) && allow(key, limit, windowSec);
  const redis = (/** @type {number} */ at) => ({ url: redisUrl, token: redisToken, fetch: fetchImpl, now: at });
  const flags = createFlags({ env, fetch: fetchImpl, now, log });
  const invites = inviteNames(env.MOKU_INVITES);
  /** Each invite's Macs in this instance's memory, for when Redis isn't there (access.js inviteTakes). */
  const invitePlaces = new Map();

  /**
   * Who a bearer token belongs to: an install's signed token (even an ended trial: it still gets its flags), or a
   * tester's static token. `subject` is how logs and limits name it; `device` is known for install tokens only.
   */
  function holder(/** @type {Request} */ request) {
    const bearer = /^Bearer\s+(\S+)$/i.exec(request.headers.get('authorization') ?? '')?.[1];
    if (!bearer) return null;
    if (bearer.startsWith('moku1.')) {
      const claims = readToken(bearer, env.MOKU_TOKEN_SECRET);
      return claims && { claims, subject: `${claims.plan}:${claims.sub}`, plan: claims.plan, device: deviceOf(claims) };
    }
    const name = testerFor(bearer, allowlist);
    return name && { claims: null, subject: name, plan: 'tester', device: null };
  }

  /**
   * POST /v1/flags { device, version } with the install's token: the switches the app acts on (forceCalm,
   * minVersion, and whether Jev and Luna are on). The device in the body counts only for a static tester token,
   * which names no device. Nothing is kept; the version only goes in the log line.
   */
  async function flagsFor(/** @type {Request} */ request) {
    const who = holder(request);
    if (!who) return json(401, { error: 'unknown token' });
    if (!(await allowHereFirst(`flags:${who.subject}`, 1000, 86_400))) return json(429, { error: 'too many flag checks' }, { 'retry-after': '3600' });
    const body = /** @type {{ device?: unknown, version?: unknown }} */ (await request.json().catch(() => ({})));
    const sent = typeof body.device === 'string' && DEVICE.test(body.device.toLowerCase()) ? body.device.toLowerCase() : null;
    const device = who.device ?? sent;
    const version = typeof body.version === 'string' && VERSION.test(body.version) ? body.version : '-';
    const answer = appFlags(await flags.forWho({ plan: who.plan, device }));
    log(`moku-proxy flags ${who.plan}/${(device ?? who.subject).slice(0, 12)} ${version}`);
    return json(200, answer, { 'cache-control': 'no-store' });
  }

  /**
   * POST /v1/attest/challenge: what the Mac signs its attestation over, or `{ challenge: null }` while the
   * `attestation` flag is off (the app then skips Apple altogether). Nothing is kept: a challenge is recognised by its MAC.
   */
  async function attestChallenge(/** @type {Request} */ request) {
    if (!env.MOKU_TOKEN_SECRET) return json(503, { error: 'installs not configured' });
    if (!(await allowHereFirst(`attest:${clientAddress(request)}`, 60, 86_400))) return json(429, { error: 'too many challenges' }, { 'retry-after': '3600' });
    if ((await flags.forWho({})).attestation === 'off') return json(200, { challenge: null }, { 'cache-control': 'no-store' });
    return json(200, { challenge: newChallenge(env.MOKU_TOKEN_SECRET, now()) }, { 'cache-control': 'no-store' });
  }

  /**
   * Whether an install's `attestation` { keyId, object, challenge } (base64 each, challenge as given) proves a genuine
   * Moku on a real Mac for this device: `{ ok: true }` or `{ ok: false, reason }` (attest.js lists the reasons; `none`
   * for no attestation, `challenge` for one not ours or too old, `key_reuse` for a key already tied to another Mac).
   */
  async function attestationFor(/** @type {unknown} */ sent, /** @type {string} */ device, /** @type {number} */ at) {
    if (!sent || typeof sent !== 'object') return { ok: false, reason: 'none' };
    const { keyId, object, challenge } = /** @type {Record<string, unknown>} */ (sent);
    if (typeof keyId !== 'string' || typeof object !== 'string' || typeof challenge !== 'string' || keyId.length > 64 || object.length > 30_000 || challenge.length > 200) return { ok: false, reason: 'format' };
    if (!challengeIsFresh(challenge, /** @type {string} */ (env.MOKU_TOKEN_SECRET), at)) return { ok: false, reason: 'challenge' };
    const key = Buffer.from(keyId, 'base64');
    const result = verifyAttestation({
      object: Buffer.from(object, 'base64'), keyId: key, challenge, device, appId: env.MOKU_ATTEST_APP_ID || DEFAULT_APP_ID,
      root: options.attestRoot, now: at, development: env.MOKU_ATTEST_DEVELOPMENT === '1',
    });
    if (!result.ok) return result;
    // A key belongs to one Mac: a statement lifted from one install can't vouch for another (Redis; without it, no check).
    const place = `moku:attest:${key.toString('hex')}`;
    const [, holder] = (await pipeline(redis(at), [['SET', place, device, 'NX'], ['GET', place]])) ?? [];
    if (holder?.result && holder.result !== device) return { ok: false, reason: 'key_reuse' };
    return { ok: true };
  }

  /** POST /v1/install { device, invite?, attestation? }: the device's signed token (a tester with an invite, else a trial). */
  async function install(/** @type {Request} */ request) {
    if (!env.MOKU_TOKEN_SECRET) return json(503, { error: 'installs not configured' });
    const ip = clientAddress(request);
    if (!(await allowHereFirst(`install:${ip}`, Number(env.MOKU_INSTALLS_PER_DAY || 20), 86_400))) return json(429, { error: 'too many installs' }, { 'retry-after': '3600' });
    const body = /** @type {{ device?: unknown, invite?: unknown, attestation?: unknown }} */ (await request.json().catch(() => ({})));
    const device = typeof body.device === 'string' ? body.device.toLowerCase() : '';
    if (!/^[0-9a-f]{64}$/.test(device)) return json(400, { error: 'device must be a 64-character hex hash' });
    const at = now();
    let claims;
    if (typeof body.invite === 'string' && body.invite.trim()) {
      const name = inviteFor(body.invite, env.MOKU_INVITES);
      if (!name) return json(403, { error: 'unknown invite' });
      if (!(await inviteTakes(name, device, Number(env.MOKU_INVITE_MACS) || INVITE_MACS, redis(at), invitePlaces))) {
        log(`moku-proxy install invite-full ${name}`);
        return json(403, { error: 'this invite is already in use on other Macs', code: 'invite_full' });
      }
      claims = /** @type {import('./access.js').Claims} */ ({ sub: `${name}/${device.slice(0, 12)}`, plan: 'tester', exp: 0, iat: at });
    } else {
      // Apple App Attest (the `attestation` flag): checked before anything is counted, so a refused Mac costs nothing.
      const { newInstallsPerDay: cap, attestation: mode } = await flags.forWho({});
      let attested = false;
      if (mode !== 'off') {
        const result = await attestationFor(body.attestation, device, at);
        attested = result.ok;
        log(`moku-proxy attest ${result.ok ? 'verified' : result.reason} ${mode} ${device.slice(0, 12)}`);
        if (!attested && mode === 'require' && !(await seenBefore(device, redis(at)))) {
          return json(403, { error: 'this Mac could not be verified as a Mac running Moku', code: 'attestation_required' });
        }
      }
      // Waves (newInstallsPerDay): a cap on new trials a UTC day. Invites always get in; a Mac seen before isn't new.
      if (cap !== null && !(await seenBefore(device, redis(at))) && !(await allow('new-installs', cap, 86_400))) {
        log(`moku-proxy install full ${device.slice(0, 12)}`);
        return json(429, { error: 'new installs are full for today', code: 'installs_full' }, { 'retry-after': String(Math.ceil((DAY_MS - (at % DAY_MS)) / 1000)) });
      }
      claims = trialClaims(device, await firstSeen(device, redis(at)), at, attested);
    }
    log(`moku-proxy install ${claims.plan} ${claims.sub.slice(0, 24)}`);
    return json(200, { token: signToken(claims, env.MOKU_TOKEN_SECRET), plan: claims.plan, expiresAt: claims.exp || null });
  }

  const payments = createPayments({ env, fetch: fetchImpl, redis, allow: allowHereFirst, log, json, now });

  /**
   * POST /v1/renew with an install's token: a fresh one (a tester's lasts TOKEN_DAYS more; access.js renewal). A Mac
   * that has paid (payments.js) gets a Pro token to its paid end, whatever it had: a trial, an ended trial or Pro.
   */
  async function renew(/** @type {Request} */ request) {
    if (!env.MOKU_TOKEN_SECRET) return json(503, { error: 'installs not configured' });
    const bearer = /^Bearer\s+(moku1\.\S+)$/i.exec(request.headers.get('authorization') ?? '')?.[1];
    const claims = bearer ? readToken(bearer, env.MOKU_TOKEN_SECRET) : null;
    if (!claims) return json(401, { error: 'unknown token' });
    // 24 a day, and more right after a checkout: the app asks every 30 s for a few minutes until the payment lands.
    if (!(await allowHereFirst(`renew:${claims.plan}:${claims.sub}`, 96, 86_400))) return json(429, { error: 'too many renewals' }, { 'retry-after': '3600' });
    const device = claims.plan === 'tester' ? null : deviceOf(claims);
    const paidUntil = await payments.proUntil(device);
    if (device && paidUntil) {
      log(`moku-proxy renew pro ${device.slice(0, 24)}`);
      return json(200, { token: signToken({ sub: device, plan: 'pro', exp: paidUntil, iat: now() }, env.MOKU_TOKEN_SECRET), plan: 'pro', expiresAt: paidUntil });
    }
    const renewed = renewal(claims, now(), invites);
    if (!renewed.ok) return json(renewed.status, { error: renewed.error });
    log(`moku-proxy renew ${renewed.claims.plan} ${renewed.claims.sub.slice(0, 24)}`);
    return json(200, { token: signToken(renewed.claims, env.MOKU_TOKEN_SECRET), plan: renewed.claims.plan, expiresAt: renewed.claims.exp || null });
  }

  const heartbeat = createHeartbeat({ env, fetch: fetchImpl, allow, allowAddress: allowHereFirst, log, json });
  // Who sent a batch of events, from the install's token when it has one (an ended trial still says who it is).
  const whoIs = (/** @type {Request} */ request) => {
    const bearer = /^Bearer\s+(moku1\.\S+)$/i.exec(request.headers.get('authorization') ?? '')?.[1];
    const claims = bearer && env.MOKU_TOKEN_SECRET ? readToken(bearer, env.MOKU_TOKEN_SECRET) : null;
    if (!claims) return null;
    const { plan, friend } = who(`${claims.plan}:${claims.sub}`);
    return { plan, friend };
  };
  const usageEvents = createEvents({ env, fetch: fetchImpl, allow, allowAddress: allowHereFirst, log, json, now, whoIs });
  const usage = createUsage({ env, fetch: fetchImpl, log, waitUntil: options.waitUntil });
  const governor = createGovernor({ env, fetch: fetchImpl, now, log, waitUntil: options.waitUntil });
  const webErrors = createWebErrors({ env, fetch: fetchImpl, allow, allowAddress: allowHereFirst, log, json, now });
  // Visits count in memory only, never Redis (web-visits.js).
  const webVisits = createWebVisits({ env, fetch: fetchImpl, allow: options.allow ?? memory, log, json, now });

  return async (/** @type {Request} */ request) => {
    const started = now();
    const url = new URL(request.url);
    // Through the rewrite (/v4/ai/:path* → /api/proxy?path=:path*) or called directly.
    const endpoint = url.searchParams.get('path') ?? url.pathname.replace(/^\/(api\/proxy|v4\/ai)\/?/, '');
    const secret = env.MOKU_TOKEN_SECRET;
    if (endpoint === 'health' || endpoint === '') return json(200, { ok: true, service: 'moku-proxy', configured: Boolean(env.AI_GATEWAY_API_KEY && (allowlist.length || secret)), installs: Boolean(secret), flags: await flags.health() });
    if (endpoint === 'get' && (request.method === 'GET' || request.method === 'HEAD')) return usageEvents.download(request);
    if (request.method !== 'POST') return json(405, { error: 'POST only' }, { allow: 'POST' });
    if (endpoint === 'v1/events') return usageEvents.events(request);
    if (endpoint === 'v1/attest/challenge') return attestChallenge(request);
    if (endpoint === 'v1/install') return install(request);
    if (endpoint === 'v1/renew') return renew(request);
    if (endpoint === 'v1/checkout') {
      const bearer = /^Bearer\s+(moku1\.\S+)$/i.exec(request.headers.get('authorization') ?? '')?.[1];
      return payments.checkout(request, deviceOf(bearer && secret ? readToken(bearer, secret) : null));
    }
    if (endpoint === 'v1/dodo') return payments.webhook(request);
    if (endpoint === 'v1/flags') return flagsFor(request);
    if (endpoint === 'v1/heartbeat') return heartbeat(request);
    if (endpoint === 'v1/web-error') return webErrors(request);
    if (endpoint === 'v1/web-visit') return webVisits(request);
    if (!ENDPOINTS.has(endpoint)) return json(404, { error: 'not found' });
    if (!env.AI_GATEWAY_API_KEY || (allowlist.length === 0 && !secret)) return json(503, { error: 'proxy not configured' });

    const who = holder(request);
    if (!who) return json(401, { error: 'unknown token' });
    if (who.claims) {
      const admitted = admit(who.claims, now(), invites);  // an ended trial or pro: 402; a revoked invite or a lapsed token: 401
      // An ended trial stays ended until a new token arrives (an invite typed in): a brain that reads Retry-After waits
      // six hours instead of asking every 5 minutes, and a new token ends its wait at once.
      // Pro past its paid end rests the same way (local mode), until a renewal brings a new token.
      if (!admitted.ok && (admitted.error === 'trial ended' || admitted.error === 'pro ended')) return json(402, { error: admitted.error, code: 'trial_ended' }, { 'retry-after': String(6 * 3600) });
      if (!admitted.ok) return json(admitted.status, { error: admitted.error });
    }
    const tester = who.subject;

    const model = request.headers.get(endpoint === 'evaluation-model' ? 'ai-model-id' : 'ai-language-model-id') ?? '';
    if (!models[/** @type {keyof typeof MODELS} */ (endpoint)].has(model)) return json(403, { error: `model not allowed: ${model || '(none)'}` });
    // The kill switch. 503 is what the brain already treats as the cloud resting: it falls back to its rules (or its
    // built-in lines), its breaker stops asking after a few tries, and the popover says Moku is thinking offline.
    const switches = await flags.forWho({ plan: who.plan, device: who.device });
    if (!(endpoint === 'evaluation-model' ? switches.cloudJudging : switches.cloudVoice)) {
      log(`moku-proxy ${tester} ${model} cloud-off`);
      return json(503, { error: 'cloud off', code: 'cloud_off' }, { 'retry-after': '600' });
    }

    // Only what the brain sends, in its own sizes (shape.js), so a minted trial isn't a general model API.
    const declared = Number(request.headers.get('content-length') ?? 0);
    if (declared > MAX_BODY_BYTES) return json(413, { error: 'body too large', code: 'too_large' });
    const raw = await request.arrayBuffer();
    if (raw.byteLength > MAX_BODY_BYTES) return json(413, { error: 'body too large', code: 'too_large' });
    const body = jsonObject(raw);
    if (!body) return json(400, { error: 'body must be a JSON object', code: 'bad_shape' });
    const problem = requestProblem(/** @type {keyof typeof MODELS} */ (endpoint), body, Math.min(MAX_OUTPUT_TOKENS, Number(env.MOKU_MAX_OUTPUT_TOKENS) || MAX_OUTPUT_TOKENS));
    if (problem) {
      log(`moku-proxy ${tester} ${model} ${problem.log}`);
      return json(problem.status, problem.body);
    }
    const forward = upstreamRequest(endpoint, model, request.headers, body);

    // Bursts are stopped in this instance's memory; the day's calls, the budget's share and the day's dollars are the
    // governor's, in Redis (one command a call).
    if (!(await memory(`${tester}:minute`, switches.callsPerMinute, 60))) return json(429, { error: 'rate limited (per minute)' }, { 'retry-after': '60' });
    const turn = await governor.admit({ subject: tester, plan: who.plan, claims: who.claims }, switches);
    if (!turn.ok) return json(turn.status, turn.body, turn.headers);

    const { headers } = forward;
    headers.set('authorization', `Bearer ${env.AI_GATEWAY_API_KEY}`);
    headers.set('ai-gateway-auth-method', 'api-key');
    let upstream;
    try {
      upstream = await fetchImpl(`${UPSTREAM}/${endpoint}`, { method: 'POST', headers, body: forward.body, signal: AbortSignal.timeout(55_000) });  // under the function's 60 s, so the relay answers, not Vercel
    } catch (error) {
      turn.settle(null);
      log(`moku-proxy ${tester} ${model} upstream-error ${now() - started}ms`);
      return json(502, { error: 'gateway unreachable' });
    }
    // The answer is a small JSON object (never streamed), read whole for what it cost; the brain gets it unchanged.
    const text = await upstream.text();
    const spent = readUsage(text), latencyMs = now() - started;
    turn.settle(spent && spent.cost > 0 ? spent.cost : null);  // the governor's dollars: what the gateway says, else costPerCall
    const kind = upstream.ok ? null : upstreamErrorKind(text);
    log(`moku-proxy ${tester} ${model} ${upstream.status} ${latencyMs}ms${spent ? ` in=${spent.input} out=${spent.output} $${spent.cost}` : ''}${kind ? ` upstream=${kind}` : ''}`);
    usage({ tester, model, endpoint, status: upstream.status, latencyMs, spent });
    if (!upstream.ok) {
      /** @type {Record<string, string>} */
      const retry = {};
      for (const name of ['retry-after', 'retry-after-ms']) {
        const value = upstream.headers.get(name);
        if (value !== null && /^[0-9.]{1,12}$/.test(value)) retry[name] = value;
      }
      return json(upstream.status, gatewayError(upstream.status), retry);
    }
    const out = new Headers();
    upstream.headers.forEach((value, name) => { if (!/^(set-cookie|content-encoding|content-length|transfer-encoding|connection)$/i.test(name)) out.set(name, value); });
    return new Response(text, { status: upstream.status, headers: out });
  };
}
