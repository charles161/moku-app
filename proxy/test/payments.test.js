// @ts-check
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { describe, it } from 'node:test';
import { readToken, signToken, trialClaims } from '../api/_lib/access.js';
import { GRACE_MS, proUntilFor, verifyWebhook } from '../api/_lib/payments.js';
import { createProxy } from '../api/_lib/proxy.js';
import { JEV_BODY } from './support/brain-requests.js';

/** Moku Pro through Dodo (docs/specs/payments.md). */
const SECRET = 'token-secret';
const WEBHOOK_KEY = `whsec_${Buffer.from('dodo-webhook-secret').toString('base64')}`;
const REDIS = 'https://redis.example';
const DODO = 'https://test.dodopayments.com';
const DEVICE = 'a1b2c3d4e5f6';
const NOW = Date.parse('2026-10-14T10:00:00Z');
const DAY = 86_400_000;

function fakeRedis() {
  /** @type {Map<string, { value: string, until: number }>} */
  const data = new Map();
  const run = (/** @type {string[]} */ [op, key, ...rest], /** @type {number} */ now) => {
    const live = (/** @type {string} */ k) => { const e = data.get(k); return e && e.until > now ? e : null; };
    switch (op) {
      case 'GET': return live(key)?.value ?? null;
      case 'DEL': return data.delete(key) ? 1 : 0;
      case 'INCR': case 'INCRBY': { const n = Number(live(key)?.value ?? 0) + Number(rest[0] ?? 1); data.set(key, { value: String(n), until: Infinity }); return n; }
      case 'EXPIRE': case 'PEXPIRE': return 1;
      case 'SET': {
        if (rest.includes('NX') && live(key)) return null;
        const at = rest.indexOf('PXAT'), ex = rest.indexOf('EX');
        const until = at >= 0 ? Number(rest[at + 1]) : ex >= 0 ? now + Number(rest[ex + 1]) * 1000 : Infinity;
        data.set(key, { value: rest[0], until });
        return 'OK';
      }
      default: return null;
    }
  };
  return { data, run };
}

function world(/** @type {Record<string, string>} */ env = {}) {
  let now = NOW;
  const redis = fakeRedis();
  const dodo = /** @type {{ url: string, auth: string | null, body: any }[]} */ ([]);
  /** @type {typeof fetch} */
  const fetchImpl = async (input, init) => {
    const url = String(input);
    if (url.startsWith(REDIS)) {
      const commands = JSON.parse(String(init?.body));
      return new Response(JSON.stringify(commands.map((/** @type {string[]} */ c) => ({ result: redis.run(c, now) }))), { status: 200 });
    }
    if (url.startsWith(DODO) || url.startsWith('https://live.dodopayments.com')) {
      dodo.push({ url, auth: new Headers(init?.headers).get('authorization'), body: JSON.parse(String(init?.body)) });
      return new Response(JSON.stringify({ session_id: 'cks_1', checkout_url: 'https://checkout.dodopayments.com/session/cks_1' }), { status: 200 });
    }
    return new Response('{}', { status: 200 });
  };
  const handle = createProxy({
    env: { AI_GATEWAY_API_KEY: 'k', MOKU_TOKEN_SECRET: SECRET, KV_REST_API_URL: REDIS, KV_REST_API_TOKEN: 't',
      DODO_PAYMENTS_API_KEY: 'dodo_test_key', DODO_PAYMENTS_WEBHOOK_KEY: WEBHOOK_KEY, DODO_PRODUCT_MONTHLY: 'pdt_month', DODO_PRODUCT_YEARLY: 'pdt_year',
      DODO_TEST_DEVICES: `0000aaaa0000, ${DEVICE}`, ...env },
    fetch: fetchImpl, log: () => {}, now: () => now, waitUntil: () => {},
  });
  const post = (/** @type {string} */ path, /** @type {unknown} */ body, /** @type {Record<string, string>} */ headers = {}) =>
    handle(new Request(`https://relay.example/api/proxy?path=${path}`, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: typeof body === 'string' ? body : JSON.stringify(body) }));
  return { redis, dodo, post, get now() { return now; }, set now(v) { now = v; } };
}

