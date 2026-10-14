import test from 'node:test';
import assert from 'node:assert/strict';
import { fromOf, MAX_PER_PAGE, optedOut, refOf, screenOf, startVisits, viewId } from './visits.js';
import { cleanVisit } from '../../proxy/api/_lib/web-visits.js';

// Visits counted without cookies (privacy.html, "This website"): a new id each page view, the few fields the relay
// takes (proxy/api/_lib/web-visits.js), and nothing when the browser asks not to be tracked.

/** A page in a browser: its listeners, links and clock under the test's hand. */
function browser({ path = '/', search = '', referrer = '', touch = false, screen = { width: 1512, height: 982 } } = {}) {
  const listeners = { window: {}, document: {} };
  const on = (where) => (name, fn) => { (listeners[where][name] ??= []).push(fn); };
  const links = ['header', 'hero', 'closing', undefined].map((where) => {
    const attributes = { href: '/download' };
    return { dataset: where ? { download: where } : {}, getAttribute: (k) => attributes[k], setAttribute: (k, v) => { attributes[k] = v; } };
  });
  for (const link of links) link.closest = (selector) => (selector === 'a[href^="/download"]' && link.getAttribute('href').startsWith('/download') ? link : null);
  let now = 1000;
  const doc = {
    referrer, visibilityState: 'visible', documentElement: { scrollHeight: 5000 },
    querySelectorAll: (selector) => (selector === 'a[href="/download"]' ? links.filter((l) => l.getAttribute('href') === '/download') : []),
    addEventListener: on('document'),
  };
  const win = {
    location: { pathname: path, search, hostname: 'hellomoku.com' }, document: doc, navigator: {}, screen,
    matchMedia: (query) => ({ matches: query === '(pointer: coarse)' && touch }), scrollY: 0, innerHeight: 1000,
    addEventListener: on('window'),
  };
  const fire = (where, name, event = {}) => (listeners[where][name] ?? []).forEach((fn) => fn(event));
  const beacons = [];
  return {
    win, doc, links, beacons, fire,
    start: () => startVisits(win, (body) => beacons.push(JSON.parse(body)), () => now),
    wait: (ms) => { now += ms; },
  };
}

test('a page view id is a UUIDv7 with the time in front, and new every time', () => {
  const id = viewId(Date.parse('2026-10-09T10:00:00Z'), new Uint8Array([0xab, 0xcd, 0xef, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde]));
  assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.equal(parseInt(id.replace(/-/g, '').slice(0, 12), 16), Date.parse('2026-10-09T10:00:00Z'));
  assert.notEqual(viewId(), viewId());
});

test('the ref is one lower-case word from ?ref= or utm_source, and the referrer only another site\'s host name', () => {
  assert.equal(refOf('?ref=Reddit'), 'reddit');
  assert.equal(refOf('?utm_source=x.com&utm_medium=social'), 'x_com');
  assert.equal(refOf('?ref=42-launch!'), 'launch_');
  assert.equal(refOf('?ref=' + 'a'.repeat(50)).length, 32);
  assert.equal(refOf(''), undefined);
  assert.equal(fromOf('https://www.reddit.com/r/macapps/comments/abc?utm=1', 'hellomoku.com'), 'www.reddit.com');
  assert.equal(fromOf('https://hellomoku.com/privacy', 'hellomoku.com'), undefined);
  assert.equal(fromOf('https://www.hellomoku.com/', 'hellomoku.com'), undefined);
  assert.equal(fromOf('', 'hellomoku.com'), undefined);
  assert.equal(fromOf('android-app://com.google.android.gm/', 'hellomoku.com'), undefined);
});

