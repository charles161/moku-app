// @ts-check
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// Every Moku ever shipped checks moku-proxy.vercel.app/updates. On 2026-10-08 two friends' Macs failed every update
// check (Sparkle 2001) while their AI calls to this same host went through: the feed redirected them to
// updates.hellomoku.com, a domain registered on 2026-09-30, and security filters (office firewalls, safe DNS) block
// domains under 30 days old. So the feed and its files are served from this host, which Vercel fetches from R2.
const config = JSON.parse(readFileSync(new URL('../vercel.json', import.meta.url), 'utf8'));

test('the update feed and its files are served from the relay itself, never redirected elsewhere', () => {
  assert.deepEqual(config.redirects.filter((r) => r.source.startsWith('/updates')), []);
  const rewrite = config.rewrites.find((r) => r.source === '/updates/:path*');
  assert.equal(rewrite?.destination, 'https://updates.hellomoku.com/updates/:path*');
});

test('the relay\'s own routes still come first', () => {
  const sources = config.rewrites.map((r) => r.source);
  assert.ok(sources.indexOf('/updates/:path*') > sources.indexOf('/v1/:path*'));
});

// hellomoku.com/download goes through /get (2026-10-09): Vercel answers a method the function doesn't export with 405
// before the relay sees it, so a HEAD (a previewer, a download manager looking first) needs its own export.
test('the function answers HEAD on /get with the redirect', async () => {
  const entry = await import('../api/proxy.js');
  assert.equal(typeof entry.HEAD, 'function');
  const res = await entry.HEAD(new Request('https://relay.example/api/proxy?path=get&ref=x', { method: 'HEAD', headers: { 'user-agent': 'Mozilla/5.0 (Macintosh) Safari/605.1.15' } }));
  assert.deepEqual([res.status, res.headers.get('location')], [302, '/download']);
});
