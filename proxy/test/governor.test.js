// @ts-check
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { signToken, trialClaims } from '../api/_lib/access.js';
import { allowances, untilMidnight } from '../api/_lib/governor.js';
import { createProxy, hashToken } from '../api/_lib/proxy.js';
import { JEV_BODY } from './support/brain-requests.js';

// The governor (docs/specs/governor.md, approved 2026-10-09): AI spend stays inside the budget however many Macs
// install. These run the real relay handler against a fake Upstash and a fake gateway that charges per call.

const SECRET = 'test-secret';
const DAY = 86_400_000;
const DAY1 = Date.UTC(2026, 9, 30); // a UTC midnight
const REDIS = 'https://redis.example';
const COST = 0.00004;
const BUDGET = 1.6; // the default: $48 a month, under the AI Gateway's $50 stop

/** An in-memory Upstash (HINCRBY, HLEN, EXPIRE, GET, SET with NX and EX, INCRBY, INCRBYFLOAT) that counts every command it runs. */
function fakeRedis() {
  const data = new Map();
  /** Each key's expiry, in seconds, as last set. */
  const ttl = new Map();
  let commands = 0;
  /** @param {string[]} c */
  const run = ([op, key, ...rest]) => {
    commands++;
    switch (op) {
      case 'HINCRBY': {
        const hash = data.get(key) ?? new Map();
        data.set(key, hash);
        const n = Number(hash.get(rest[0]) ?? 0) + Number(rest[1]);
        hash.set(rest[0], n);
        return n;
      }
      case 'HLEN': return data.get(key)?.size ?? 0;
      case 'EXPIRE': if (!data.has(key)) return 0; ttl.set(key, Number(rest[0])); return 1;
      case 'GET': return data.get(key) ?? null;
      case 'INCRBY': { const n = Number(data.get(key) ?? 0) + Number(rest[0]); data.set(key, String(n)); return n; }
      case 'INCRBYFLOAT': { const n = Number(data.get(key) ?? 0) + Number(rest[0]); data.set(key, String(n)); return String(n); }
      case 'SET': {
        if (rest.includes('NX') && data.has(key)) return null;
        data.set(key, rest[0]);
        return 'OK';
      }
      default: throw new Error(`fake redis: ${op}`);
    }
  };
  return { data, ttl, run, get commands() { return commands; } };
}

/**
 * The relay with a fake Redis, a fake gateway that charges `price` a call (COST unless said; null: the gateway doesn't
 * say what a call cost, which is still charged at COST), and PostHog recorded.
 */
function world(/** @type {Record<string, string>} */ env = {}, /** @type {{ price?: number | null }} */ { price = COST } = {}) {
  let now = DAY1;
  const redis = fakeRedis();
  const posthog = /** @type {any[]} */ ([]);
  let spent = 0, gatewayCalls = 0;
  /** @type {typeof fetch} */
  const fetchImpl = async (input, init) => {
    const url = String(input);
    if (url.startsWith(REDIS)) {
      const commands = JSON.parse(String(init?.body));
      return new Response(JSON.stringify(commands.map((/** @type {string[]} */ c) => ({ result: redis.run(c) }))), { status: 200 });
    }
    if (url.includes('posthog')) { posthog.push(JSON.parse(String(init?.body))); return new Response('{}', { status: 200 }); }
    gatewayCalls++;
    spent += price ?? COST;
    return new Response(JSON.stringify({ answers: {}, usage: { inputTokens: 900, outputTokens: 30 }, ...(price === null ? {} : { providerMetadata: { gateway: { cost: String(price) } } }) }), { status: 200 });
  };
  const handle = createProxy({
    env: { AI_GATEWAY_API_KEY: 'k', MOKU_TOKEN_SECRET: SECRET, KV_REST_API_URL: REDIS, KV_REST_API_TOKEN: 't', POSTHOG_KEY: 'phc_test',
      MOKU_TESTER_TOKENS: `dave:${hashToken('moku_dave')}`, MOKU_INVITES: `friends:${'0'.repeat(64)}`, ...env },
    fetch: fetchImpl, log: () => {}, now: () => now, waitUntil: () => {},
  });
  const call = async (/** @type {string} */ token) => {
    const res = await handle(new Request('https://relay.example/api/proxy?path=evaluation-model', {
      method: 'POST', body: JEV_BODY, headers: { authorization: `Bearer ${token}`, 'ai-model-id': 'typesafe-ai/jev' },
    }));
    return { status: res.status, body: await res.json(), retryAfter: res.headers.get('retry-after') };
  };
  return {
    redis, posthog, call,
    get now() { return now; }, set now(v) { now = v; },
    get spent() { return spent; }, get gatewayCalls() { return gatewayCalls; },
  };
}

