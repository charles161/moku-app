// @ts-check
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { signToken, trialClaims } from '../api/_lib/access.js';
import { createProxy, hashToken } from '../api/_lib/proxy.js';
import { JEV_BODY, LUNA_BODY } from './support/brain-requests.js';

// Open-source review 2026-10-14, finding 2: routes that need no token spent Upstash commands before any check, refused
// requests included, so about 250K requests used up the free 500K a month. Then every cap fell back to each instance's
// memory: the governor's pool restarted in every instance, an invite worked on any number of Macs.

const SECRET = 'test-secret';
const REDIS = 'https://redis.example';
const NOW = Date.UTC(2026, 9, 14, 10);
const DAY = 86_400_000;
const DEVICE = 'c'.repeat(64);
const BROWSER = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15';

/** An in-memory Upstash that counts commands; `failing` makes it answer 500, as a used-up or broken Redis does. */
function fakeRedis() {
  const data = new Map();
  const state = { commands: 0, failing: false, fetches: 0, signals: 0, failOn: '' };
  /** @param {string[]} c */
  const run = ([op, key, ...rest]) => {
    state.commands++;
    switch (op) {
      case 'INCR': case 'INCRBY': { const n = Number(data.get(key) ?? 0) + Number(rest[0] ?? 1); data.set(key, String(n)); return n; }
      case 'INCRBYFLOAT': { const n = Number(data.get(key) ?? 0) + Number(rest[0]); data.set(key, String(n)); return String(n); }
      case 'HINCRBY': { const h = data.get(key) ?? new Map(); data.set(key, h); const n = Number(h.get(rest[0]) ?? 0) + Number(rest[1]); h.set(rest[0], n); return n; }
      case 'HLEN': return data.get(key)?.size ?? 0;
      case 'EXPIRE': return data.has(key) ? 1 : 0;
      case 'GET': return data.get(key) ?? null;
      case 'DEL': return data.delete(key) ? 1 : 0;
      case 'SET': if (rest.includes('NX') && data.has(key)) return null; data.set(key, rest[0]); return 'OK';
      case 'SISMEMBER': return 0;
      case 'SCARD': return 0;
      default: throw new Error(`fake redis: ${op}`);
    }
  };
  /** @type {typeof fetch} */
  const fetchImpl = async (input, init) => {
    const url = String(input);
    if (url.startsWith(REDIS)) {
      state.fetches++;
      if (init?.signal instanceof AbortSignal) state.signals++;
      const commands = JSON.parse(String(init?.body));
      if (state.failing || commands.some((/** @type {string[]} */ c) => c[0] === state.failOn)) { state.commands += commands.length; return new Response('{"error":"ERR max requests limit exceeded"}', { status: 400 }); }
      return new Response(JSON.stringify(commands.map((/** @type {string[]} */ c) => ({ result: run(c) }))));
    }
    if (url.includes('posthog')) return new Response('{"status":"Ok"}');
    return new Response(JSON.stringify({ answers: {}, usage: { inputTokens: 900, outputTokens: 30 }, providerMetadata: { gateway: { cost: '0.00004' } } }));
  };
  return { state, fetchImpl, get commands() { return state.commands; } };
}

const ENV = {
  AI_GATEWAY_API_KEY: 'k', MOKU_TOKEN_SECRET: SECRET, POSTHOG_KEY: 'phc_test', MOKU_TESTER_TOKENS: `dave:${hashToken('moku_dave')}`,
  MOKU_INVITES: `friends:${'0'.repeat(64)}`, UPSTASH_REDIS_REST_URL: REDIS, UPSTASH_REDIS_REST_TOKEN: 't',
};

function relay(/** @type {Record<string, string | undefined>} */ env = {}) {
  const redis = fakeRedis();
  /** @type {string[]} */
  const lines = [];
  const handle = createProxy({ env: { ...ENV, ...env }, fetch: redis.fetchImpl, log: (l) => lines.push(l), now: () => NOW, waitUntil: () => {} });
  return { redis, lines, handle };
}

const post = (/** @type {string} */ path, /** @type {unknown} */ body, /** @type {Record<string, string>} */ headers = {}) => new Request(`https://relay.example/api/proxy?path=${path}`, {
  method: 'POST', body: JSON.stringify(body), headers: { 'content-type': 'application/json', 'x-forwarded-for': '198.51.100.7', ...headers },
});

