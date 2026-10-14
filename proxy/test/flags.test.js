// @ts-check
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { signToken } from '../api/_lib/access.js';
import { createFlags, DEFAULTS, globalConfigReader, parseFlags, resolveFlags, sameDevice } from '../api/_lib/flags.js';
import { createProxy, hashToken } from '../api/_lib/proxy.js';
import { JEV_BODY, LUNA_BODY } from './support/brain-requests.js';

const SECRET = 'test-secret';
const NOW = Date.UTC(2026, 9, 4, 9, 0, 0);
const DAY = 86_400_000;
const ALICE = 'a1'.repeat(32); // a trial Mac
const BOB = 'b2'.repeat(32); // another trial Mac
const CAROL = 'c3'.repeat(32); // a friend with an invite
const trial = (device = ALICE, exp = NOW + 21 * DAY) => signToken({ sub: device, plan: 'trial', exp, iat: NOW }, SECRET);
const tester = (device = CAROL) => signToken({ sub: `friends/${device.slice(0, 12)}`, plan: 'tester', exp: 0, iat: NOW }, SECRET);
const STATIC = 'moku_dave-token';
// The testers' invite: their tokens stay valid only while its name is in MOKU_INVITES.
const ENV = { AI_GATEWAY_API_KEY: 'real-gateway-key', MOKU_TOKEN_SECRET: SECRET, MOKU_TESTER_TOKENS: `dave:${hashToken(STATIC)}`, MOKU_INVITES: `friends:${'0'.repeat(64)}` };

const flagsCall = (/** @type {string | null} */ token, body = { device: ALICE, version: '0.1.8' }) => new Request('https://relay.example/api/proxy?path=v1/flags', {
  method: 'POST', headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body),
});
const modelCall = (/** @type {string} */ token, endpoint = 'evaluation-model') => new Request(`https://relay.example/api/proxy?path=${endpoint}`, {
  method: 'POST', body: endpoint === 'evaluation-model' ? JEV_BODY : LUNA_BODY,
  headers: { authorization: `Bearer ${token}`, ...(endpoint === 'evaluation-model' ? { 'ai-model-id': 'typesafe-ai/jev' } : { 'ai-language-model-id': 'openai/gpt-6-luna' }) },
});
const install = (/** @type {object} */ body) => new Request('https://relay.example/api/proxy?path=v1/install', {
  method: 'POST', headers: { 'content-type': 'application/json', 'x-forwarded-for': '1.2.3.4' }, body: JSON.stringify(body),
});
/** A gateway that answers every call, and counts them. */
function gateway() {
  const calls = /** @type {string[]} */ ([]);
  /** @type {typeof fetch} */
  const fetchImpl = async (url) => { calls.push(String(url)); return new Response('{"answers":{}}', { status: 200 }); };
  return { calls, fetch: fetchImpl };
}
const relay = (/** @type {Record<string, string>} */ env = {}, over = {}) => {
  const lines = /** @type {string[]} */ ([]);
  const { calls, fetch } = gateway();
  const handle = createProxy({ env: { ...ENV, ...env }, fetch, log: (l) => lines.push(l), now: () => NOW, ...over });
  return { handle, lines, calls };
};
const flagsOf = async (/** @type {ReturnType<typeof relay>} */ r, /** @type {string | null} */ token, body = undefined) => {
  const res = await r.handle(flagsCall(token, body));
  return { status: res.status, body: await res.json() };
};

