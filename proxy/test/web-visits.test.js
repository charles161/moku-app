// @ts-check
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { describe, it } from 'node:test';
import { createProxy } from '../api/_lib/proxy.js';
import { cleanVisit, VISIT_EVENTS } from '../api/_lib/web-visits.js';

const NOW = Date.parse('2026-10-09T10:00:00Z');
const VIEW = '0199c8a2-5b40-7a3c-9f21-4d5e6f708192';
const IPHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1';
const relay = (/** @type {Record<string, string>} */ env = { POSTHOG_KEY: 'phc_test' }) => {
  /** @type {{ url: string, body: any }[]} */
  const calls = [];
  /** @type {string[]} */
  const lines = [];
  const fetch = /** @type {typeof globalThis.fetch} */ (async (url, init) => { calls.push({ url: String(url), body: JSON.parse(String(init?.body ?? 'null')) }); return new Response('{"status":"Ok"}'); });
  return { calls, lines, handle: createProxy({ env, fetch, log: (line) => lines.push(line), now: () => NOW }) };
};
const beacon = (/** @type {unknown} */ body, /** @type {Record<string, string>} */ headers = {}) => new Request('https://relay.example/api/proxy?path=v1/web-visit', {
  method: 'POST', body: typeof body === 'string' ? body : JSON.stringify(body),
  headers: { 'content-type': 'text/plain;charset=UTF-8', origin: 'https://hellomoku.com', 'user-agent': IPHONE, 'x-forwarded-for': '203.0.113.9', 'x-vercel-ip-country': 'IN', ...headers },
});
const PAGEVIEW = { event: 'pageview', view: VIEW, page: '/', screen: 'phone', ref: 'reddit', from: 'www.reddit.com' };
const SHARED = {
  $session_id: VIEW, $current_url: 'https://hellomoku.com/', $host: 'hellomoku.com', $pathname: '/', $device_type: 'Mobile', $browser: 'Safari', $os: 'iOS',
  $geoip_country_code: 'IN', $lib: 'moku-web', $process_person_profile: false, $geoip_disable: true,
};

