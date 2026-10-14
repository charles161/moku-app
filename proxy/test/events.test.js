// @ts-check
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { describe, it } from 'node:test';
import { signToken } from '../api/_lib/access.js';
import { cleanEvent, EVENTS } from '../api/_lib/events.js';
import { createProxy } from '../api/_lib/proxy.js';

const DEVICE = 'c'.repeat(64);
const NOW = Date.parse('2026-10-02T10:00:00Z');
const posthog = (status = 200) => {
  /** @type {{ url: string, body: any }[]} */
  const calls = [];
  return { calls, fetch: /** @type {typeof fetch} */ (async (url, init) => { calls.push({ url: String(url), body: JSON.parse(String(init?.body)) }); return new Response('{"status":"Ok"}', { status }); }) };
};
const post = (/** @type {unknown} */ body, /** @type {Record<string, string>} */ headers = {}) => new Request('https://relay.example/api/proxy?path=v1/events', {
  method: 'POST', headers: { 'content-type': 'application/json', 'x-forwarded-for': '5.6.7.8', ...headers }, body: JSON.stringify(body),
});
const relay = (/** @type {Record<string, string>} */ env = { POSTHOG_KEY: 'phc_test', MOKU_TOKEN_SECRET: 'secret' }, ph = posthog()) =>
  ({ ph, handle: createProxy({ env, fetch: ph.fetch, log: () => {}, now: () => NOW }) });

