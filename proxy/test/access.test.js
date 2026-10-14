// @ts-check
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { admit, hashInvite, inviteFor, inviteNames, readToken, RENEW_GRACE_DAYS, signToken, TOKEN_DAYS, TRIAL_DAYS } from '../api/_lib/access.js';
import { createProxy } from '../api/_lib/proxy.js';
import { JEV_BODY, LUNA_BODY } from './support/brain-requests.js';

const SECRET = 'test-secret';
const DEVICE = 'a'.repeat(64);
const DAY = 86_400_000;
const ENV = { AI_GATEWAY_API_KEY: 'real-gateway-key', MOKU_TOKEN_SECRET: SECRET, MOKU_INVITES: `friends:${hashInvite('MOKU-7F3K-QX2P')}` };
const install = (body, ip = '1.2.3.4') => new Request('https://relay.example/api/proxy?path=v1/install', { method: 'POST', headers: { 'content-type': 'application/json', 'x-forwarded-for': ip }, body: JSON.stringify(body) });
const jev = (token) => new Request('https://relay.example/api/proxy?path=evaluation-model', { method: 'POST', headers: { authorization: `Bearer ${token}`, 'ai-model-id': 'typesafe-ai/jev' }, body: JEV_BODY });
const upstream = () => { const calls = []; return { calls, fetch: /** @type {typeof fetch} */ (async (url) => { calls.push(String(url)); return new Response('{"answers":{}}', { status: 200 }); }) }; };

/**
 * Upstash's REST pipeline over a Map, as Redis runs it: each command atomic on its own, a pipeline's commands in order
 * but not as one (others' commands can run between them), nothing atomic across requests. Commands run on later turns
 * of the event loop, as over a network, so concurrent requests interleave. Anything that isn't Redis answers 200 {}.
 */
function fakeRedis() {
  /** @type {Map<string, any>} */
  const store = new Map();
  const tick = () => new Promise((resolve) => setImmediate(resolve));
  /** @type {typeof fetch} */
  const fetchImpl = async (url, init) => {
    if (!String(url).includes('redis')) return new Response('{}', { status: 200 });
    const results = [];
    for (const [op, key, value, nx] of JSON.parse(String(init?.body))) {
      await tick();
      const set = store.get(key) instanceof Set ? store.get(key) : new Set();
      if (op === 'GET') results.push({ result: store.get(key) ?? null });
      else if (op === 'SET') { if (nx === 'NX' && store.has(key)) results.push({ result: null }); else { store.set(key, value); results.push({ result: 'OK' }); } }
      else if (op === 'INCR') { const n = Number(store.get(key) ?? 0) + 1; store.set(key, String(n)); results.push({ result: n }); }
      else if (op === 'SISMEMBER') results.push({ result: set.has(value) ? 1 : 0 });
      else if (op === 'SCARD') results.push({ result: set.size });
      else if (op === 'SADD') { results.push({ result: set.has(value) ? 0 : 1 }); set.add(value); store.set(key, set); }
      else results.push({ result: 1 });
    }
    await tick();
    return new Response(JSON.stringify(results), { status: 200 });
  };
  return { store, fetch: fetchImpl };
}
const REDIS_ENV = { UPSTASH_REDIS_REST_URL: 'https://redis.example', UPSTASH_REDIS_REST_TOKEN: 't' };

