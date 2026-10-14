// @ts-check
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { hashInvite, readToken } from '../api/_lib/access.js';
import { createProxy } from '../api/_lib/proxy.js';
import { APP_ID, fakeApple } from './support/fake-apple.js';

const SECRET = 'test-secret';
const DAY = 86_400_000;
const MAC = 'a'.repeat(64);
const OTHER_MAC = 'b'.repeat(64);
const apple = fakeApple();
const ENV = { AI_GATEWAY_API_KEY: 'k', MOKU_TOKEN_SECRET: SECRET, MOKU_INVITES: `friends:${hashInvite('MOKU-7F3K-QX2P')}`, MOKU_ATTEST_APP_ID: APP_ID };
const post = (/** @type {string} */ path, /** @type {object} */ body, /** @type {Record<string, string>} */ headers = {}) =>
  new Request(`https://relay.example/api/proxy?path=${path}`, { method: 'POST', headers: { 'content-type': 'application/json', 'x-forwarded-for': '1.2.3.4', ...headers }, body: JSON.stringify(body) });

/** Redis over a Map: SET NX and GET, nothing more (what attestation and first-seen use). */
function redis() {
  const store = new Map();
  /** @type {typeof fetch} */
  const fetchImpl = async (url, init) => {
    if (!String(url).includes('redis')) return new Response('{}');
    const out = [];
    for (const [op, key, value, nx] of JSON.parse(String(init?.body))) {
      if (op === 'SET') { if (nx === 'NX' && store.has(key)) out.push({ result: null }); else { store.set(key, value); out.push({ result: 'OK' }); } }
      else out.push({ result: store.get(key) ?? null });
    }
    return Response.json(out);
  };
  return { store, fetch: fetchImpl };
}
const REDIS_ENV = { UPSTASH_REDIS_REST_URL: 'https://redis.example', UPSTASH_REDIS_REST_TOKEN: 't' };

function relay(/** @type {'off' | 'observe' | 'require' | undefined} */ mode, extra = {}, fetch = redis().fetch) {
  const lines = /** @type {string[]} */ ([]);
  const env = { ...ENV, ...REDIS_ENV, ...(mode ? { MOKU_FLAGS: JSON.stringify({ everyone: { attestation: mode } }) } : {}), ...extra };
  const handle = createProxy({ env, fetch, log: (l) => lines.push(l), now: () => Date.now(), attestRoot: apple.root });
  return { handle, lines };
}
const challengeFrom = async (/** @type {ReturnType<typeof relay>} */ r) => (await (await r.handle(post('v1/attest/challenge', {}))).json()).challenge;
/** What the app does: ask for a challenge, have Apple (here, the fake) attest over it, send it with the install. */
async function attestedInstall(/** @type {ReturnType<typeof relay>} */ r, device = MAC, change = {}) {
  const challenge = await challengeFrom(r);
  const made = apple.attest({ challenge, device, ...change });
  return r.handle(post('v1/install', { device, attestation: { keyId: made.keyId.toString('base64'), object: made.object.toString('base64'), challenge } }));
}
const claimsOf = async (/** @type {Response} */ res) => readToken((await res.json()).token, SECRET);