describe('parsing MOKU_FLAGS', () => {
  it('reads everyone, plans and devices, and drops each bad entry with a reason, keeping the rest', () => {
    const doc = parseFlags(JSON.stringify({
      everyone: { cloudJudging: false, forceCalm: 'yes', speed: 3, newInstallsPerDay: 50 },
      plans: { trial: { callsPerDay: 2000, newInstallsPerDay: 1 }, free: { forceCalm: true } },
      devices: { 'A1B2C3D4E5F6': { forceCalm: true }, xyz: { forceCalm: true } },
      people: {},
    }), 'MOKU_FLAGS');
    assert.deepEqual(doc.everyone, { cloudJudging: false, newInstallsPerDay: 50 });
    assert.deepEqual(doc.plans, { trial: { callsPerDay: 2000 } });
    assert.deepEqual(doc.devices, { 'a1b2c3d4e5f6': { forceCalm: true } });
    assert.deepEqual(doc.problems, [
      'MOKU_FLAGS.everyone.forceCalm: expected true or false',
      'MOKU_FLAGS.everyone.speed: not a flag (cloudJudging, cloudVoice, forceCalm, minVersion, callsPerMinute, callsPerDay, newInstallsPerDay, dailyBudgetUsd, costPerCall, attestation)',
      'MOKU_FLAGS.plans.trial.newInstallsPerDay: only for everyone',
      'MOKU_FLAGS.plans.free: not a plan (tester, trial, pro)',
      'MOKU_FLAGS.devices.xyz: a device id is 12 to 64 hex characters',
      'MOKU_FLAGS.people: not a scope (everyone, plans, devices)',
    ]);
  });

  it('nothing set is no overrides; a value that isn\'t JSON is one problem and no overrides', () => {
    assert.deepEqual(parseFlags(undefined, 'MOKU_FLAGS'), { everyone: {}, plans: {}, devices: {}, problems: [] });
    assert.deepEqual(parseFlags('{"everyone":', 'MOKU_FLAGS').problems, ['MOKU_FLAGS: not JSON']);
    assert.deepEqual(parseFlags('[1]', 'MOKU_FLAGS').problems, ['MOKU_FLAGS: expected {"everyone": …, "plans": …, "devices": …}']);
    assert.deepEqual(parseFlags({ everyone: { minVersion: '0.1' } }, 'g').everyone, { minVersion: '0.1' });
    assert.deepEqual(parseFlags({ everyone: { minVersion: 'v1' } }, 'g').problems, ['g.everyone.minVersion: expected a version like "0.1.8", or null']);
  });
});

describe('resolving', () => {
  const env = parseFlags({ everyone: { forceCalm: true, callsPerDay: 100 }, plans: { trial: { forceCalm: false, cloudVoice: false } }, devices: { [ALICE.slice(0, 12)]: { forceCalm: true } } }, 'env');
  const edge = parseFlags({ everyone: { callsPerDay: 50 }, plans: { trial: { cloudVoice: true } } }, 'edge');

  it('the most specific scope wins: everyone, then the plan, then the device; Global Config wins within a scope', () => {
    assert.deepEqual(resolveFlags(DEFAULTS, [env]), { ...DEFAULTS, forceCalm: true, callsPerDay: 100 });
    assert.deepEqual(resolveFlags(DEFAULTS, [env], { plan: 'trial', device: BOB }), { ...DEFAULTS, forceCalm: false, cloudVoice: false, callsPerDay: 100 });
    assert.deepEqual(resolveFlags(DEFAULTS, [env], { plan: 'trial', device: ALICE }), { ...DEFAULTS, forceCalm: true, cloudVoice: false, callsPerDay: 100 });
    assert.deepEqual(resolveFlags(DEFAULTS, [env, edge], { plan: 'trial', device: BOB }), { ...DEFAULTS, forceCalm: false, callsPerDay: 50 });
  });

  it('a device id matches over the shorter of the two, at least 12 characters', () => {
    assert.ok(sameDevice(ALICE.slice(0, 12), ALICE));
    assert.ok(sameDevice(ALICE, ALICE.slice(0, 12)));
    assert.ok(!sameDevice(ALICE.slice(0, 12), BOB));
    assert.ok(!sameDevice(ALICE.slice(0, 11), ALICE));
  });
});