describe('signed tokens', () => {
  it('round-trips claims, and rejects a token signed with another secret or tampered with', () => {
    const token = signToken({ sub: DEVICE, plan: 'trial', exp: 123, iat: 1 }, SECRET);
    assert.deepEqual(readToken(token, SECRET), { sub: DEVICE, plan: 'trial', exp: 123, iat: 1 });
    assert.equal(readToken(token, 'other'), null);
    const [head, payload, sig] = token.split('.');
    const forged = Buffer.from(JSON.stringify({ sub: DEVICE, plan: 'pro', exp: 0, iat: 1 })).toString('base64url');
    assert.equal(readToken(`${head}.${forged}.${sig}`, SECRET), null);
    assert.equal(readToken('moku_static', SECRET), null);
    assert.equal(readToken(token, undefined), null);
  });

  it('a live trial and a tester pass; an ended trial is 402; nothing is 401', () => {
    assert.deepEqual(admit({ sub: 'd', plan: 'trial', exp: 1000, iat: 0 }, 999), { ok: true, subject: 'trial:d', plan: 'trial' });
    assert.deepEqual(admit({ sub: 'd', plan: 'trial', exp: 1000, iat: 0 }, 1000), { ok: false, status: 402, error: 'trial ended' });
    assert.equal(admit({ sub: 'n', plan: 'tester', exp: 0, iat: 0 }, 5e12).ok, true);
    assert.equal(admit(null, 0).ok, false);
  });

  it('invite codes are case- and dash-insensitive, stored as hashes', () => {
    assert.equal(inviteFor('moku 7f3k qx2p', ENV.MOKU_INVITES), 'friends');
    assert.equal(inviteFor('MOKU-0000-0000', ENV.MOKU_INVITES), null);
  });
});

