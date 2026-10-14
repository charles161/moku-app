import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { measured, startVercelInsights } from './vercel-insights.js';

// Vercel's Web Analytics and Speed Insights (privacy.html, "This website"): only on hellomoku.com, never when the
// browser asks not to be tracked, and only after the page has loaded.

/** A page in a browser: its host, its privacy signals, and its load under the test's hand. */
function browser({ hostname = 'hellomoku.com', navigator = {}, readyState = 'loading' } = {}) {
  const listeners = {};
  const win = {
    location: { hostname }, navigator, document: { readyState },
    addEventListener: (name, fn) => { (listeners[name] ??= []).push(fn); },
  };
  let started = 0;
  return {
    win,
    start: () => startVercelInsights(win, () => { started += 1; }),
    load: () => { win.document.readyState = 'complete'; (listeners.load ?? []).forEach((fn) => fn()); },
    started: () => started,
  };
}

test('measured on hellomoku.com and www, never on previews, localhost or other hosts', () => {
  assert.equal(measured(browser().win), true);
  assert.equal(measured(browser({ hostname: 'www.hellomoku.com' }).win), true);
  for (const hostname of ['127.0.0.1', 'localhost', 'hellomoku-8kjeg2hiu-charles161s-projects.vercel.app', 'evil.example']) {
    assert.equal(measured(browser({ hostname }).win), false, hostname);
  }
});

test('nothing when the browser asks not to be tracked (Global Privacy Control or Do Not Track)', () => {
  for (const navigator of [{ globalPrivacyControl: true }, { doNotTrack: '1' }, { doNotTrack: 'yes' }]) {
    const page = browser({ navigator });
    assert.equal(page.start(), false);
    page.load();
    assert.equal(page.started(), 0, JSON.stringify(navigator));
  }
});

test('starts once, after the page has loaded', () => {
  const page = browser();
  assert.equal(page.start(), true);
  assert.equal(page.started(), 0, 'not before the load');
  page.load();
  assert.equal(page.started(), 1);
});

test('starts at once when the page had already loaded', () => {
  const page = browser({ readyState: 'complete' });
  page.start();
  assert.equal(page.started(), 1);
});

test('every page loads it, and the CSP allows its own-domain scripts and beacons', () => {
  const read = (path) => readFileSync(new URL(path, import.meta.url), 'utf8');
  assert.match(read('./main.js'), /import '\.\/vercel-insights\.js';/);
  for (const page of ['../privacy.html', '../changelog.html']) {
    assert.match(read(page), /<script type="module" src="\/src\/vercel-insights\.js"><\/script>/, page);
  }
  const csp = JSON.parse(read('../vercel.json')).headers.flatMap((rule) => rule.headers)
    .find((header) => header.key === 'Content-Security-Policy').value;
  assert.match(csp, /script-src 'self'/);
  assert.match(csp, /connect-src 'self'/);
});