describe('POST /v1/flags', () => {
  it('answers the defaults to an install, only the switches the app reads, and logs who and which version', async () => {
    const r = relay();
    const { status, body } = await flagsOf(r, trial());
    assert.equal(status, 200);
    assert.deepEqual(body, { cloudJudging: true, cloudVoice: true, forceCalm: false, minVersion: null });
    assert.deepEqual(r.lines, [`moku-proxy flags trial/${ALICE.slice(0, 12)} 0.1.8`]);
  });

  it('each override resolves for everyone, one plan, and one device', async () => {
    const r = relay({
      MOKU_FLAGS: JSON.stringify({
        everyone: { minVersion: '0.1.8' },
        plans: { trial: { cloudJudging: false } },
        devices: { [BOB.slice(0, 12)]: { forceCalm: true }, [CAROL]: { cloudVoice: false } },
      }),
    });
    // Everyone: minVersion. The trial plan: Jev off. Bob's Mac alone: calm.
    assert.deepEqual((await flagsOf(r, trial(ALICE))).body, { cloudJudging: false, cloudVoice: true, forceCalm: false, minVersion: '0.1.8' });
    assert.deepEqual((await flagsOf(r, trial(BOB), { device: BOB, version: '0.1.7' })).body, { cloudJudging: false, cloudVoice: true, forceCalm: true, minVersion: '0.1.8' });
    // A friend with an invite (tester): not the trial's override; their device by its whole hash, from a token that holds 12.
    assert.deepEqual((await flagsOf(r, tester(CAROL), { device: CAROL, version: '0.1.8' })).body, { cloudJudging: true, cloudVoice: false, forceCalm: false, minVersion: '0.1.8' });
    // The device in the body can't stand in for the one in the token.
    assert.equal((await flagsOf(r, trial(ALICE), { device: BOB, version: '0.1.8' })).body.forceCalm, false);
  });

  it('a static tester token names no device, so the body\'s device counts', async () => {
    const r = relay({ MOKU_FLAGS: JSON.stringify({ devices: { [ALICE.slice(0, 12)]: { forceCalm: true } } }) });
    assert.equal((await flagsOf(r, STATIC)).body.forceCalm, true);
    assert.equal((await flagsOf(r, STATIC, { device: BOB, version: '0.1.8' })).body.forceCalm, false);
  });

  it('needs the install\'s token (401 without one), and an ended trial still gets its switches', async () => {
    const r = relay({ MOKU_FLAGS: '{"everyone":{"forceCalm":true}}' });
    assert.equal((await flagsOf(r, null)).status, 401);
    assert.equal((await flagsOf(r, 'moku1.forged.token')).status, 401);
    assert.equal((await flagsOf(r, signToken({ sub: ALICE, plan: 'trial', exp: 0, iat: 0 }, 'other-secret'))).status, 401);
    const ended = await flagsOf(r, trial(ALICE, NOW - DAY));
    assert.equal(ended.status, 200);
    assert.equal(ended.body.forceCalm, true);
  });
});