describe('POST /v1/install', () => {
  it('gives a device a 21-day trial token that Jev accepts, and a tester token for an invite', async () => {
    const up = upstream(); let now = 10 * DAY;
    const relay = createProxy({ env: ENV, fetch: up.fetch, log: () => {}, now: () => now });
    const trial = await (await relay(install({ device: DEVICE }))).json();
    assert.equal(trial.plan, 'trial');
    assert.equal(trial.expiresAt, 10 * DAY + TRIAL_DAYS * DAY);
    assert.equal((await relay(jev(trial.token))).status, 200);
    const tester = await (await relay(install({ device: DEVICE, invite: 'moku-7f3k-qx2p' }))).json();
    assert.deepEqual([tester.plan, tester.expiresAt], ['tester', null]);
    now += (TRIAL_DAYS + 1) * DAY;
    const ended = await relay(jev(trial.token));
    assert.equal(ended.status, 402);
    assert.deepEqual(await ended.json(), { error: 'trial ended', code: 'trial_ended' });
    assert.equal((await relay(jev(tester.token))).status, 200);
    assert.equal(up.calls.length, 2); // the ended trial never reached Jev
  });

  it('refuses a bad device id, an unknown invite, and too many installs from one address', async () => {
    const relay = createProxy({ env: { ...ENV, MOKU_INSTALLS_PER_DAY: '2' }, fetch: upstream().fetch, log: () => {} });
    assert.equal((await relay(install({ device: 'not-a-hash' }))).status, 400);
    assert.equal((await relay(install({ device: DEVICE, invite: 'NOPE-NOPE' }))).status, 403);
    assert.equal((await relay(install({ device: DEVICE }, '9.9.9.9'))).status, 200);
    assert.equal((await relay(install({ device: DEVICE }, '9.9.9.9'))).status, 200);
    assert.equal((await relay(install({ device: DEVICE }, '9.9.9.9'))).status, 429);
  });

  it('keeps the first day a device was seen (Redis), so reinstalling doesn\'t restart the trial', async () => {
    const store = new Map(); let now = 1 * DAY;
    /** @type {typeof fetch} */
    const redis = async (url, init) => {
      if (!String(url).includes('redis')) return new Response('{}', { status: 200 });
      const commands = JSON.parse(String(init?.body));
      const results = commands.map(([op, key, value, nx]) => {
        if (op === 'SET') { if (nx === 'NX' && store.has(key)) return { result: null }; store.set(key, value); return { result: 'OK' }; }
        if (op === 'GET') return { result: store.get(key) ?? null };
        if (op === 'INCR') { const n = Number(store.get(key) ?? 0) + 1; store.set(key, String(n)); return { result: n }; }
        return { result: 1 };
      });
      return new Response(JSON.stringify(results), { status: 200 });
    };
    const relay = createProxy({ env: { ...ENV, UPSTASH_REDIS_REST_URL: 'https://redis.example', UPSTASH_REDIS_REST_TOKEN: 't' }, fetch: redis, log: () => {}, now: () => now });
    const first = await (await relay(install({ device: DEVICE }))).json();
    now += 5 * DAY;
    const again = await (await relay(install({ device: DEVICE }))).json();
    assert.equal(again.expiresAt, first.expiresAt);
  });

  it('an invite works on two Macs at most (Redis), and a Mac it already has can reinstall', async () => {
    const relay = createProxy({ env: { ...ENV, ...REDIS_ENV }, fetch: fakeRedis().fetch, log: () => {} });
    const code = 'moku-7f3k-qx2p';
    assert.equal((await relay(install({ device: 'a'.repeat(64), invite: code }))).status, 200);
    assert.equal((await relay(install({ device: 'b'.repeat(64), invite: code }))).status, 200);
    const third = await relay(install({ device: 'c'.repeat(64), invite: code }));
    assert.equal(third.status, 403);
    assert.equal((await third.json()).code, 'invite_full');
    assert.equal((await relay(install({ device: 'a'.repeat(64), invite: code }))).status, 200);
  });

  // Security review low (2026-10-05): the check (SISMEMBER, SCARD) and the add (SADD) were two requests, so redemptions
  // at the same moment all passed the check before any added itself.
  it('redemptions of one invite at the same moment still give it two Macs at most (Redis, every instance)', async () => {
    const code = 'moku-7f3k-qx2p';
    const macs = ['a', 'b', 'c', 'd', 'e'].map((c) => c.repeat(64));
    // Two relay instances on one Redis, as on Vercel.
    const redis = fakeRedis();
    const one = createProxy({ env: { ...ENV, ...REDIS_ENV }, fetch: redis.fetch, log: () => {} });
    const two = createProxy({ env: { ...ENV, ...REDIS_ENV }, fetch: redis.fetch, log: () => {} });
    const answers = await Promise.all(macs.map((device, i) => (i % 2 ? two : one)(install({ device, invite: code }, `10.0.0.${i}`))));
    const statuses = answers.map((res) => res.status);
    assert.equal(statuses.filter((s) => s === 200).length, 2, `statuses ${statuses}`);
    assert.equal(statuses.filter((s) => s === 403).length, 3, `statuses ${statuses}`);
    // The two that got in can reinstall; nobody else can, even now that it's quiet.
    const inside = macs.filter((_, i) => statuses[i] === 200);
    for (const device of inside) assert.equal((await one(install({ device, invite: code }))).status, 200);
    for (const device of macs.filter((d) => !inside.includes(d))) assert.equal((await two(install({ device, invite: code }))).status, 403);
  });

  it('Macs an invite took before this change (the Redis set moku:invite:<name>) keep their places', async () => {
    const code = 'moku-7f3k-qx2p';
    const redis = fakeRedis();
    redis.store.set('moku:invite:friends', new Set(['a'.repeat(64)]));
    const relay = createProxy({ env: { ...ENV, ...REDIS_ENV }, fetch: redis.fetch, log: () => {} });
    assert.equal((await relay(install({ device: 'a'.repeat(64), invite: code }))).status, 200);
    const statuses = (await Promise.all(['b', 'c', 'd'].map((c, i) => relay(install({ device: c.repeat(64), invite: code }, `10.0.2.${i}`))))).map((res) => res.status);
    assert.deepEqual(statuses.toSorted(), [200, 403, 403]);
    assert.equal((await relay(install({ device: 'a'.repeat(64), invite: code }))).status, 200);
  });

  it('one Mac redeeming twice at the same moment takes one place, not two (Redis)', async () => {
    const code = 'moku-7f3k-qx2p';
    const relay = createProxy({ env: { ...ENV, ...REDIS_ENV }, fetch: fakeRedis().fetch, log: () => {} });
    const twice = await Promise.all([relay(install({ device: 'a'.repeat(64), invite: code })), relay(install({ device: 'a'.repeat(64), invite: code }))]);
    assert.deepEqual(twice.map((res) => res.status), [200, 200]);
    assert.equal((await relay(install({ device: 'b'.repeat(64), invite: code }))).status, 200);
    assert.equal((await relay(install({ device: 'c'.repeat(64), invite: code }))).status, 403);
  });

  it('without Redis, or while it fails, an instance still holds an invite to two Macs, at the same moment too (its own memory only)', async () => {
    const code = 'moku-7f3k-qx2p';
    const relay = createProxy({ env: ENV, fetch: upstream().fetch, log: () => {} });
    const macs = ['a', 'b', 'c', 'd'].map((c) => c.repeat(64));
    const statuses = (await Promise.all(macs.map((device, i) => relay(install({ device, invite: code }, `10.0.1.${i}`))))).map((res) => res.status);
    assert.deepEqual(statuses.toSorted(), [200, 200, 403, 403]);
    assert.equal((await relay(install({ device: macs[statuses.indexOf(200)], invite: code }))).status, 200);
    // Redis configured but failing: the same (it used to let every Mac in).
    /** @type {typeof fetch} */
    const failing = async (url) => new Response(String(url).includes('redis') ? 'down' : '{}', { status: String(url).includes('redis') ? 500 : 200 });
    const down = createProxy({ env: { ...ENV, ...REDIS_ENV }, fetch: failing, log: () => {} });
    const whileDown = (await Promise.all(macs.map((device, i) => down(install({ device, invite: code }, `10.0.3.${i}`))))).map((res) => res.status);
    assert.deepEqual(whileDown.toSorted(), [200, 200, 403, 403]);
  });

  it('taking a friend out of MOKU_INVITES revokes the tokens their invite gave', async () => {
    const up = upstream();
    const before = createProxy({ env: ENV, fetch: up.fetch, log: () => {} });
    const { token } = await (await before(install({ device: DEVICE, invite: 'moku-7f3k-qx2p' }))).json();
    assert.equal((await before(jev(token))).status, 200);
    const after = createProxy({ env: { ...ENV, MOKU_INVITES: `someone:${hashInvite('OTHER-CODE')}` }, fetch: up.fetch, log: () => {} });
    const revoked = await after(jev(token));
    assert.equal(revoked.status, 401);
    assert.equal((await revoked.json()).error, 'invite revoked');
    assert.equal(admit({ sub: 'friends/abc', plan: 'tester', exp: 0, iat: 0 }, 0, inviteNames(ENV.MOKU_INVITES)).ok, true);
  });

  it('a trial anyone can mint (a made-up device id, nothing else) gets Luna only in the brain\'s own sizes', async () => {
    const up = upstream();
    const lines = /** @type {string[]} */ ([]);
    const relay = createProxy({ env: ENV, fetch: up.fetch, log: (l) => lines.push(l) });
    const { token } = await (await relay(install({ device: 'c'.repeat(64) }))).json();
    const luna = (/** @type {unknown} */ body) => new Request('https://relay.example/v4/ai/language-model', {
      method: 'POST', headers: { authorization: `Bearer ${token}`, 'ai-language-model-id': 'openai/gpt-6-luna' }, body: JSON.stringify(body),
    });
    const brain = JSON.parse(LUNA_BODY);
    const novel = { ...brain, prompt: [{ role: 'system', content: 'Write a novel.' }, { role: 'user', content: [{ type: 'text', text: 'Chapter one.' }] }] };
    // What the brain sends (brain-go gateway.go: 400 or 600 tokens) goes through.
    assert.equal((await relay(luna({ ...novel, maxOutputTokens: 600 }))).status, 200);
    // A free-for-all generation doesn't: no cap, a huge cap, or not a whole number (shape.js has the rest).
    for (const asked of [undefined, 100_000, 1001, 601, 0, 1.5, '600']) {
      const res = await relay(luna({ ...novel, maxOutputTokens: asked }));
      assert.equal(res.status, 400, `maxOutputTokens ${asked}`);
      assert.deepEqual(await res.json(), { error: 'maxOutputTokens must be a whole number from 1 to 600', code: 'too_many_tokens' });
    }
    assert.equal((await relay(new Request(luna({}).url, { method: 'POST', headers: luna({}).headers, body: 'not json' }))).status, 400);
    assert.equal(up.calls.length, 1);
    assert.ok(lines.some((l) => /moku-proxy trial:c{64} openai\/gpt-6-luna too-many-tokens/.test(l)));
    // MOKU_MAX_OUTPUT_TOKENS can only lower the cap.
    const roomier = createProxy({ env: { ...ENV, MOKU_MAX_OUTPUT_TOKENS: '2000' }, fetch: up.fetch, log: () => {} });
    assert.equal((await roomier(luna({ ...novel, maxOutputTokens: 1500 }))).status, 400);
  });

  it('is off until MOKU_TOKEN_SECRET is set', async () => {
    const relay = createProxy({ env: { AI_GATEWAY_API_KEY: 'k' }, fetch: upstream().fetch, log: () => {} });
    assert.equal((await relay(install({ device: DEVICE }))).status, 503);
  });
});