/** A Dodo delivery, signed the Standard Webhooks way. */
function delivery(/** @type {string} */ id, /** @type {string} */ type, /** @type {Record<string, unknown>} */ data, sentAt = NOW, key = WEBHOOK_KEY) {
  const body = JSON.stringify({ business_id: 'bus_1', type, timestamp: new Date(sentAt).toISOString(), data });
  const ts = String(Math.floor(sentAt / 1000));
  const sig = createHmac('sha256', Buffer.from(key.replace(/^whsec_/, ''), 'base64')).update(`${id}.${ts}.${body}`).digest('base64');
  return { body, headers: { 'webhook-id': id, 'webhook-timestamp': ts, 'webhook-signature': `v1,${sig}` } };
}
const subscription = (/** @type {Record<string, unknown>} */ fields) => ({
  payload_type: 'Subscription', subscription_id: 'sub_1', status: 'active', next_billing_date: new Date(NOW + 30 * DAY).toISOString(),
  metadata: { moku_device: DEVICE }, customer: { email: 'someone@example.com' }, ...fields,
});
const trialToken = (/** @type {number} */ start) => signToken(trialClaims(DEVICE, start, start), SECRET);
const renew = async (/** @type {ReturnType<typeof world>} */ w, /** @type {string} */ token) => {
  const res = await w.post('v1/renew', {}, { authorization: `Bearer ${token}` });
  return { status: res.status, body: await res.json() };
};