describe('the relay enforces the switches', () => {
  it('cloudJudging off: Jev answers 503 "cloud off" without calling the gateway; Luna still works', async () => {
    const r = relay({ MOKU_FLAGS: '{"everyone":{"cloudJudging":false}}' });
    const res = await r.handle(modelCall(trial()));
    assert.equal(res.status, 503);
    assert.equal(res.headers.get('retry-after'), '600');
    assert.deepEqual(await res.json(), { error: 'cloud off', code: 'cloud_off' });
    assert.equal(r.calls.length, 0);
    assert.equal((await r.handle(modelCall(trial(), 'language-model'))).status, 200);
    assert.equal(r.calls.length, 1);
    assert.match(r.lines[0], /^moku-proxy trial:a1a1\S+ typesafe-ai\/jev cloud-off$/);
  });

  it('cloudVoice off for one plan: that plan\'s Luna calls are refused, the others\' go through', async () => {
    const r = relay({ MOKU_FLAGS: '{"plans":{"trial":{"cloudVoice":false}}}' });
    assert.equal((await r.handle(modelCall(trial(), 'language-model'))).status, 503);
    assert.equal((await r.handle(modelCall(trial()))).status, 200);
    assert.equal((await r.handle(modelCall(tester(), 'language-model'))).status, 200);
  });

  it('one device switched off; the rest of its plan untouched', async () => {
    const r = relay({ MOKU_FLAGS: JSON.stringify({ devices: { [BOB.slice(0, 12)]: { cloudJudging: false } } }) });
    assert.equal((await r.handle(modelCall(trial(BOB)))).status, 503);
    assert.equal((await r.handle(modelCall(trial(ALICE)))).status, 200);
  });

  it('per-plan call limits: trials get 2 a day, testers keep MOKU_RATE_PER_DAY', async () => {
    const r = relay({ MOKU_RATE_PER_DAY: '5', MOKU_FLAGS: '{"plans":{"trial":{"callsPerDay":2}}}' });
    assert.equal((await r.handle(modelCall(trial()))).status, 200);
    assert.equal((await r.handle(modelCall(trial()))).status, 200);
    assert.equal((await r.handle(modelCall(trial()))).status, 429);
    for (let i = 0; i < 3; i++) assert.equal((await r.handle(modelCall(tester()))).status, 200);
  });

  // A friend's day is ~300 calls and the busiest day any Mac had 2,978 (PostHog, 2026-10-09); 5,000 a day let one
  // scripted trial cost far more than Moku ever uses (launch review 2026-10-09, B2).
  it('a trial starts at 3,000 calls a day, never above MOKU_RATE_PER_DAY; testers keep it; any MOKU_FLAGS entry wins', async () => {
    const make = (/** @type {Record<string, string>} */ env = {}) =>
      createFlags({ env: { MOKU_RATE_PER_DAY: '5000', ...env }, fetch: gateway().fetch, now: () => NOW, log: () => {} });
    assert.equal((await make().forWho({ plan: 'trial' })).callsPerDay, 3000);
    assert.equal((await make().forWho({ plan: 'tester' })).callsPerDay, 5000);
    assert.equal((await make().forWho({})).callsPerDay, 5000);
    assert.equal((await make({ MOKU_RATE_PER_DAY: '1000' }).forWho({ plan: 'trial' })).callsPerDay, 1000);
    assert.equal((await make({ MOKU_FLAGS: '{"plans":{"trial":{"callsPerDay":4000}}}' }).forWho({ plan: 'trial' })).callsPerDay, 4000);
    assert.equal((await make({ MOKU_FLAGS: '{"everyone":{"callsPerDay":4500}}' }).forWho({ plan: 'trial' })).callsPerDay, 4500);
  });

  it('with no flags set, the relay behaves as before', async () => {
    const r = relay({ MOKU_RATE_PER_MINUTE: '2' });
    assert.equal((await r.handle(modelCall(trial()))).status, 200);
    assert.equal((await r.handle(modelCall(trial()))).status, 200);
    assert.equal((await r.handle(modelCall(trial()))).status, 429);
  });
});

describe('newInstallsPerDay', () => {
  it('caps new trials a UTC day (retry at midnight), never invites, and opens again the next day', async () => {
    let now = NOW;
    const r = relay({ MOKU_FLAGS: '{"everyone":{"newInstallsPerDay":2}}', MOKU_INVITES: `friends:${(await import('../api/_lib/access.js')).hashInvite('MOKU-AAAA-BBBB')}` }, { now: () => now });
    assert.equal((await r.handle(install({ device: ALICE }))).status, 200);
    assert.equal((await r.handle(install({ device: BOB }))).status, 200);
    const full = await r.handle(install({ device: 'd4'.repeat(32) }));
    assert.equal(full.status, 429);
    assert.equal(full.headers.get('retry-after'), String(15 * 3600));
    assert.deepEqual(await full.json(), { error: 'new installs are full for today', code: 'installs_full' });
    assert.equal((await r.handle(install({ device: 'd4'.repeat(32), invite: 'MOKU-AAAA-BBBB' }))).status, 200);
    now += DAY;
    assert.equal((await r.handle(install({ device: 'd4'.repeat(32) }))).status, 200);
  });

  it('0 closes new trials; with Upstash, a Mac seen before gets back in when the day is full', async () => {
    const seen = new Set([ALICE]);
    /** @type {typeof fetch} */
    const redis = async (_url, init) => {
      const commands = JSON.parse(String(init?.body));
      return new Response(JSON.stringify(commands.map((/** @type {string[]} */ [op, key]) => {
        const device = key.split(':').at(-1);
        if (op === 'GET') return { result: device && seen.has(device) ? String(NOW - DAY) : null };
        if (op === 'SET') { if (device) seen.add(device); return { result: 'OK' }; }
        return { result: 1 };
      })));
    };
    const r = relay({ MOKU_FLAGS: '{"everyone":{"newInstallsPerDay":0}}', UPSTASH_REDIS_REST_URL: 'https://redis.example', UPSTASH_REDIS_REST_TOKEN: 't' },
      { fetch: redis });
    assert.equal((await r.handle(install({ device: BOB }))).status, 429);
    const back = await r.handle(install({ device: ALICE }));
    assert.equal(back.status, 200);
    assert.equal((await back.json()).expiresAt, NOW - DAY + 21 * DAY); // the first install's date still counts
  });
});