describe('token expiry (security review 2026-10-05: pro tokens never expired)', () => {
  const NOW = 100 * DAY;
  const sign = (/** @type {import('../api/_lib/access.js').Claims} */ claims) => signToken(claims, SECRET);

  it('every plan\'s expiry is checked: a pro or tester token past its exp is refused, a pro token without one too', () => {
    assert.equal(admit({ sub: DEVICE, plan: 'pro', exp: NOW + DAY, iat: 0 }, NOW).ok, true);
    assert.deepEqual(admit({ sub: DEVICE, plan: 'pro', exp: NOW - 1, iat: 0 }, NOW), { ok: false, status: 402, error: 'pro ended' });
    // No pro token has ever been minted (only /v1/install mints, and only trials and testers), so none in the field lacks one.
    assert.deepEqual(admit({ sub: DEVICE, plan: 'pro', exp: 0, iat: 0 }, NOW), { ok: false, status: 401, error: 'token has no expiry' });
    assert.deepEqual(admit({ sub: 'friends/abc', plan: 'tester', exp: NOW - 1, iat: 0 }, NOW, inviteNames(ENV.MOKU_INVITES)), { ok: false, status: 401, error: 'token expired' });
    assert.equal(admit({ sub: 'friends/abc', plan: 'tester', exp: NOW + 1, iat: 0 }, NOW, inviteNames(ENV.MOKU_INVITES)).ok, true);
  });

  it('every token shipped builds (0.1.4–0.1.9) hold keeps working: a tester\'s without an expiry, a live trial', async () => {
    const relay = createProxy({ env: ENV, fetch: upstream().fetch, log: () => {}, now: () => NOW });
    assert.equal((await relay(jev(sign({ sub: `friends/${DEVICE.slice(0, 12)}`, plan: 'tester', exp: 0, iat: 1 })))).status, 200);
    assert.equal((await relay(jev(sign({ sub: DEVICE, plan: 'trial', exp: NOW + DAY, iat: 1 })))).status, 200);
    // And the static tokens in MOKU_TESTER_TOKENS are untouched (proxy.test.js).
  });

  it('a pro token past its expiry never reaches Jev', async () => {
    const up = upstream();
    const relay = createProxy({ env: ENV, fetch: up.fetch, log: () => {}, now: () => NOW });
    const ended = await relay(jev(sign({ sub: DEVICE, plan: 'pro', exp: NOW - DAY, iat: 1 })));
    assert.equal(ended.status, 402);
    assert.equal((await relay(jev(sign({ sub: DEVICE, plan: 'pro', exp: 0, iat: 1 })))).status, 401);
    assert.equal(up.calls.length, 0);
  });

  describe('POST /v1/renew: the renewal path', () => {
    const renew = (/** @type {string | null} */ token) => new Request('https://relay.example/api/proxy?path=v1/renew', {
      method: 'POST', headers: token ? { authorization: `Bearer ${token}`, 'x-forwarded-for': '1.2.3.4' } : {},
    });
    const tester = (/** @type {number} */ exp) => sign({ sub: `friends/${DEVICE.slice(0, 12)}`, plan: 'tester', exp, iat: 1 });

    it('gives a tester\'s token without an expiry (every one in the field) a new one with an expiry, which Jev accepts', async () => {
      let now = NOW;
      const relay = createProxy({ env: ENV, fetch: upstream().fetch, log: () => {}, now: () => now });
      const res = await relay(renew(tester(0)));
      assert.equal(res.status, 200);
      const renewed = await res.json();
      assert.deepEqual([renewed.plan, renewed.expiresAt], ['tester', NOW + TOKEN_DAYS * DAY]);
      assert.deepEqual(readToken(renewed.token, SECRET), { sub: `friends/${DEVICE.slice(0, 12)}`, plan: 'tester', exp: NOW + TOKEN_DAYS * DAY, iat: NOW });
      assert.equal((await relay(jev(renewed.token))).status, 200);
      // Renewed again before it ends, it moves on; left to lapse, Jev refuses it.
      now += 20 * DAY;
      assert.equal((await (await relay(renew(renewed.token))).json()).expiresAt, now + TOKEN_DAYS * DAY);
      now += TOKEN_DAYS * DAY;
      assert.equal((await relay(jev(renewed.token))).status, 401);
    });

    it('renews a lapsed tester token within the grace, not after it, and never one whose invite was taken out', async () => {
      const relay = createProxy({ env: ENV, fetch: upstream().fetch, log: () => {}, now: () => NOW });
      assert.equal((await relay(renew(tester(NOW - RENEW_GRACE_DAYS * DAY + 1)))).status, 200);
      const late = await relay(renew(tester(NOW - RENEW_GRACE_DAYS * DAY - 1)));
      assert.deepEqual([late.status, await late.json()], [401, { error: 'token expired' }]);
      const revoked = createProxy({ env: { ...ENV, MOKU_INVITES: `someone:${hashInvite('OTHER-CODE')}` }, fetch: upstream().fetch, log: () => {}, now: () => NOW });
      assert.deepEqual(await (await revoked(renew(tester(0)))).json(), { error: 'invite revoked' });
    });

    it('never moves a trial\'s or a pro token\'s end: those come from the first day seen and from payment', async () => {
      const relay = createProxy({ env: ENV, fetch: upstream().fetch, log: () => {}, now: () => NOW });
      const trial = await (await relay(renew(sign({ sub: DEVICE, plan: 'trial', exp: NOW + 3 * DAY, iat: 1 })))).json();
      assert.deepEqual([trial.plan, trial.expiresAt], ['trial', NOW + 3 * DAY]);
      assert.equal((await relay(renew(sign({ sub: DEVICE, plan: 'trial', exp: NOW - 1, iat: 1 })))).status, 402);
      const pro = await (await relay(renew(sign({ sub: DEVICE, plan: 'pro', exp: NOW + 3 * DAY, iat: 1 })))).json();
      assert.deepEqual([pro.plan, pro.expiresAt], ['pro', NOW + 3 * DAY]);
      assert.equal((await relay(renew(sign({ sub: DEVICE, plan: 'pro', exp: NOW - 1, iat: 1 })))).status, 402);
    });

    it('refuses no token, a forged one and a static tester token (those live in MOKU_TESTER_TOKENS), and too many renewals', async () => {
      const relay = createProxy({ env: ENV, fetch: upstream().fetch, log: () => {}, now: () => NOW });
      assert.equal((await relay(renew(null))).status, 401);
      assert.equal((await relay(renew(signToken({ sub: DEVICE, plan: 'tester', exp: 0, iat: 1 }, 'other-secret')))).status, 401);
      assert.equal((await relay(renew('moku_static-token'))).status, 401);
      const token = tester(0);
      for (let i = 0; i < 96; i++) assert.equal((await relay(renew(token))).status, 200);
      assert.equal((await relay(renew(token))).status, 429);
    });
  });
});