describe('Moku Pro through Dodo', () => {
  it('checkout: the Mac\'s plan, with its id in the metadata, and the hosted page\'s address back', async () => {
    const w = world();
    const res = await w.post('v1/checkout', { plan: 'yearly' }, { authorization: `Bearer ${trialToken(NOW)}` });
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { url: 'https://checkout.dodopayments.com/session/cks_1' });
    assert.equal(w.dodo.length, 1);
    assert.equal(w.dodo[0].url, `${DODO}/checkouts`);
    assert.equal(w.dodo[0].auth, 'Bearer dodo_test_key');
    assert.deepEqual(w.dodo[0].body.product_cart, [{ product_id: 'pdt_year', quantity: 1 }]);
    assert.deepEqual(w.dodo[0].body.metadata, { moku_device: DEVICE });
    assert.equal(w.dodo[0].body.customer, undefined, 'no email or name of ours: Dodo asks for them');
  });

  it('checkout needs a Mac\'s token, and payments configured', async () => {
    assert.equal((await world().post('v1/checkout', { plan: 'monthly' })).status, 401);
    assert.equal((await world({ DODO_PAYMENTS_API_KEY: '' }).post('v1/checkout', {}, { authorization: `Bearer ${trialToken(NOW)}` })).status, 503);
  });

  it('test mode: only the Macs named for testing get a checkout; the rest hear it isn\'t open (no Pro for a test card)', async () => {
    const closed = world({ DODO_TEST_DEVICES: '' });
    assert.equal((await closed.post('v1/checkout', { plan: 'monthly' }, { authorization: `Bearer ${trialToken(NOW)}` })).status, 503);
    assert.equal(closed.dodo.length, 0);
    const live = world({ DODO_TEST_DEVICES: '', DODO_ENVIRONMENT: 'live_mode' });
    const res = await live.post('v1/checkout', { plan: 'monthly' }, { authorization: `Bearer ${trialToken(NOW)}` });
    assert.equal(res.status, 200, 'live mode is open to every Mac');
    assert.equal(live.dodo[0].url, 'https://live.dodopayments.com/checkouts');
  });

  it('a paid subscription makes the Mac Pro on its next renewal, to the billing date and a little grace', async () => {
    const w = world();
    const ended = trialToken(NOW - 22 * DAY);
    assert.equal((await renew(w, ended)).status, 402, 'the trial is over');
    const d = delivery('evt_1', 'subscription.active', subscription({}));
    assert.equal((await w.post('v1/dodo', d.body, d.headers)).status, 200);
    const pro = await renew(w, ended);
    assert.equal(pro.status, 200);
    assert.equal(pro.body.plan, 'pro');
    const claims = readToken(pro.body.token, SECRET);
    assert.equal(claims?.plan, 'pro');
    assert.equal(claims?.sub, DEVICE);
    assert.equal(claims?.exp, NOW + 30 * DAY + GRACE_MS);
  });

  it('a forged, replayed or stale delivery changes nothing', async () => {
    const w = world();
    const forged = delivery('evt_2', 'subscription.active', subscription({}), NOW, `whsec_${Buffer.from('wrong').toString('base64')}`);
    assert.equal((await w.post('v1/dodo', forged.body, forged.headers)).status, 401);
    const old = delivery('evt_3', 'subscription.active', subscription({}), NOW - 10 * 60_000);
    assert.equal((await w.post('v1/dodo', old.body, old.headers)).status, 401);
    const tampered = delivery('evt_4', 'subscription.active', subscription({}));
    assert.equal((await w.post('v1/dodo', tampered.body.replace(DEVICE, 'ffffffffffff'), tampered.headers)).status, 401);
    assert.equal(w.redis.data.has(`moku:pro:${DEVICE}`), false);
  });

  it('a delivery handled once: Dodo\'s retry of it is acknowledged and changes nothing', async () => {
    const w = world();
    const first = delivery('evt_5', 'subscription.active', subscription({}));
    await w.post('v1/dodo', first.body, first.headers);
    const hold = delivery('evt_6', 'subscription.on_hold', subscription({ status: 'on_hold' }));
    await w.post('v1/dodo', hold.body, hold.headers);
    const again = delivery('evt_5', 'subscription.active', subscription({}));
    assert.equal((await w.post('v1/dodo', again.body, again.headers)).status, 200);
    assert.equal(w.redis.data.has(`moku:pro:${DEVICE}`), false, 'the retry of the older delivery didn\'t bring Pro back');
  });

  it('cancelled at period end: Pro until the paid period ends, no grace; on hold: Pro ends at once', async () => {
    const w = world();
    const ended = trialToken(NOW - 22 * DAY);
    const cancel = delivery('evt_7', 'subscription.cancelled', subscription({ cancel_at_next_billing_date: true }));
    await w.post('v1/dodo', cancel.body, cancel.headers);
    assert.equal(readToken((await renew(w, ended)).body.token, SECRET)?.exp, NOW + 30 * DAY);
    const hold = delivery('evt_8', 'subscription.on_hold', subscription({ status: 'on_hold' }));
    await w.post('v1/dodo', hold.body, hold.headers);
    assert.equal((await renew(w, ended)).status, 402);
  });

  it('a Pro token past its end is refused like an ended trial, so the brain rests in local mode', async () => {
    const w = world();
    const token = signToken({ sub: DEVICE, plan: 'pro', exp: NOW - 1, iat: NOW - 30 * DAY }, SECRET);
    const res = await w.post('evaluation-model', JEV_BODY, { authorization: `Bearer ${token}`, 'ai-model-id': 'typesafe-ai/jev' });
    assert.equal(res.status, 402);
    assert.equal((await res.json()).code, 'trial_ended');
  });

  it('the pieces: signatures, and what a subscription\'s state means', () => {
    const body = '{"a":1}';
    const sig = createHmac('sha256', Buffer.from('k')).update(`id.100.${body}`).digest('base64');
    assert.ok(verifyWebhook({ id: 'id', timestamp: '100', signature: `v1,${sig}`, body, secret: `whsec_${Buffer.from('k').toString('base64')}`, nowS: 100 }));
    assert.ok(verifyWebhook({ id: 'id', timestamp: '100', signature: `v1,AAAA v1,${sig}`, body, secret: `whsec_${Buffer.from('k').toString('base64')}`, nowS: 100 }), 'any of several signatures');
    assert.ok(!verifyWebhook({ id: 'id', timestamp: '100', signature: 'v1,short', body, secret: `whsec_${Buffer.from('k').toString('base64')}`, nowS: 100 }));
    const next = new Date(NOW + DAY).toISOString();
    assert.equal(proUntilFor({ status: 'active', next_billing_date: next }), NOW + DAY + GRACE_MS);
    assert.equal(proUntilFor({ status: 'active', next_billing_date: next, cancel_at_next_billing_date: true }), NOW + DAY);
    for (const status of ['on_hold', 'paused', 'cancelled', 'failed', 'expired', 'pending']) assert.equal(proUntilFor({ status, next_billing_date: next }), 0, status);
  });
});