describe('the attestation switch', () => {
  it('off (the default): a challenge is null, an attestation is ignored, a trial is given as always', async () => {
    const r = relay(undefined);
    assert.equal(await challengeFrom(r), null);
    const res = await attestedInstall(r, MAC, { appId: 'WRONG.app' });
    assert.equal(res.status, 200);
    assert.equal((await claimsOf(res))?.att, undefined);
    assert.deepEqual(r.lines.filter((l) => l.includes('attest')), []);
  });

  it('observe: a verified Mac gets att, one without gets a trial anyway, and the reason is logged', async () => {
    const r = relay('observe');
    assert.equal((await claimsOf(await attestedInstall(r)))?.att, 1);
    const plain = await r.handle(post('v1/install', { device: OTHER_MAC }));
    assert.equal(plain.status, 200);
    assert.equal((await claimsOf(plain))?.att, undefined);
    const wrong = await attestedInstall(r, 'c'.repeat(64), { appId: 'ABCDE12345.ai.lightslips.moku' });
    assert.equal(wrong.status, 200);
    assert.deepEqual(r.lines.filter((l) => l.includes('attest')), [
      `moku-proxy attest verified observe ${MAC.slice(0, 12)}`,
      `moku-proxy attest none observe ${OTHER_MAC.slice(0, 12)}`,
      `moku-proxy attest rp observe ${'c'.repeat(12)}`,
    ]);
  });

  it('require: a new Mac must be verified; the refusal says why in a code the app understands', async () => {
    const r = relay('require');
    const none = await r.handle(post('v1/install', { device: MAC }));
    assert.equal(none.status, 403);
    assert.deepEqual(await none.json(), { error: 'this Mac could not be verified as a Mac running Moku', code: 'attestation_required' });
    for (const bad of [{ appId: 'ABCDE12345.ai.lightslips.moku' }, { counter: 3 }, { nonce: Buffer.alloc(32) }]) {
      assert.equal((await attestedInstall(r, MAC, bad)).status, 403);
    }
    const ok = await attestedInstall(r);
    assert.equal(ok.status, 200);
    assert.equal((await claimsOf(ok))?.plan, 'trial');
  });

  it('require: a Mac seen before keeps its trial (reinstalling, or on a macOS without App Attest)', async () => {
    const fake = redis();
    const observing = relay('observe', {}, fake.fetch);
    assert.equal((await observing.handle(post('v1/install', { device: MAC }))).status, 200);
    const requiring = relay('require', {}, fake.fetch);
    assert.equal((await requiring.handle(post('v1/install', { device: MAC }))).status, 200);
    assert.equal((await requiring.handle(post('v1/install', { device: OTHER_MAC }))).status, 403);
  });

  it('require never asks an invite: a friend with a code is known', async () => {
    const r = relay('require');
    const res = await r.handle(post('v1/install', { device: MAC, invite: 'moku-7f3k-qx2p' }));
    assert.equal(res.status, 200);
    assert.equal((await claimsOf(res))?.plan, 'tester');
  });

  it('a refused Mac does not use up a day\'s new installs', async () => {
    const r = relay('require', { MOKU_FLAGS: JSON.stringify({ everyone: { attestation: 'require', newInstallsPerDay: 1 } }) });
    assert.equal((await r.handle(post('v1/install', { device: MAC }))).status, 403);
    assert.equal((await attestedInstall(r, OTHER_MAC)).status, 200, 'the one place was still free');
  });
});

