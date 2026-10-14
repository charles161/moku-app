// @ts-check
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { createProxy } from '../api/_lib/proxy.js';
import { cleanMessage, cleanWebError, family } from '../api/_lib/web-errors.js';

const NOW = Date.parse('2026-10-06T10:00:00Z');
const SAFARI = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15';
const posthog = () => {
  /** @type {{ url: string, body: any }[]} */
  const calls = [];
  return { calls, fetch: /** @type {typeof fetch} */ (async (url, init) => { calls.push({ url: String(url), body: JSON.parse(String(init?.body)) }); return new Response('{"status":"Ok"}'); }) };
};
const relay = (/** @type {Record<string, string>} */ env = { POSTHOG_KEY: 'phc_test' }) => {
  const ph = posthog();
  /** @type {string[]} */
  const lines = [];
  return { ph, lines, handle: createProxy({ env, fetch: ph.fetch, log: (line) => lines.push(line), now: () => NOW }) };
};
const beacon = (/** @type {unknown} */ body, /** @type {Record<string, string>} */ headers = {}) => new Request('https://relay.example/api/proxy?path=v1/web-error', {
  method: 'POST', body: typeof body === 'string' ? body : JSON.stringify(body),
  headers: { 'content-type': 'text/plain;charset=UTF-8', origin: 'https://hellomoku.com', 'user-agent': SAFARI, 'x-forwarded-for': '203.0.113.9', ...headers },
});
const ERROR = { kind: 'error', type: 'TypeError', message: "null is not an object (evaluating 'clip.play')", file: '/assets/index-Ab12.js', line: 3, col: 4567, page: '/' };

describe('POST /v1/web-error', () => {
  it('passes a site error to PostHog as an $exception with level error, a new id, the browser and OS family, and nothing else', async () => {
    const { ph, handle } = relay();
    const res = await handle(beacon(ERROR));
    assert.equal(res.status, 202);
    assert.deepEqual(await res.json(), { ok: true, forwarded: true });
    assert.equal(ph.calls[0].url, 'https://eu.i.posthog.com/batch/');
    const [event] = ph.calls[0].body.batch;
    assert.equal(event.event, '$exception');
    assert.match(event.distinct_id, /^web-[0-9a-f]{12}$/);
    assert.equal(event.timestamp, new Date(NOW).toISOString());
    assert.deepEqual(event.properties, {
      $exception_list: [{ type: 'TypeError', value: "null is not an object (evaluating 'clip.play')", mechanism: { handled: false, synthetic: false, type: 'onerror' },
        stacktrace: { type: 'raw', frames: [{ platform: 'custom', lang: 'javascript', filename: '/assets/index-Ab12.js', lineno: 3, colno: 4567, function: '?', in_app: true }] } }],
      $exception_level: 'error', kind: 'error', page: '/', file: '/assets/index-Ab12.js', line: 3, col: 4567, browser: 'safari', os: 'macos',
      process: 'website', $lib: 'moku-web', $process_person_profile: false, $geoip_disable: true,
    });
    const sent = JSON.stringify(ph.calls[0].body);
    for (const kept of ['203.0.113.9', 'Mozilla', 'Version/26']) assert.ok(!sent.includes(kept), `${kept} reached PostHog`);
    const second = await handle(beacon(ERROR));
    assert.equal(second.status, 202);
    assert.notEqual(ph.calls[1].body.batch[0].distinct_id, event.distinct_id);  // no id ties two errors together
  });

  it('keeps only the allowed fields in their shapes, and a message without query strings or emails', () => {
    assert.deepEqual(cleanWebError({
      ...ERROR, kind: 'rejection', type: 'Not a name!', page: '/privacy?ref=x', file: 'https://evil.example/x.js', cookie: 'a=b', ip: '1.2.3.4',
      message: 'Failed https://hellomoku.com/motion/moku/wave.mp4?v=3&email=priya@example.com for priya@example.com\n(404)',
    }), { kind: 'rejection', type: 'Error', message: 'Failed https://hellomoku.com/motion/moku/wave.mp4 for [email] (404)', page: 'other' });
    assert.equal(cleanWebError({ ...ERROR, file: '/assets/../../etc/passwd.js' })?.file, undefined);
    assert.equal(cleanWebError({ ...ERROR, line: -1, col: 1.5 })?.line, undefined);
    assert.equal(cleanWebError({ message: '' }), null);
    assert.equal(cleanWebError(['x']), null);
    assert.equal(cleanMessage('y'.repeat(900)).length, 300);
  });

  it('names the browser and the system by family only', () => {
    const cases = [
      [SAFARI, 'safari', 'macos'],
      ['Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1', 'safari', 'ios'],
      ['Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0', 'edge', 'windows'],
      ['Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36', 'chrome', 'android'],
      ['Mozilla/5.0 (X11; Linux x86_64; rv:143.0) Gecko/20100101 Firefox/143.0', 'firefox', 'linux'],
      ['Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/141.0 Mobile/15E148 Safari/604.1', 'chrome', 'ios'],
      ['something else', 'other', 'other'],
    ];
    for (const [agent, browser, os] of cases) assert.deepEqual(family(agent), { browser, os }, agent);
  });

  it('turns away other sites, bots, big or broken bodies, and too many from one address or in all', async () => {
    const { ph, handle } = relay({ POSTHOG_KEY: 'phc_test', MOKU_WEB_ERRORS_PER_DAY: '25' });
    assert.equal((await handle(beacon(ERROR, { origin: 'https://evil.example' }))).status, 403);
    assert.equal((await handle(new Request('https://relay.example/api/proxy?path=v1/web-error', { method: 'POST', body: '{}' }))).status, 403);
    assert.equal((await handle(beacon(ERROR, { 'user-agent': 'Mozilla/5.0 HeadlessChrome/141.0' }))).status, 202);
    assert.equal((await handle(beacon({ ...ERROR, message: 'x'.repeat(5000) }))).status, 413);
    assert.equal((await handle(beacon('not json'))).status, 400);
    assert.equal((await handle(beacon({ type: 'TypeError' }))).status, 400);
    assert.equal(ph.calls.length, 0);
    const statuses = [];
    for (let i = 0; i < 21; i++) statuses.push((await handle(beacon(ERROR))).status);
    assert.deepEqual([statuses.slice(0, 20).every((s) => s === 202), statuses[20]], [true, 429]);
    // Another address still gets in, until the day's 25 in all are used.
    for (let i = 0; i < 5; i++) assert.equal((await handle(beacon(ERROR, { 'x-forwarded-for': `198.51.100.${i}` }))).status, 202);
    assert.equal((await handle(beacon(ERROR, { 'x-forwarded-for': '198.51.100.99' }))).status, 429);
    assert.equal(ph.calls.length, 25);
  });

  it('logs the page and the error\'s name only, and without a PostHog key logs the event instead of sending it', async () => {
    const { ph, lines, handle } = relay({});
    assert.deepEqual(await (await handle(beacon(ERROR))).json(), { ok: true, forwarded: false });
    assert.equal(ph.calls.length, 0);
    assert.match(lines[0], /^moku-proxy web-error /);
    const sending = relay();
    await sending.handle(beacon(ERROR));
    assert.deepEqual(sending.lines, ['moku-proxy web-error / TypeError forwarded']);
  });
});