describe('POST /v1/events', () => {
  it('forwards allowed events to PostHog as one batch, keyed by the short device id, with no person profile', async () => {
    const { ph, handle } = relay();
    const res = await handle(post({ device: DEVICE, events: [
      { name: 'app_opened', ts: NOW - 1000, props: { app_version: '0.1.8', first_launch: true, macos: 26, ram_gb: 16, launched_by: 'login' } },
      { name: 'permission_answered', ts: NOW, props: { app_version: '0.1.8', kind: 'screen', granted: false, where: 'welcome' } },
    ] }, { 'x-vercel-ip-country': 'IN' }));
    assert.equal(res.status, 202);
    assert.deepEqual(await res.json(), { ok: true, accepted: 2, dropped: 0, forwarded: true });
    assert.equal(ph.calls.length, 1);
    assert.equal(ph.calls[0].url, 'https://eu.i.posthog.com/batch/');
    const { api_key, batch } = ph.calls[0].body;
    assert.equal(api_key, 'phc_test');
    assert.deepEqual(batch[0], {
      event: 'app_opened', distinct_id: 'cccccccccccc', timestamp: new Date(NOW - 1000).toISOString(),
      properties: { app_version: '0.1.8', first_launch: true, macos: 26, ram_gb: 16, launched_by: 'login', device: 'cccccccccccc', plan: 'none',
        friend: 'none', country: 'IN', $lib: 'moku-app', $process_person_profile: false, $geoip_disable: true },
    });
    assert.deepEqual(batch[1].properties.granted, false);
  });

  it('takes the permissions and the companion on app_opened, and only in their shapes', () => {
    const props = { app_version: '0.1.8', screen_recording: false, accessibility: true, companion: 'tetsu' };
    assert.deepEqual(cleanEvent({ name: 'app_opened', ts: NOW, props }, NOW)?.properties, props);
    const odd = cleanEvent({ name: 'app_opened', ts: NOW, props: { screen_recording: 'no', accessibility: 1, companion: 'Clippy' } }, NOW);
    assert.deepEqual(odd?.properties, {});
  });

  it('takes how the launch before ended on app_opened, as one of two words', () => {
    for (const previous_exit of ['clean', 'unclean']) {
      const props = { app_version: '0.1.12', previous_exit };
      assert.deepEqual(cleanEvent({ name: 'app_opened', ts: NOW, props }, NOW)?.properties, props);
    }
    const odd = cleanEvent({ name: 'app_opened', ts: NOW, props: { app_version: '0.1.12', previous_exit: 'crashed in Safari' } }, NOW);
    assert.deepEqual(odd?.properties, { app_version: '0.1.12' });
  });

  it('takes where Your day opened from and which popover control was used, and only as their fixed words', () => {
    const day = { app_version: '0.1.8', from: 'popover_numbers' };
    assert.deepEqual(cleanEvent({ name: 'day_opened', ts: NOW, props: day }, NOW)?.properties, day);
    const action = { app_version: '0.1.8', action: 'put_back', from: 'menu' };
    assert.deepEqual(cleanEvent({ name: 'popover_action', ts: NOW, props: action }, NOW)?.properties, action);
    const odd = cleanEvent({ name: 'popover_action', ts: NOW, props: { action: 'open_url', from: 'postcard' } }, NOW);
    assert.deepEqual(odd?.properties, {});
    assert.deepEqual(cleanEvent({ name: 'day_opened', ts: NOW, props: { from: 'dock' } }, NOW)?.properties, {});
  });

  it('takes the deeper metrics as fixed words and numbers, and the companion on every event', () => {
    const ok = (/** @type {string} */ name, /** @type {Record<string, unknown>} */ props) =>
      assert.deepEqual(cleanEvent({ name, ts: NOW, props: { app_version: '0.1.9', companion: 'tetsu', ...props } }, NOW)?.properties,
        { app_version: '0.1.9', companion: 'tetsu', ...props }, name);
    ok('companion_changed', { from: 'moku', to: 'tetsu', where: 'welcome' });
    ok('hidden', { by: 'screen_share' });
    ok('shown', { by: 'person', after_seconds: 5400 });
    ok('welcome_step', { step: 'allow_screen' });
    ok('welcome_left', { last_step: 'reads', seconds: 40 });
    ok('trouble', { kind: 'relay_429', count: 3, seconds: 120 });
    ok('drift_step', { step: 'tall' });
    ok('ask_outcome', { outcome: 'within_2_min', seconds: 70 });
    ok('break_suggested', { kind: 'look_away' });
    ok('break', { what: 'started', from: 'popover', after_suggestion: true });
    ok('resume_offered', { after: 'away', already_there: false });
    ok('day_card', { what: 'timed_out', yesterday: false, farewell: false });
    ok('day_closed', { seconds_open: 95, expanded: 2 });
    ok('settings_opened', { tab: 'breaks', how: 'switched' });
    ok('setting_changed', { key: 'drink_every_sec', turned: 'off' });
    ok('app_quit', { uptime_minutes: 600, how: 'logout' });
    // Did it work: Your day loaded, Take me there, a permission's answer, a setting kept or changed back.
    ok('day_loaded', { ms: 340, ok: true });
    ok('resume_used', { came_forward: false, ms: 410 });
    ok('permission_answered', { kind: 'accessibility', granted: true, where: 'settings', seconds: 25 });
    ok('setting_outcome', { key: 'size', outcome: 'changed_back', seconds: 12 });
    // Repeats, frustration and lags.
    ok('repeat', { action: 'take_me_there', count: 3 });
    ok('frustration', { signal: 'hide_after_nudge' });
    ok('launch_speed', { ms: 2300, stand_in: false });
    ok('popover_opened', { from: 'menubar', ms: 180 });
    // Versions and updates.
    ok('update_check', { result: 'error', error: 'signature' });
    ok('update_downloaded', { to: '0.1.9' });
    ok('update_installed', { from: '0.1.8', to: '0.1.9', hours_since_release: 30 });
    ok('update_stuck', { why: 'not_in_applications' });
    ok('whats_new', { what: 'closed', seconds: 12 });
    assert.deepEqual(cleanEvent({ name: 'repeat', ts: NOW, props: { action: 'open_slack', count: 1 } }, NOW)?.properties, {});
    ok('app_opened', { displays: 2, reduce_motion: false, low_power: true });
    ok('day_summary', { days_ago: 1, active_minutes: 410, focused_minutes: 250, hovers: 12, drifts_ask: 1, brain_p95_ms: 1500, memory_mb: 350, core_permille: 5 });
    // Words that aren't on the lists, and numbers out of range, are dropped.
    const odd = cleanEvent({ name: 'trouble', ts: NOW, props: { kind: 'Slack crashed', count: 0, seconds: -1, companion: 'Clippy' } }, NOW);
    assert.deepEqual(odd?.properties, {});
    assert.deepEqual(cleanEvent({ name: 'day_summary', ts: NOW, props: { focused_minutes: 5000, app: 'Xcode' } }, NOW)?.properties, {});
  });

  it('passes an app_error to PostHog as an $exception with level error: its kind, family and number, and its place in our code', async () => {
    const { ph, handle } = relay();
    const res = await handle(post({ device: DEVICE, events: [
      { name: 'app_error', ts: NOW, props: { app_version: '0.1.10', companion: 'moku', kind: 'brain_unreachable', domain: 'url', code: -1004,
        where: 'BrainClient.swift:today', count: 3 } },
      { name: 'app_error', ts: NOW, props: { kind: 'brain_task', domain: 'go', code: 0, where: 'labeler.go:Labeler.enqueue.func1', count: 1 } },
    ] }));
    assert.deepEqual(await res.json(), { ok: true, accepted: 2, dropped: 0, forwarded: true });
    const [app, brain] = ph.calls[0].body.batch;
    assert.equal(app.event, '$exception');
    assert.equal(app.distinct_id, 'cccccccccccc');
    assert.deepEqual(app.properties, {
      app_version: '0.1.10', companion: 'moku', kind: 'brain_unreachable', domain: 'url', code: -1004, where: 'BrainClient.swift:today', count: 3,
      $exception_list: [{ type: 'brain_unreachable', value: 'url -1004', mechanism: { handled: true, synthetic: false, type: 'generic' },
        stacktrace: { type: 'raw', frames: [{ platform: 'custom', lang: 'swift', filename: 'BrainClient.swift', function: 'today', in_app: true, resolved: true }] } }],
      $exception_level: 'error', process: 'Moku',
      device: 'cccccccccccc', plan: 'none', friend: 'none', $lib: 'moku-app', $process_person_profile: false, $geoip_disable: true,
    });
    assert.deepEqual([brain.properties.process, brain.properties.$exception_list[0].stacktrace.frames[0].lang], ['moku-brain', 'go']);
  });

  it('takes an app_error\'s place only when it is a file and a function in code, and its words only from its lists', () => {
    const keep = (/** @type {Record<string, unknown>} */ props) => cleanEvent({ name: 'app_error', ts: NOW, props }, NOW)?.properties;
    assert.deepEqual(keep({ where: 'QuietUpdates.swift:updater', code: 2001, domain: 'sparkle', kind: 'sparkle' }),
      { where: 'QuietUpdates.swift:updater', code: 2001, domain: 'sparkle', kind: 'sparkle' });
    for (const where of ['BrainClient.swift', 'today', '/Users/priya/BrainClient.swift:today', 'Notes.app:open', 'x.swift:open note', 'x.swift:1today']) {
      assert.deepEqual(keep({ where }), {}, where);
    }
    assert.deepEqual(keep({ kind: 'attest_failed', domain: 'other', code: 2 }), { kind: 'attest_failed', domain: 'other', code: 2 });
    assert.deepEqual(keep({ kind: 'Slack crashed', domain: 'NSCocoaErrorDomain', code: 1.5, count: 0 }), {});
  });

  it('takes exactly the events the privacy page lists', () => {
    const page = readFileSync(new URL('../../website/privacy.html', import.meta.url), 'utf8');
    const listed = page.match(/usage-events: ([a-z0-9_ ]+) -->/)?.[1].split(' ') ?? [];
    assert.deepEqual([...listed].sort(), Object.keys(EVENTS).sort());
  });

  it('names the friend and plan from the install token', async () => {
    const { ph, handle } = relay();
    const token = signToken({ sub: 'priya/cccccccccccc', plan: 'tester', exp: 0, iat: NOW }, 'secret');
    await handle(post({ device: DEVICE, events: [{ name: 'day_opened', props: { app_version: '0.1.8' } }] }, { authorization: `Bearer ${token}` }));
    const { properties } = ph.calls[0].body.batch[0];
    assert.deepEqual([properties.plan, properties.friend], ['tester', 'priya']);
  });

  it('lets nothing sensitive through: titles, addresses, screen text and names are dropped wherever they are put', () => {
    const sensitive = ['Q3 board deck — Confidential.key', 'https://mail.google.com/mail/u/0/#inbox', 'Hey, are we still on for tonight?',
      'priya@example.com', 'building Moku', 'WhatsApp', 'step two', '../etc/passwd', 'ABC', '0.1.8 (beta)'];
    for (const [name, shapes] of Object.entries(EVENTS)) {
      for (const key of [...Object.keys(shapes), 'app_version', 'title', 'url', 'text', 'app', 'thread', 'goal']) {
        for (const value of sensitive) {
          const clean = cleanEvent({ name, ts: NOW, props: { [key]: value } }, NOW);
          assert.deepEqual(clean?.properties, {}, `${name}.${key} let ${JSON.stringify(value)} through`);
        }
      }
    }
  });

  it('drops events that are not on the list, and properties of the wrong shape, but keeps the rest', async () => {
    const { ph, handle } = relay();
    const res = await handle(post({ device: DEVICE, events: [
      { name: 'screen_text', props: { text: 'secret' } },
      { name: 'popover_opened', props: { from: 'menubar', app_version: '0.1.8', window_title: 'Inbox (3)' } },
      { name: 'comeback', props: { drift_seconds: 1e9, first_today: 'yes' } },
      'not an event',
    ] }));
    assert.deepEqual(await res.json(), { ok: true, accepted: 2, dropped: 2, forwarded: true });
    const [popover, comeback] = ph.calls[0].body.batch;
    assert.deepEqual([popover.properties.from, popover.properties.app_version, 'window_title' in popover.properties], ['menubar', '0.1.8', false]);
    assert.equal('drift_seconds' in comeback.properties || 'first_today' in comeback.properties, false);
  });

  it('dates events from the app, but not from the far past or the future', () => {
    assert.equal(cleanEvent({ name: 'day_opened', ts: NOW - 60_000 }, NOW)?.at, NOW - 60_000);
    assert.equal(cleanEvent({ name: 'day_opened', ts: NOW - 8 * 86_400_000 }, NOW)?.at, NOW);
    assert.equal(cleanEvent({ name: 'day_opened', ts: NOW + 3_600_000 }, NOW)?.at, NOW);
  });

  it('turns away a bad device or too many events, and only logs when PostHog has no key', async () => {
    const { handle } = relay();
    assert.equal((await handle(post({ device: 'nope', events: [] }))).status, 400);
    assert.equal((await handle(post({ device: DEVICE, events: Array(51).fill({ name: 'day_opened' }) }))).status, 400);
    /** @type {string[]} */
    const lines = [];
    const quiet = createProxy({ env: {}, fetch: posthog().fetch, log: (line) => lines.push(line), now: () => NOW });
    const res = await quiet(post({ device: DEVICE, events: [{ name: 'day_opened' }] }));
    assert.deepEqual(await res.json(), { ok: true, accepted: 1, dropped: 0, forwarded: false });
    assert.match(lines[0], /^moku-proxy events /);
  });
});

