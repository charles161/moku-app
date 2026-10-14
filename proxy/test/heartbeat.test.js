// @ts-check
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { flattenCounts } from '../api/_lib/heartbeat.js';
import { createProxy } from '../api/_lib/proxy.js';

const DEVICE = 'b'.repeat(64);
const beat = (body, ip = '5.6.7.8') => new Request('https://relay.example/api/proxy?path=v1/heartbeat', { method: 'POST', headers: { 'content-type': 'application/json', 'x-forwarded-for': ip }, body: JSON.stringify(body) });
const DAY = {
  device: DEVICE, day: '2026-09-28', version: '0.4.0', build: '212', macos: '26.1', chip: 'arm64', plan: 'tester',
  counts: { screens: 820, watchedMinutes: 410, verdicts: { working: 600, drifting: 90 }, models: { cloudP50Ms: 640, errors: { timeout: 2 } }, app: { cpuPercent: 3.14159, screenRecording: true } },
};
const posthog = (status = 200) => {
  /** @type {{ url: string, body: any }[]} */
  const calls = [];
  return { calls, fetch: /** @type {typeof fetch} */ (async (url, init) => { calls.push({ url: String(url), body: JSON.parse(String(init?.body)) }); return new Response('{"status":"Ok"}', { status }); }) };
};

describe('POST /v1/heartbeat', () => {
  it('passes a day of counts to PostHog as one daily_counts event, keyed by the device hash, dated that day', async () => {
    const ph = posthog();
    const handle = createProxy({ env: { POSTHOG_KEY: 'phc_test' }, fetch: ph.fetch, log: () => {} });
    const res = await handle(beat(DAY));
    assert.equal(res.status, 202);
    assert.deepEqual(await res.json(), { ok: true, forwarded: true });
    assert.equal(ph.calls.length, 1);
    assert.equal(ph.calls[0].url, 'https://eu.i.posthog.com/i/v0/e/');
    const { api_key, event, distinct_id, timestamp, properties } = ph.calls[0].body;
    assert.deepEqual({ api_key, event, distinct_id, timestamp }, { api_key: 'phc_test', event: 'daily_counts', distinct_id: DEVICE, timestamp: '2026-09-28T12:00:00Z' });
    assert.deepEqual(properties, {
      screens: 820, watchedMinutes: 410, verdicts_working: 600, verdicts_drifting: 90, models_cloudP50Ms: 640, models_errors_timeout: 2, app_cpuPercent: 3.142, app_screenRecording: true,
      version: '0.4.0', build: '212', macos: '26.1', chip: 'arm64', plan: 'tester', day: '2026-09-28', $lib: 'moku-relay', $geoip_disable: true,
    });
  });

  it('lets nothing but numbers through: text, arrays, odd keys, deep nesting and badly shaped strings are dropped', () => {
    assert.deepEqual(flattenCounts({ a: 1, title: 'my secret doc', list: [1, 2], 'bad key': 3, n: { m: { deep: 4, o: { deeper: 5 } } }, inf: Infinity, big: 1e12, ok: false }), { a: 1, n_m_deep: 4, big: 1e9, ok: false });
    assert.equal(flattenCounts(Object.fromEntries(Array.from({ length: 201 }, (_, i) => [`k${i}`, i]))), null);
  });

  it('drops strings that are not the known fields in their known shapes', async () => {
    const ph = posthog();
    const handle = createProxy({ env: { POSTHOG_KEY: 'phc_test' }, fetch: ph.fetch, log: () => {} });
    await handle(beat({ ...DAY, version: 'Writing to Alice about the offer', plan: 'enterprise', note: 'hello', chip: 'M4' }));
    const { properties } = ph.calls[0].body;
    for (const key of ['version', 'plan', 'note', 'chip']) assert.equal(key in properties, false, key);
  });

  it('refuses a bad device or day, a big body, and too many from one Mac or one address', async () => {
    const handle = createProxy({ env: { POSTHOG_KEY: 'phc_test' }, fetch: posthog().fetch, log: () => {} });
    assert.equal((await handle(beat({ ...DAY, device: 'mac-mini' }))).status, 400);
    assert.equal((await handle(beat({ ...DAY, day: 'yesterday' }))).status, 400);
    assert.equal((await handle(beat({ ...DAY, counts: { pad: 'x'.repeat(20_000) } }))).status, 413);
    const statuses = [];
    for (let i = 0; i < 9; i++) statuses.push((await handle(beat(DAY, '9.9.9.9'))).status);
    assert.deepEqual(statuses.slice(-2), [202, 429]);  // 8 a day per Mac
    const perIp = createProxy({ env: { POSTHOG_KEY: 'phc_test', MOKU_HEARTBEATS_PER_IP: '2' }, fetch: posthog().fetch, log: () => {} });
    const fromOneAddress = [];
    for (let i = 0; i < 3; i++) fromOneAddress.push((await perIp(beat({ ...DAY, device: String(i).repeat(64) }))).status);
    assert.deepEqual(fromOneAddress, [202, 202, 429]);
  });

  it('without a PostHog key it logs the counts (for vercel logs); a PostHog failure is a 502, so the app tries again', async () => {
    const lines = [];
    const logOnly = createProxy({ env: {}, log: (line) => lines.push(line) });
    const res = await logOnly(beat(DAY));
    assert.equal(res.status, 202);
    assert.deepEqual(await res.json(), { ok: true, forwarded: false });
    assert.match(lines[0], /^moku-proxy heartbeat bbbbbbbbbbbb 2026-09-28 \{.*"screens":820/);
    assert.doesNotMatch(lines[0], new RegExp(DEVICE));  // never the whole device hash in the logs
    const failing = createProxy({ env: { POSTHOG_KEY: 'phc_test' }, fetch: posthog(500).fetch, log: () => {} });
    assert.equal((await failing(beat(DAY))).status, 502);
  });
});

// Security review 2026-10-09 (H2): see events.test.js.
describe('anonymous junk never reaches Redis', () => {
  it('/v1/heartbeat: no limit is counted for a body that is not JSON, has no device or no day', async () => {
    const counted = /** @type {string[]} */ ([]);
    const handle = createProxy({ env: { POSTHOG_KEY: 'phc_test' }, fetch: posthog().fetch, log: () => {},
      allow: async (key) => { counted.push(key); return true; } });
    assert.equal((await handle(new Request('https://relay.example/api/proxy?path=v1/heartbeat', { method: 'POST', body: 'not json' }))).status, 400);
    assert.equal((await handle(beat({ device: 'nope', day: '2026-10-01' }))).status, 400);
    assert.equal((await handle(beat({ device: DEVICE, day: 'yesterday' }))).status, 400);
    assert.deepEqual(counted, []);
  });
});