const device = (/** @type {number} */ i) => i.toString(16).padStart(64, '0');
/** A trial Mac first seen `ageDays` before `at`. */
const trial = (/** @type {number} */ i, /** @type {number} */ at, ageDays = 5) => signToken(trialClaims(device(i), at - ageDays * DAY, at), SECRET);

describe('the allowance', () => {
  const budget = 41_666; // $50 a month at $0.00004 a call
  it('splits the day\'s calls: a quarter among new Macs, the rest among established ones, each capped', () => {
    assert.deepEqual(allowances({ budgetCalls: budget, cap: 3000, activeNew: 10, activeOld: 90 }), { fresh: 1041, settled: 347 });
    assert.deepEqual(allowances({ budgetCalls: budget, cap: 3000, activeNew: 100, activeOld: 900 }), { fresh: 104, settled: 34 });
    assert.deepEqual(allowances({ budgetCalls: budget, cap: 3000, activeNew: 10_000, activeOld: 90_000 }), { fresh: 1, settled: 0 });
  });
  it('a share the cap leaves unused goes to the other group; one group alone takes the whole budget', () => {
    assert.deepEqual(allowances({ budgetCalls: budget, cap: 3000, activeNew: 2, activeOld: 1000 }), { fresh: 3000, settled: 35 });
    assert.deepEqual(allowances({ budgetCalls: budget, cap: 3000, activeNew: 0, activeOld: 10 }), { fresh: 3000, settled: 3000 });
    assert.deepEqual(allowances({ budgetCalls: budget, cap: 3000, activeNew: 0, activeOld: 100 }), { fresh: 3000, settled: 416 });
    assert.deepEqual(allowances({ budgetCalls: budget, cap: 3000, activeNew: 100, activeOld: 0 }), { fresh: 416, settled: 3000 });
  });
  it('nobody active yet is everyone at the cap', () => {
    assert.deepEqual(allowances({ budgetCalls: budget, cap: 3000, activeNew: 0, activeOld: 0 }), { fresh: 3000, settled: 3000 });
  });
});

describe('spend holds at any scale', () => {
  // Day 1 is the worst case: nothing known from yesterday, all Macs arriving in the first two hours. Each Mac asks every
  // 3 minutes, up to 300 times, and stops at its first "daily limit" (as a new brain does). A quarter installed
  // yesterday (new); the rest are established.
  for (const macs of [100, 1_000, 100_000]) {
    it(`${macs.toLocaleString('en')} Macs arriving in two hours spend at most the day's budget plus 5%`, async () => {
      const w = world();
      /** @type {Map<number, { i: number, token: string, calls: number }[]>} */
      const minutes = new Map();
      const at = (/** @type {number} */ m, /** @type {{ i: number, token: string, calls: number }} */ mac) => {
        if (!minutes.has(m)) minutes.set(m, []);
        /** @type {any[]} */ (minutes.get(m)).push(mac);
      };
      for (let i = 0; i < macs; i++) at(Math.floor((i / macs) * 120), { i, token: trial(i, DAY1, i % 4 === 0 ? 1 : 10), calls: 0 });
      let refused = 0, asked = 0;
      for (let m = 0; m < 24 * 60; m++) {
        for (const mac of minutes.get(m) ?? []) {
          w.now = DAY1 + m * 60_000;
          const res = await w.call(mac.token);
          asked++;
          mac.calls++;
          if (res.status === 429) { refused++; continue; }
          assert.equal(res.status, 200);
          if (mac.calls < 300) at(m + 3, mac);
        }
        minutes.delete(m);
      }
      if (process.env.GOVERNOR_REPORT) console.log(`${macs} Macs: $${w.spent.toFixed(2)} spent, ${w.gatewayCalls} calls, ${refused} Macs stopped, ${w.redis.commands} Redis commands`);
      assert.ok(w.spent <= BUDGET * 1.05, `spent $${w.spent.toFixed(2)} of $${BUDGET.toFixed(2)}`);
      if (macs <= 100) assert.equal(refused, 0, 'a small day meets no limit');
      // One Redis command per counted call, none for a Mac already refused today, and a few a minute to read the counts.
      assert.ok(w.redis.commands <= w.gatewayCalls + macs + 24 * 60 * 8, `${w.redis.commands} commands for ${w.gatewayCalls} calls (${asked} asked)`);
    });
  }
});

