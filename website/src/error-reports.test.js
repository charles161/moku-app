import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { cleanMessage, ENDPOINT, MAX_PER_PAGE, ownFrame, reportOf, startErrorReports } from './error-reports.js';

// The site's own errors, sent so I hear about them (privacy.html, "This website"): what broke and where in our script,
// never anything else, and nothing from anyone else's script.
const ORIGIN = 'https://hellomoku.com';
const HOME = { origin: ORIGIN, page: '/' };

test('a message keeps an address’s origin and path, on one line, and is never long', () => {
  assert.equal(cleanMessage('Failed to load https://hellomoku.com/motion/moku/wave.mp4?v=3#t=2 (404)'),
    'Failed to load https://hellomoku.com/motion/moku/wave.mp4 (404)');
  assert.equal(cleanMessage('a\nb\t c'), 'a b c');
  assert.equal(cleanMessage('x'.repeat(1000)).length, 300);
  assert.equal(cleanMessage(undefined), '');
});

test('the place is the first frame in our own script, in Chrome, Safari and Firefox', () => {
  const chrome = 'TypeError: x is undefined\n    at play (chrome-extension://abc/inject.js:1:10)\n    at start (https://hellomoku.com/assets/index-Ab12.js:3:4567)';
  assert.deepEqual(ownFrame(chrome, ORIGIN), { file: '/assets/index-Ab12.js', line: 3, col: 4567 });
  assert.deepEqual(ownFrame('start@https://hellomoku.com/assets/live-demo-9f.js:1:200\n', ORIGIN), { file: '/assets/live-demo-9f.js', line: 1, col: 200 });
  assert.equal(ownFrame('at x (https://evil.example/hellomoku.com/a.js:1:1)', ORIGIN), null);
  assert.equal(ownFrame('', ORIGIN), null);
});

test('an error in our script is reported with its name, message, place and page', () => {
  const error = new TypeError('Cannot read properties of null (reading \'play\')');
  error.stack = `TypeError: ${error.message}\n    at play (https://hellomoku.com/assets/index-Ab12.js:3:4567)`;
  assert.deepEqual(reportOf({ kind: 'error', error, message: `Uncaught ${error.message}`, filename: 'https://hellomoku.com/assets/index-Ab12.js', lineno: 3, colno: 4567 }, HOME), {
    kind: 'error', type: 'TypeError', message: 'Cannot read properties of null (reading \'play\')', file: '/assets/index-Ab12.js', line: 3, col: 4567, page: '/',
  });
  // A failed fetch in Safari has no address in its stack: still ours, with no place.
  const fetchFailed = Object.assign(new TypeError('Load failed'), { stack: '' });
  assert.deepEqual(reportOf({ kind: 'rejection', error: fetchFailed }, { origin: ORIGIN, page: '/privacy' }),
    { kind: 'rejection', type: 'TypeError', message: 'Load failed', page: '/privacy' });
});

test('anyone else’s errors are not ours to send', () => {
  const theirs = new Error('boom');
  theirs.stack = 'Error: boom\n    at x (chrome-extension://abcdef/content.js:1:1)';
  assert.equal(reportOf({ kind: 'rejection', error: theirs }, HOME), null);
  assert.equal(reportOf({ kind: 'error', error: theirs, message: 'boom', filename: 'chrome-extension://abcdef/content.js', lineno: 1, colno: 1 }, HOME), null);
  assert.equal(reportOf({ kind: 'error', message: 'Script error.', filename: '' }, HOME), null);  // a cross-origin script
  // Code run from the developer tools, or injected by an extension: no file of ours, frames of no address.
  const injected = Object.assign(new Error('from an extension'), { stack: 'Error: from an extension\n    at <anonymous>:1:41' });
  assert.equal(reportOf({ kind: 'error', error: injected, message: 'Uncaught Error: from an extension', filename: '', lineno: 1, colno: 41 }, HOME), null);
  assert.equal(reportOf({ kind: 'rejection', error: injected }, HOME), null);
  assert.equal(reportOf({ kind: 'rejection', error: Object.assign(new Error('x'), { stack: 'x@debugger eval code:1:1' }) }, HOME), null);
  assert.equal(reportOf({ kind: 'rejection', error: 'just a string' }, HOME), null);
  // A page path that isn't one of ours is "other", never a query.
  assert.equal(reportOf({ kind: 'rejection', error: Object.assign(new Error('x'), { stack: '' }) }, { origin: ORIGIN, page: '/Some Page?x=1' }).page, 'other');
});

test('the page sends each error as a beacon to the relay, five at most', () => {
  const listeners = {};
  const sent = [];
  const win = { location: { origin: ORIGIN, pathname: '/' }, addEventListener: (name, fn) => { listeners[name] = fn; } };
  startErrorReports(win, (url, body) => sent.push([url, JSON.parse(body)]));
  const error = new RangeError('bad frame');
  error.stack = 'RangeError: bad frame\n    at f (https://hellomoku.com/assets/index-Ab12.js:1:2)';
  listeners.error({ message: 'x', filename: '', error: null });  // a cross-origin script: nothing
  listeners.error({ message: '', error: null });  // a resource that didn't load: nothing
  for (let i = 0; i < 8; i++) listeners.unhandledrejection({ reason: error });
  assert.equal(sent.length, MAX_PER_PAGE);
  assert.deepEqual(sent[0], [ENDPOINT, { kind: 'rejection', type: 'RangeError', message: 'bad frame', file: '/assets/index-Ab12.js', line: 1, col: 2, page: '/' }]);
});

test('the content security policy lets the page reach only that endpoint besides itself', () => {
  const config = JSON.parse(readFileSync(new URL('../vercel.json', import.meta.url), 'utf8'));
  const policy = config.headers.flatMap((rule) => rule.headers).find((header) => header.key === 'Content-Security-Policy').value;
  const connect = policy.split(';').map((part) => part.trim()).find((part) => part.startsWith('connect-src ')).split(/\s+/).slice(1);
  assert.deepEqual(connect, ["'self'", 'data:', 'blob:', new URL(ENDPOINT).origin]);
});