describe('an address past its limit costs no Redis command', () => {
  // Each route that reaches Redis without a token, with its per-address limit (set low here to keep the test quick).
  const routes = /** @type {[string, () => Request, number, Record<string, string>][]} */ ([
    ['GET /get (counting a download)', () => new Request('https://relay.example/api/proxy?path=get', { headers: { 'user-agent': BROWSER, 'x-forwarded-for': '198.51.100.7' } }), 20, {}],
    ['POST /v1/events', () => post('v1/events', { device: DEVICE, events: [{ name: 'day_opened' }] }), 5, { MOKU_EVENT_BATCHES_PER_IP: '5' }],
    ['POST /v1/heartbeat', () => post('v1/heartbeat', { device: DEVICE, day: '2026-10-13', counts: { screens: 1 } }), 5, { MOKU_HEARTBEATS_PER_IP: '5' }],
    ['POST /v1/web-error', () => post('v1/web-error', { kind: 'error', type: 'TypeError', message: 'x is null', page: '/' }, { origin: 'https://hellomoku.com', 'user-agent': BROWSER }), 20, {}],
    ['POST /v1/attest/challenge', () => post('v1/attest/challenge', {}), 60, {}],
    ['POST /v1/install', () => post('v1/install', { device: DEVICE }), 5, { MOKU_INSTALLS_PER_DAY: '5' }],
  ]);
  for (const [name, request, limit, env] of routes) {
    it(name, async () => {
      const r = relay(env);
      for (let i = 0; i < limit; i++) assert.ok((await r.handle(request())).status < 400, `request ${i + 1} of ${limit}`);
      const before = r.redis.commands;
      for (let i = 0; i < 50; i++) {
        const res = await r.handle(request());
        assert.ok(res.status === 429 || name.startsWith('GET /get'), `${name} answered ${res.status}`);
      }
      assert.equal(r.redis.commands, before, `${name}: 50 refused requests cost ${r.redis.commands - before} Redis commands`);
      // Another address is counted on its own.
      const other = new Request(request(), { headers: { ...Object.fromEntries(request().headers), 'x-forwarded-for': '203.0.113.50' } });
      assert.ok((await r.handle(other)).status < 400);
    });
  }

  it('a token past its limit too: flag checks and renewals', async () => {
    const r = relay();
    const token = signToken(trialClaims(DEVICE, NOW, NOW), SECRET);
    const auth = { authorization: `Bearer ${token}` };
    for (let i = 0; i < 1000; i++) assert.equal((await r.handle(post('v1/flags', { version: '0.1.13' }, auth))).status, 200);
    for (let i = 0; i < 96; i++) assert.equal((await r.handle(post('v1/renew', {}, auth))).status, 200);
    const before = r.redis.commands;
    for (let i = 0; i < 20; i++) {
      assert.equal((await r.handle(post('v1/flags', { version: '0.1.13' }, auth))).status, 429);
      assert.equal((await r.handle(post('v1/renew', {}, auth))).status, 429);
    }
    assert.equal(r.redis.commands, before);
  });

  it('every call to Redis has a time limit, so a Redis that hangs can\'t hold the relay', async () => {
    const r = relay();
    await r.handle(post('v1/install', { device: DEVICE }));
    await r.handle(new Request('https://relay.example/v4/ai/evaluation-model', {
      method: 'POST', body: JEV_BODY, headers: { authorization: `Bearer ${signToken(trialClaims(DEVICE, NOW, NOW), SECRET)}`, 'ai-model-id': 'typesafe-ai/jev' },
    }));
    assert.ok(r.redis.state.fetches >= 4, `${r.redis.state.fetches} requests to Redis`);
    assert.equal(r.redis.state.signals, r.redis.state.fetches);
  });
});

describe('Redis configured but failing', () => {
  const call = (/** @type {string} */ token, endpoint = 'evaluation-model') => new Request(`https://relay.example/v4/ai/${endpoint}`, {
    method: 'POST', body: endpoint === 'evaluation-model' ? JEV_BODY : LUNA_BODY,
    headers: { authorization: `Bearer ${token}`, ...(endpoint === 'evaluation-model' ? { 'ai-model-id': 'typesafe-ai/jev' } : { 'ai-language-model-id': 'openai/gpt-6-luna' }) },
  });
  const trial = signToken(trialClaims(DEVICE, NOW - 5 * DAY, NOW), SECRET);
  const tester = signToken({ sub: 'friends/0a1b2c3d4e5f', plan: 'tester', exp: 0, iat: NOW }, SECRET);
  const pro = signToken({ sub: 'd'.repeat(64), plan: 'pro', exp: NOW + 30 * DAY, iat: NOW }, SECRET);

  it('trial calls get 503 cloud_off (the brain judges by its rules) instead of each instance\'s own pool', async () => {
    const r = relay();
    assert.equal((await r.handle(call(trial))).status, 200);
    r.redis.state.failing = true;
    for (const endpoint of ['evaluation-model', 'language-model']) {
      const res = await r.handle(call(trial, endpoint));
      assert.equal(res.status, 503, endpoint);
      assert.deepEqual(await res.json(), { error: 'cloud off', code: 'cloud_off' });
      assert.ok(Number(res.headers.get('retry-after')) >= 60);
    }
    assert.ok(r.lines.some((l) => /^moku-proxy trial:c{12}.* governor redis-down$/.test(l)), r.lines.join('\n'));
    // Testers, static tokens and pro aren't governed: they keep working on this instance's counts.
    for (const token of [tester, 'moku_dave', pro]) assert.equal((await r.handle(call(token))).status, 200);
    // Redis back: trials go through again.
    r.redis.state.failing = false;
    assert.equal((await r.handle(call(trial))).status, 200);
  });

  it('a failing read of the day\'s counts rests trial calls too', async () => {
    const r = relay();
    r.redis.state.failOn = 'HLEN';
    const res = await r.handle(call(trial));
    assert.deepEqual([res.status, (await res.json()).code], [503, 'cloud_off']);
    r.redis.state.failOn = '';
    assert.equal((await r.handle(call(trial))).status, 200);
  });

  it('without Redis configured (a local run), trials keep this instance\'s counts as before', async () => {
    const r = relay({ UPSTASH_REDIS_REST_URL: undefined, UPSTASH_REDIS_REST_TOKEN: undefined });
    assert.equal((await r.handle(call(trial))).status, 200);
    assert.equal(r.redis.commands, 0);
  });
});
