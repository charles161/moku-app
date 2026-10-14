// @ts-check
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { addressKey, clientAddress } from '../api/_lib/address.js';
import { createProxy } from '../api/_lib/proxy.js';

// Security review low (2026-10-05): one IPv6 host owns a whole /64, so a limit per address was dodged by stepping
// through it. Per-address limits now key an IPv6 address by its /64, and an IPv4 address as itself.

describe('the address a per-address limit keys on', () => {
  it('keeps IPv4 as it is, with or without a port', () => {
    assert.equal(addressKey('203.0.113.7'), '203.0.113.7');
    assert.equal(addressKey(' 203.0.113.7 '), '203.0.113.7');
    assert.equal(addressKey('203.0.113.7:51234'), '203.0.113.7');
  });

  it('keys IPv6 by its /64, whichever way it is written', () => {
    const net = '2001:db8:85a3:0::/64';
    for (const written of [
      '2001:db8:85a3::8a2e:370:7334',                // compressed
      '2001:0DB8:85A3:0000:1111:2222:3333:4444',      // full, upper case, leading zeros
      '2001:db8:85a3:0:ffff:ffff:ffff:ffff',          // the last of the /64
      '2001:db8:85a3::',                              // the first
      '[2001:db8:85a3::1]',                           // bracketed
      '[2001:db8:85a3::1]:443',                       // bracketed, with a port
      '2001:db8:85a3::1%en0',                         // a zone id
      '2001:db8:85a3::1.2.3.4',                       // an IPv4 tail
    ]) assert.equal(addressKey(written), net, written);
    assert.equal(addressKey('2001:db8:85a3:1::1'), '2001:db8:85a3:1::/64');  // the next /64 is another key
    assert.equal(addressKey('fe80::1%eth0'), 'fe80:0:0:0::/64');
    assert.equal(addressKey('::1'), '0:0:0:0::/64');
    assert.equal(addressKey('::'), '0:0:0:0::/64');
  });

  it('reads an IPv4-mapped IPv6 address as the IPv4 address it is', () => {
    assert.equal(addressKey('::ffff:203.0.113.7'), '203.0.113.7');
    assert.equal(addressKey('::FFFF:203.0.113.7'), '203.0.113.7');
    assert.equal(addressKey('::ffff:cb00:7107'), '203.0.113.7');
    assert.equal(addressKey('0:0:0:0:0:ffff:cb00:7107'), '203.0.113.7');
    assert.equal(addressKey('[::ffff:203.0.113.7]:8080'), '203.0.113.7');
  });

  it('takes the first address in x-forwarded-for, else x-real-ip, else "unknown"; anything else is kept, cut short', () => {
    const from = (/** @type {Record<string, string>} */ headers) => clientAddress(new Request('https://relay.example/', { headers }));
    assert.equal(from({ 'x-forwarded-for': '2001:db8:85a3::1, 10.0.0.1' }), '2001:db8:85a3:0::/64');
    assert.equal(from({ 'x-forwarded-for': '::ffff:203.0.113.7,2001:db8::1' }), '203.0.113.7');
    assert.equal(from({ 'x-real-ip': '2001:db8:85a3::2' }), '2001:db8:85a3:0::/64');
    assert.equal(from({}), 'unknown');
    assert.equal(from({ 'x-forwarded-for': '' }), 'unknown');
    assert.equal(addressKey('not-an-address'), 'not-an-address');
    assert.equal(addressKey('x'.repeat(500)).length, 64);
  });
});