describe('GET /get', () => {
  const get = (/** @type {string} */ query, agent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15') =>
    new Request(`https://relay.example/api/proxy?path=get${query}`, { headers: { 'user-agent': agent, 'x-forwarded-for': '9.9.9.9', 'x-vercel-ip-country': 'US' } });

  it('counts a download with where it came from, then redirects to /download', async () => {
    const { ph, handle } = relay();
    const res = await handle(get('&ref=x_launch'));
    assert.equal(res.status, 302);
    assert.equal(res.headers.get('location'), '/download');
    const [event] = ph.calls[0].body.batch;
    assert.equal(event.event, 'download');
    assert.match(event.distinct_id, /^download-[0-9a-f]{12}$/);
    assert.deepEqual({ ref: event.properties.ref, country: event.properties.country }, { ref: 'x_launch', country: 'US' });
  });

  it('calls an odd or missing ref "direct", and redirects bots and link previews without counting them', async () => {
    const { ph, handle } = relay();
    await handle(get('&ref=<script>'));
    assert.equal(ph.calls[0].body.batch[0].properties.ref, 'direct');
    // WhatsApp's and Facebook's real previewers name no bot: hellomoku.com/download shared in a chat isn't a download.
    for (const agent of ['WhatsApp/2.23.20.0 A', 'WhatsApp/2.24.1 i', 'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)', 'curl/8.7.1', 'Slackbot-LinkExpanding 1.0']) {
      const res = await handle(get('&ref=x', agent));
      assert.equal(res.status, 302);
    }
    assert.equal(ph.calls.length, 1);
  });

  it('answers a HEAD (a previewer or a download manager looking first) with the same redirect, uncounted', async () => {
    const { ph, handle } = relay();
    const res = await handle(new Request('https://relay.example/api/proxy?path=get&ref=x', { method: 'HEAD', headers: { 'user-agent': 'Mozilla/5.0 (Macintosh) Safari/605.1.15' } }));
    assert.deepEqual([res.status, res.headers.get('location')], [302, '/download']);
    assert.equal(ph.calls.length, 0);
  });
});

// Security review 2026-10-09 (H2): anonymous junk spent Redis commands before the relay read it. Each Redis command
// costs, and a flood could use up the plan; once Redis fails, every limit falls back to one instance's memory.
describe('anonymous junk never reaches Redis', () => {
  it('/v1/events: no limit is counted for a body that is not JSON, has no device, or is too big', async () => {
    const counted = /** @type {string[]} */ ([]);
    const handle = createProxy({ env: { POSTHOG_KEY: 'phc_test' }, fetch: posthog().fetch, log: () => {}, now: () => NOW,
      allow: async (key) => { counted.push(key); return true; } });
    const raw = (/** @type {string} */ body) => new Request('https://relay.example/api/proxy?path=v1/events', { method: 'POST', headers: { 'x-forwarded-for': '5.6.7.8' }, body });
    assert.equal((await handle(raw('not json'))).status, 400);
    assert.equal((await handle(post({ device: 'nope', events: [] }))).status, 400);
    assert.equal((await handle(post({ device: DEVICE, events: 'x' }))).status, 400);
    assert.equal((await handle(raw('x'.repeat(40 * 1024)))).status, 413);
    assert.deepEqual(counted, []);
    assert.equal((await handle(post({ device: DEVICE, events: [] }))).status, 202);
    assert.deepEqual(counted, ['events-ip:5.6.7.8', `events:${DEVICE}`]);
  });
});