describe('fair from the second day', () => {
  it('with yesterday known, every Mac in a group gets the same calls, and the pool never has to cut in', async () => {
    const w = world();
    const macs = 1_000;
    const tokens = Array.from({ length: macs }, (_, i) => trial(i, DAY1, i % 4 === 0 ? 1 : 10));
    w.now = DAY1 + 3_600_000;
    for (const token of tokens) await w.call(token); // day 1: everyone once, so day 2 knows the crowd
    const got = /** @type {number[]} */ (Array(macs).fill(0));
    // Day 2: each Mac asks every 3 minutes from its own start through the day, until its first "daily limit".
    for (let m = 0; m < 20 * 60; m += 3) {
      w.now = DAY1 + 86_400_000 + m * 60_000;
      for (let i = 0; i < macs; i++) {
        if (got[i] < 0 || m < (i % 240)) continue; // arrivals spread over the first four hours
        const res = await w.call(tokens[i]);
        if (res.status === 429) got[i] = -got[i] - 1; else got[i]++;
      }
    }
    const calls = got.map((g) => (g < 0 ? -g - 1 : g));
    const fresh = new Set(calls.filter((_, i) => i % 4 === 0)), settled = new Set(calls.filter((_, i) => i % 4 !== 0));
    assert.equal(fresh.size, 1, `new Macs got ${[...fresh]} calls`);
    assert.equal(settled.size, 1, `established Macs got ${[...settled]} calls`);
    // $1.60 is 40,000 calls: a quarter shared by 250 new Macs (40 each), the rest by 750 established ones (40 each).
    assert.deepEqual([...fresh, ...settled], [40, 40]);
  });
});

describe('the pool counts dollars, not calls', () => {
  // Open-source review 2026-10-14, finding 1b: the pool was dailyBudgetUsd ÷ costPerCall calls, so calls dearer than
  // costPerCall (Luna's, or the largest a body allows) spent past the budget.
  it('calls three times dearer than costPerCall stop at the day\'s budget', async () => {
    const w = world({}, { price: 3 * COST });
    const tokens = Array.from({ length: 100 }, (_, i) => trial(i, DAY1));
    const stopped = new Set();
    for (let m = 0; m < 300 * 3; m += 3) {
      w.now = DAY1 + 3_600_000 + m * 60_000;
      for (const [i, token] of tokens.entries()) {
        if (stopped.has(i)) continue;
        const res = await w.call(token);
        if (res.status === 429) { assert.equal(res.body.code, 'daily_limit'); stopped.add(i); } else assert.equal(res.status, 200);
      }
    }
    if (process.env.GOVERNOR_REPORT) console.log(`at 3× costPerCall: $${w.spent.toFixed(2)} spent, ${w.gatewayCalls} calls, ${w.redis.commands} Redis commands`);
    // 100 Macs asking 300 times is $3.60 at this price: the pool holds it to the budget.
    assert.ok(w.spent <= BUDGET * 1.05, `spent $${w.spent.toFixed(2)} of $${BUDGET.toFixed(2)}`);
    assert.ok(w.spent >= BUDGET * 0.95, `spent only $${w.spent.toFixed(2)}`);
    assert.equal(stopped.size, 100);
  });

  it('adds each call\'s real cost to the day\'s dollars in Redis, kept three days; a call whose cost isn\'t said counts as costPerCall', async () => {
    const known = world({}, { price: 0.0001 });
    const unknown = world({}, { price: null });
    for (const w of [known, unknown]) {
      w.now = DAY1 + 3_600_000;
      for (let i = 0; i < 5; i++) assert.equal((await w.call(trial(i, w.now))).status, 200);
      // Testers aren't governed: their calls aren't in the day's dollars.
      assert.equal((await w.call(signToken({ sub: 'friends/0a1b2c3d4e5f', plan: 'tester', exp: 0, iat: w.now }, SECRET))).status, 200);
      w.now += 61_000; // the next call reads the day's counts and adds this instance's spend
      assert.equal((await w.call(trial(9, w.now))).status, 200);
    }
    const key = 'moku:spent-usd:2026-10-30';
    assert.ok(Math.abs(Number(known.redis.data.get(key)) - 5 * 0.0001) < 1e-9, known.redis.data.get(key));
    assert.ok(Math.abs(Number(unknown.redis.data.get(key)) - 5 * COST) < 1e-9, unknown.redis.data.get(key));
    assert.equal(known.redis.ttl.get(key), 3 * 86_400);
  });
});