describe('every per-address limit treats one /64 as one address', () => {
  const sameNet = ['2001:db8:1:2::a', '2001:db8:1:2:ffff:ffff:ffff:ffff', '2001:db8:1:2::1:0'];
  const otherNet = '2001:db8:1:3::a';
  const DEVICE = (/** @type {number} */ i) => String(i).repeat(64);
  const posthog = () => /** @type {typeof fetch} */ (async () => new Response('{"status":"Ok"}'));
  /** @param {(ip: string, i: number) => Request} request @param {Record<string, string>} env */
  const statuses = async (request, env, addresses = [...sameNet, otherNet]) => {
    const relay = createProxy({ env, fetch: posthog(), log: () => {} });
    const out = [];
    for (const [i, ip] of addresses.entries()) out.push((await relay(request(ip, i))).status);
    return out;
  };
  const json = (/** @type {string} */ path, /** @type {unknown} */ body, /** @type {string} */ ip, headers = {}) => new Request(`https://relay.example/api/proxy?path=${path}`, {
    method: 'POST', headers: { 'content-type': 'application/json', 'x-forwarded-for': ip, ...headers }, body: JSON.stringify(body),
  });

  it('installs (MOKU_INSTALLS_PER_DAY)', async () => {
    assert.deepEqual(await statuses((ip, i) => json('v1/install', { device: DEVICE(i) }, ip), { MOKU_TOKEN_SECRET: 's', MOKU_INSTALLS_PER_DAY: '2' }), [200, 200, 429, 200]);
    // The IPv4-mapped form of an address shares its IPv4 count.
    assert.deepEqual(await statuses((ip, i) => json('v1/install', { device: DEVICE(i) }, ip), { MOKU_TOKEN_SECRET: 's', MOKU_INSTALLS_PER_DAY: '1' }, ['203.0.113.7', '::ffff:203.0.113.7']), [200, 429]);
  });

  it('heartbeats (MOKU_HEARTBEATS_PER_IP)', async () => {
    const beat = (/** @type {string} */ ip, /** @type {number} */ i) => json('v1/heartbeat', { device: DEVICE(i), day: '2026-10-05', counts: { screens: 1 } }, ip);
    assert.deepEqual(await statuses(beat, { POSTHOG_KEY: 'phc_test', MOKU_HEARTBEATS_PER_IP: '2' }), [202, 202, 429, 202]);
  });

  it('usage events (MOKU_EVENT_BATCHES_PER_IP)', async () => {
    const batch = (/** @type {string} */ ip, /** @type {number} */ i) => json('v1/events', { device: DEVICE(i), events: [] }, ip);
    assert.deepEqual(await statuses(batch, { POSTHOG_KEY: 'phc_test', MOKU_EVENT_BATCHES_PER_IP: '2' }), [202, 202, 429, 202]);
  });

  it('website errors (20 a day per address)', async () => {
    const SAFARI = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15';
    const error = (/** @type {string} */ ip) => json('v1/web-error', { kind: 'error', type: 'TypeError', message: 'x is null', page: '/' }, ip, { origin: 'https://hellomoku.com', 'user-agent': SAFARI });
    const addresses = Array.from({ length: 21 }, (_, i) => `2001:db8:1:2::${(i + 1).toString(16)}`);
    const out = await statuses(error, { POSTHOG_KEY: 'phc_test' }, [...addresses, otherNet]);
    assert.deepEqual([out.slice(0, 20).every((s) => s === 202), out[20], out[21]], [true, 429, 202]);
  });

  it('downloads counted (20 a day per address)', async () => {
    /** @type {string[]} */
    const counted = [];
    /** @type {typeof fetch} */
    const recording = async (_url, init) => { counted.push(String(init?.body)); return new Response('{"status":"Ok"}'); };
    const relay = createProxy({ env: { POSTHOG_KEY: 'phc_test' }, fetch: recording, log: () => {} });
    const get = (/** @type {string} */ ip) => new Request('https://relay.example/api/proxy?path=get&ref=x', { headers: { 'user-agent': 'Mozilla/5.0 Safari/605.1.15', 'x-forwarded-for': ip } });
    for (let i = 1; i <= 21; i++) assert.equal((await relay(get(`2001:db8:1:2::${i.toString(16)}`))).status, 302);
    assert.equal(counted.length, 20);
    await relay(get(otherNet));
    assert.equal(counted.length, 21);
  });
});