describe('POST /v1/web-visit', () => {
  it('passes a page view to PostHog under its Web analytics names, with the page view\'s own id and nothing about the person', async () => {
    const { calls, handle } = relay();
    const res = await handle(beacon(PAGEVIEW));
    assert.equal(res.status, 202);
    assert.deepEqual(await res.json(), { ok: true, forwarded: true });
    assert.equal(calls[0].url, 'https://eu.i.posthog.com/batch/');
    assert.deepEqual(calls[0].body.batch, [{
      event: '$pageview', distinct_id: `web-${VIEW}`, timestamp: new Date(NOW).toISOString(),
      properties: { ...SHARED, $referrer: 'https://www.reddit.com/', $referring_domain: 'www.reddit.com', utm_source: 'reddit' },
    }]);
    const sent = JSON.stringify(calls[0].body);
    for (const kept of ['203.0.113.9', 'Mozilla', 'iPhone OS 26']) assert.ok(!sent.includes(kept), `${kept} reached PostHog`);
  });

  it('a visit with no referrer is direct; leaving the page carries its time and how far it was read, as PostHog reads them', async () => {
    const { calls, handle } = relay();
    await handle(beacon({ event: 'pageview', view: VIEW, page: '/privacy', screen: 'computer' }, { 'user-agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36' }));
    const view = calls[0].body.batch[0].properties;
    assert.deepEqual([view.$referrer, view.$referring_domain, view.utm_source, view.$device_type, view.$browser, view.$os, view.$pathname], ['$direct', '$direct', undefined, 'Desktop', 'Chrome', 'Mac OS X', '/privacy']);
    await handle(beacon({ event: 'pageleave', view: VIEW, page: '/', screen: 'phone', seconds: 95, visible: 61, scroll: 80 }));
    assert.deepEqual(calls[1].body.batch[0], {
      event: '$pageleave', distinct_id: `web-${VIEW}`, timestamp: new Date(NOW).toISOString(),
      properties: { ...SHARED, $prev_pageview_pathname: '/', $prev_pageview_duration: 95, seconds_visible: 61, $prev_pageview_max_scroll_percentage: 0.8, $prev_pageview_max_content_percentage: 0.8 },
    });
  });

  it('download clicks and companion picks keep their names and their one or two fields', async () => {
    const { calls, handle } = relay();
    await handle(beacon({ event: 'download_clicked', view: VIEW, page: '/', screen: 'phone', where: 'hero' }));
    await handle(beacon({ event: 'companion_picked', view: VIEW, page: '/', screen: 'phone', companion: 'tetsu', where: 'friends' }));
    assert.deepEqual(calls.map((c) => [c.body.batch[0].event, c.body.batch[0].properties.where, c.body.batch[0].properties.companion]),
      [['download_clicked', 'hero', undefined], ['companion_picked', 'friends', 'tetsu']]);
  });

  it('keeps only the allowed events and fields in their shapes', () => {
    assert.equal(cleanVisit({ ...PAGEVIEW, event: 'identify' }), null);
    assert.equal(cleanVisit({ ...PAGEVIEW, event: 'constructor' }), null);
    assert.equal(cleanVisit({ ...PAGEVIEW, view: 'not-a-uuid' }), null);
    assert.equal(cleanVisit({ ...PAGEVIEW, view: '0199c8a2-5b40-4a3c-9f21-4d5e6f708192' }), null);  // a v4: PostHog drops it from sessions
    assert.equal(cleanVisit([PAGEVIEW]), null);
    assert.deepEqual(cleanVisit({
      ...PAGEVIEW, page: '/?email=priya@example.com', screen: 'fridge', ref: 'Priya Sharma', from: 'https://evil.example/path?q=1',
      email: 'priya@example.com', ip: '1.2.3.4', $set: { name: 'Priya' }, distinct_id: 'priya',
    }), { event: 'pageview', view: VIEW, page: '/other', screen: 'computer', fields: {} });
    assert.deepEqual(cleanVisit({ event: 'pageleave', view: VIEW, page: '/', seconds: 999_999, visible: -4, scroll: 120.5 })?.fields, { seconds: 86_400 });
    assert.deepEqual(cleanVisit({ event: 'download_clicked', view: VIEW, where: 'somewhere' })?.fields, {});
    assert.deepEqual(Object.keys(VISIT_EVENTS), ['pageview', 'pageleave', 'download_clicked', 'companion_picked']);
  });

  it('takes exactly the events and fields the privacy page lists', () => {
    const page = readFileSync(new URL('../../website/privacy.html', import.meta.url), 'utf8');
    const listed = page.match(/web-visits: ([a-z0-9_ ()]+) -->/)?.[1] ?? '';
    const events = Object.fromEntries([...listed.matchAll(/([a-z_]+)\(([a-z_ ]*)\)/g)].map(([, name, fields]) => [name, fields.split(' ').filter(Boolean)]));
    assert.deepEqual(events, Object.fromEntries(Object.entries(VISIT_EVENTS).map(([name, fields]) => [name, Object.keys(fields)])));
  });

  it('turns away other sites, bots, big or broken bodies, and too many from one address or in all', async () => {
    const { calls, handle } = relay({ POSTHOG_KEY: 'phc_test', MOKU_WEB_VISITS_PER_DAY: '305' });
    assert.equal((await handle(beacon(PAGEVIEW, { origin: 'https://evil.example' }))).status, 403);
    assert.equal((await handle(new Request('https://relay.example/api/proxy?path=v1/web-visit', { method: 'POST', body: '{}' }))).status, 403);
    assert.equal((await handle(beacon(PAGEVIEW, { 'user-agent': 'Mozilla/5.0 HeadlessChrome/141.0' }))).status, 202);
    assert.equal((await handle(beacon({ ...PAGEVIEW, ref: 'x'.repeat(2000) }))).status, 413);
    assert.equal((await handle(beacon('not json'))).status, 400);
    assert.equal((await handle(beacon({ event: 'pageview' }))).status, 400);
    assert.equal(calls.length, 0);
    const statuses = [];
    for (let i = 0; i < 301; i++) statuses.push((await handle(beacon(PAGEVIEW))).status);
    assert.deepEqual([statuses.slice(0, 300).every((s) => s === 202), statuses[300]], [true, 429]);
    for (let i = 0; i < 5; i++) assert.equal((await handle(beacon(PAGEVIEW, { 'x-forwarded-for': `198.51.100.${i}` }))).status, 202);
    assert.equal((await handle(beacon(PAGEVIEW, { 'x-forwarded-for': '198.51.100.99' }))).status, 429);
    assert.equal(calls.length, 305);
  });

  it('counts in memory, never with a Redis command, even when Redis is set up', async () => {
    const { calls, handle } = relay({ POSTHOG_KEY: 'phc_test', UPSTASH_REDIS_REST_URL: 'https://redis.example', UPSTASH_REDIS_REST_TOKEN: 'secret' });
    assert.equal((await handle(beacon(PAGEVIEW))).status, 202);
    assert.deepEqual(calls.map((c) => c.url), ['https://eu.i.posthog.com/batch/']);
  });

  it('without a PostHog key logs the event instead of sending it', async () => {
    const { calls, lines, handle } = relay({});
    assert.deepEqual(await (await handle(beacon(PAGEVIEW))).json(), { ok: true, forwarded: false });
    assert.equal(calls.length, 0);
    assert.match(lines[0], /^moku-proxy web-visit \{"event":"\$pageview"/);
  });
});