describe('Vercel Global Config (Edge Config)', () => {
  it('reads the flags item with the connection string\'s token, lays it over MOKU_FLAGS, and keeps it 30 s', async () => {
    let now = NOW;
    let item = { everyone: { forceCalm: true } };
    const reads = /** @type {{ url: string, auth: string | null }[]} */ ([]);
    /** @type {typeof fetch} */
    const fetchImpl = async (url, init) => {
      if (!String(url).startsWith('https://global-config.vercel.com/')) return new Response('{"answers":{}}');
      reads.push({ url: String(url), auth: new Headers(init?.headers).get('authorization') });
      return new Response(JSON.stringify(item));
    };
    const r = relay({ GLOBAL_CONFIG: 'https://global-config.vercel.com/ecfg_abc?token=edge-token', MOKU_FLAGS: '{"everyone":{"forceCalm":false,"minVersion":"0.1.7"}}' },
      { fetch: fetchImpl, now: () => now });
    assert.deepEqual((await flagsOf(r, trial())).body, { cloudJudging: true, cloudVoice: true, forceCalm: true, minVersion: '0.1.7' });
    assert.deepEqual(reads, [{ url: 'https://global-config.vercel.com/ecfg_abc/item/flags?version=1', auth: 'Bearer edge-token' }]);
    item = { everyone: { forceCalm: false } };
    assert.equal((await flagsOf(r, trial())).body.forceCalm, true); // still cached
    now += 31_000;
    assert.equal((await flagsOf(r, trial())).body.forceCalm, false);
    assert.equal(reads.length, 2);
    const health = await (await r.handle(new Request('https://relay.example/api/proxy?path=health'))).json();
    assert.deepEqual(health.flags, { source: 'MOKU_FLAGS+global-config', problems: 0 });
  });

  it('no item (404) is no overrides; a failed read keeps the last value', async () => {
    let now = 0, answer = () => new Response('not found', { status: 404 });
    const lines = /** @type {string[]} */ ([]);
    const read = globalConfigReader({ connection: 'https://edge-config.vercel.com/ecfg_x?token=t', fetch: async () => answer(), now: () => now, log: (l) => lines.push(l) });
    assert.equal(await read(), null);
    answer = () => new Response('{"everyone":{"cloudJudging":false}}');
    now += 31_000;
    assert.deepEqual(await read(), { everyone: { cloudJudging: false } });
    answer = () => new Response('oops', { status: 500 });
    now += 31_000;
    assert.deepEqual(await read(), { everyone: { cloudJudging: false } });
    assert.deepEqual(lines, ['moku-proxy flags global-config-error status 500']);
  });
});

describe('/health and the logs', () => {
  it('count the dropped entries (never the flags), and the log names them once', async () => {
    const r = relay({ MOKU_FLAGS: '{"everyone":{"forceCalm":"yes","cloudJudging":false}}' });
    const health = await (await r.handle(new Request('https://relay.example/api/proxy?path=health'))).json();
    assert.deepEqual(health.flags, { source: 'MOKU_FLAGS', problems: 1 });
    assert.deepEqual(r.lines, ['moku-proxy flags dropped: MOKU_FLAGS.everyone.forceCalm: expected true or false']);
    assert.equal((await r.handle(modelCall(trial()))).status, 503); // the valid half still applies
  });
});

describe('names that are not flags', () => {
  it("drops Object's own names instead of crashing (the kill switch stays)", () => {
    const doc = parseFlags('{"everyone":{"constructor":true,"__proto__":{"x":1},"toString":1,"forceCalm":true},"plans":{"trial":{"hasOwnProperty":2}}}', 'MOKU_FLAGS');
    assert.deepEqual(doc.everyone, { forceCalm: true });
    assert.deepEqual(doc.plans.trial, {});
    assert.equal(doc.problems.length, 4);  // constructor, __proto__, toString, hasOwnProperty
  });
});