test('phone, tablet or computer; and the browser\'s own "don\'t track me" is obeyed', () => {
  assert.equal(screenOf(browser().win), 'computer');
  assert.equal(screenOf(browser({ touch: true, screen: { width: 393, height: 852 } }).win), 'phone');
  assert.equal(screenOf(browser({ touch: true, screen: { width: 1032, height: 1376 } }).win), 'tablet');
  assert.equal(optedOut({ globalPrivacyControl: true }), true);
  assert.equal(optedOut({ doNotTrack: '1' }), true);
  assert.equal(optedOut({ doNotTrack: 'unspecified' }), false);
  assert.equal(optedOut({}), false);
});

test('a visit: the page view, a download pressed, a companion picked, then leaving with its time and how far it was read', () => {
  const page = browser({ search: '?ref=reddit', referrer: 'https://www.reddit.com/r/macapps' });
  const track = page.start();
  const [view] = page.beacons;
  assert.match(view.view, /^[0-9a-f]{8}-[0-9a-f]{4}-7/);
  assert.deepEqual(view, { event: 'pageview', view: view.view, page: '/', screen: 'computer', ref: 'reddit', from: 'www.reddit.com' });
  // The download buttons carry the ref on to /download, where the relay counts the download.
  assert.deepEqual(page.links.map((l) => l.getAttribute('href')), Array(4).fill('/download?ref=reddit'));

  page.fire('document', 'click', { target: page.links[1] });
  page.fire('document', 'click', { target: page.links[3] });
  page.fire('document', 'click', { target: { closest: () => null } });
  track('companion_picked', { companion: 'tetsu', where: 'hero' });

  page.wait(20_000);
  page.win.scrollY = 3000;
  page.fire('window', 'scroll');
  page.win.scrollY = 1000;
  page.fire('window', 'scroll');
  page.doc.visibilityState = 'hidden';
  page.fire('document', 'visibilitychange');
  page.wait(60_000);
  page.doc.visibilityState = 'visible';
  page.fire('document', 'visibilitychange');
  page.wait(10_000);
  page.fire('window', 'pagehide');
  page.fire('window', 'pagehide');  // once only

  assert.deepEqual(page.beacons.slice(1).map(({ view: id, page: p, screen, ...rest }) => (assert.equal(id, view.view), rest)), [
    { event: 'download_clicked', where: 'hero' },
    { event: 'download_clicked', where: 'other' },
    { event: 'companion_picked', companion: 'tetsu', where: 'hero' },
    { event: 'pageleave', seconds: 90, visible: 30, scroll: 80 },
  ]);
});

test('no ref: the downloads say they came from the site, and the page view names no source', () => {
  const page = browser({ path: '/privacy' });
  page.start();
  assert.deepEqual(page.beacons[0], { event: 'pageview', view: page.beacons[0].view, page: '/privacy', screen: 'computer' });
  assert.equal(page.links[0].getAttribute('href'), '/download?ref=site');
});

test(`never more than ${MAX_PER_PAGE} beacons a page, and a failing beacon never breaks the page`, () => {
  const page = browser();
  const track = page.start();
  for (let i = 0; i < 50; i++) track('companion_picked', { companion: 'moku', where: 'hero' });
  assert.equal(page.beacons.length, MAX_PER_PAGE);
  const broken = startVisits(browser().win, () => { throw new Error('beacon refused'); }, () => 0);
  assert.doesNotThrow(() => broken('companion_picked', {}));
});

test('every beacon the site sends gets through the relay\'s checks whole: nothing the site sends is dropped there', () => {
  for (const options of [{ search: '?utm_source=x.com', referrer: 'https://t.co/abc' }, { path: '/changelog', touch: true, screen: { width: 393, height: 852 } }]) {
    const page = browser(options);
    const track = page.start();
    page.fire('document', 'click', { target: page.links[0] });
    track('companion_picked', { companion: 'tetsu', where: 'friends' });
    page.wait(5000);
    page.fire('window', 'pagehide');
    assert.equal(page.beacons.length, 4);
    for (const { event, view, page: path, screen, ...fields } of page.beacons) {
      assert.deepEqual(cleanVisit({ event, view, page: path, screen, ...fields }), { event, view, page: path, screen, fields }, event);
    }
  }
});