describe('what an attestation can and cannot do', () => {
  it('is for one Mac: another Mac\'s device in the install fails, and so does a lifted key', async () => {
    const r = relay('require');
    const challenge = await challengeFrom(r);
    const made = apple.attest({ challenge, device: MAC });
    const body = (/** @type {string} */ device) => ({ device, attestation: { keyId: made.keyId.toString('base64'), object: made.object.toString('base64'), challenge } });
    assert.equal((await r.handle(post('v1/install', body(OTHER_MAC)))).status, 403, 'it vouched for MAC, not OTHER_MAC');
    assert.equal((await r.handle(post('v1/install', body(MAC)))).status, 200);
    assert.equal((await r.handle(post('v1/install', body(MAC)))).status, 200, 'the same Mac again: the same trial');
  });

  it('a key tied to one Mac refuses another (a statement lifted and re-used)', async () => {
    const r = relay('observe');
    const challenge = await challengeFrom(r);
    const made = apple.attest({ challenge, device: MAC });
    await r.handle(post('v1/install', { device: MAC, attestation: { keyId: made.keyId.toString('base64'), object: made.object.toString('base64'), challenge } }));
    // The same key, claimed for OTHER_MAC with its own statement over that device: Apple would never sign this twice, but if it were, the key is taken.
    const again = apple.attest({ challenge, device: OTHER_MAC, leafKeys: made.leafKeys });
    const res = await r.handle(post('v1/install', { device: OTHER_MAC, attestation: { keyId: again.keyId.toString('base64'), object: again.object.toString('base64'), challenge } }));
    assert.equal((await claimsOf(res))?.att, undefined);
    assert.ok(r.lines.some((l) => l.startsWith('moku-proxy attest key_reuse')));
  });

  it('needs a challenge this relay made, and a fresh one', async () => {
    const r = relay('require');
    for (const challenge of ['made-up', 'x.y.z', await challengeFrom(relay('require', { MOKU_TOKEN_SECRET: 'another-relay' }))]) {
      const made = apple.attest({ challenge, device: MAC });
      const res = await r.handle(post('v1/install', { device: MAC, attestation: { keyId: made.keyId.toString('base64'), object: made.object.toString('base64'), challenge } }));
      assert.equal(res.status, 403);
    }
    assert.deepEqual(r.lines.filter((l) => l.startsWith('moku-proxy attest')).map((l) => l.split(' ')[2]), ['challenge', 'challenge', 'challenge']);
  });

  it('garbage in the body is a plain refusal, never an error', async () => {
    const r = relay('require');
    for (const attestation of ['text', 5, null, [], {}, { keyId: 1, object: 2, challenge: 3 }, { keyId: 'x'.repeat(100), object: 'y', challenge: 'z' }, { keyId: 'AA==', object: 'x'.repeat(40_000), challenge: 'z' }]) {
      assert.equal((await r.handle(post('v1/install', { device: MAC, attestation }))).status, 403);
    }
  });

  it('survives Redis being down: nothing is lost but the key-reuse check', async () => {
    const down = relay('require', {}, async () => { throw new Error('down'); });
    assert.equal((await attestedInstall(down)).status, 200);
  });

  it('renewal keeps the mark', async () => {
    const r = relay('observe');
    const first = await (await attestedInstall(r)).json();
    const renewed = await r.handle(post('v1/renew', {}, { authorization: `Bearer ${first.token}` }));
    assert.equal((await claimsOf(renewed))?.att, 1);
    const plain = await (await r.handle(post('v1/install', { device: OTHER_MAC }))).json();
    const plainRenewed = await r.handle(post('v1/renew', {}, { authorization: `Bearer ${plain.token}` }));
    assert.equal((await claimsOf(plainRenewed))?.att, undefined);
  });

  it('challenges are rate limited per address and need the relay\'s secret', async () => {
    const r = relay('observe', { UPSTASH_REDIS_REST_URL: undefined, UPSTASH_REDIS_REST_TOKEN: undefined }); // the in-memory limiter
    let last = 200;
    for (let i = 0; i < 61; i++) last = (await r.handle(post('v1/attest/challenge', {}))).status;
    assert.equal(last, 429);
    const bare = createProxy({ env: { AI_GATEWAY_API_KEY: 'k' }, log: () => {} });
    assert.equal((await bare(post('v1/attest/challenge', {}))).status, 503);
  });
});

describe('the flag itself', () => {
  it('is for everyone only, and only the three words', async () => {
    const lines = /** @type {string[]} */ ([]);
    const handle = createProxy({ env: { ...ENV, MOKU_FLAGS: JSON.stringify({ everyone: { attestation: 'strict' }, plans: { trial: { attestation: 'require' } } }) }, log: (l) => lines.push(l) });
    assert.equal((await (await handle(post('v1/attest/challenge', {}))).json()).challenge, null, 'a bad value is dropped: still off');
    assert.match(lines.join('\n'), /everyone\.attestation: expected "off", "observe" or "require"/);
    assert.match(lines.join('\n'), /plans\.trial\.attestation: only for everyone/);
    assert.ok(DAY > 0);
  });
});