describe('a Mac over its allowance', () => {
  it('is told "daily limit" until UTC midnight, then asks again without Redis; next day it starts over', async () => {
    const w = world({ MOKU_FLAGS: JSON.stringify({ everyone: { dailyBudgetUsd: 2 * COST } }) }); // two calls a day
    const token = trial(1, DAY1);
    w.now = DAY1 + 3_600_000;
    assert.equal((await w.call(token)).status, 200);
    assert.equal((await w.call(token)).status, 200);
    const over = await w.call(token);
    assert.equal(over.status, 429);
    assert.equal(over.body.code, 'daily_limit');
    assert.equal(over.retryAfter, String(untilMidnight(w.now)));
    assert.equal(over.retryAfter, String(23 * 3600));
    const before = w.redis.commands;
    assert.equal((await w.call(token)).status, 429);
    assert.equal(w.redis.commands, before, 'a refused Mac costs no Redis command for the rest of the day');
    w.now = DAY1 + DAY + 60_000;
    assert.equal((await w.call(token)).status, 200);
  });

  it('testers and static tokens are not governed: they keep their own callsPerDay', async () => {
    const w = world({ MOKU_RATE_PER_DAY: '5', MOKU_FLAGS: JSON.stringify({ everyone: { dailyBudgetUsd: 0 } }) });
    w.now = DAY1 + 3_600_000;
    assert.equal((await w.call(trial(1, w.now))).status, 429);
    const friend = signToken({ sub: 'friends/0a1b2c3d4e5f', plan: 'tester', exp: 0, iat: w.now }, SECRET);
    for (let i = 0; i < 5; i++) assert.equal((await w.call(friend)).status, 200);
    assert.equal((await w.call(friend)).status, 429);
    for (let i = 0; i < 5; i++) assert.equal((await w.call('moku_dave')).status, 200);
  });

  it('dailyBudgetUsd null turns the governor off: a trial keeps its 3,000 a day', async () => {
    const w = world({ MOKU_RATE_PER_DAY: '5000', MOKU_FLAGS: JSON.stringify({ everyone: { dailyBudgetUsd: null } }) });
    w.now = DAY1 + 3_600_000;
    for (let i = 0; i < 200; i++) assert.equal((await w.call(trial(i, w.now))).status, 200);
  });
});

describe('what Charles sees', () => {
  it('one governor_day event a day in PostHog: yesterday\'s active Macs and today\'s allowances, never a device', async () => {
    const w = world();
    w.now = DAY1 + 3_600_000;
    for (let i = 0; i < 30; i++) await w.call(trial(i, w.now, i < 10 ? 1 : 10));
    w.now = DAY1 + DAY + 3_600_000;
    await w.call(trial(1, w.now));
    w.now += 120_000;
    await w.call(trial(2, w.now));
    const days = w.posthog.filter((e) => e.event === 'governor_day');
    assert.equal(days.length, 1);
    assert.deepEqual(days[0].properties, {
      day: '2026-10-30', active_new: 10, active_old: 20, budget_usd: 1.6, cost_per_call: COST, spent_usd: 0.0012,
      allowance_new: 1000, allowance_old: 1500, $process_person_profile: false, $geoip_disable: true,
    });
    assert.equal(days[0].distinct_id, 'moku-relay');
  });
});

describe('an ended trial', () => {
  // The brain paused 5 minutes on a 402 and asked again, up to 288 times a day (launch review 2026-10-09). An ended
  // trial stays ended until a new token arrives (an invite typed in), which a new brain notices at once.
  it('gets 402 trial_ended with Retry-After of six hours, and costs no Redis command', async () => {
    const w = world();
    w.now = DAY1 + 3_600_000;
    const ended = signToken(trialClaims(device(7), w.now - 22 * DAY, w.now - DAY), SECRET);
    const before = w.redis.commands;
    const res = await w.call(ended);
    assert.equal(res.status, 402);
    assert.equal(res.body.code, 'trial_ended');
    assert.equal(res.retryAfter, String(6 * 3600));
    assert.equal(w.redis.commands, before);
  });
});
