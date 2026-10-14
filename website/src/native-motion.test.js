import test from 'node:test';
import assert from 'node:assert/strict';
import { NativeMotion } from './native-motion.js';

test('changing a held pose keeps it visible until its replacement is decoded', async (t) => {
  const previousImage = globalThis.Image;
  globalThis.Image = class {
    setAttribute() {}
    async decode() {}
    remove() { this.removed = true; }
  };
  t.after(() => { globalThis.Image = previousImage; });
  const classes = new Set();
  const poster = {};
  const art = { querySelector: () => poster, append: () => {} };
  const root = {
    querySelector: () => art, dataset: {},
    classList: { add: (name) => classes.add(name), remove: (name) => classes.delete(name) },
  };
  const clip = { blob: new Blob(['test']), duration: 10000 };
  let resolveClip;
  const motion = new NativeMotion(root, (name) => name === 'in' ? Promise.resolve(clip) : new Promise((resolve) => { resolveClip = resolve; }));
  t.after(() => motion.cancel());
  await motion.play('in', { hold: true });
  const held = motion.overlay;
  const replacement = motion.play('out');
  assert.equal(motion.overlay, held, 'the held pose survives an uncached next clip');
  assert.ok(classes.has('is-playing'), 'the neutral poster stays hidden');
  assert.ok(!held.removed);
  resolveClip(clip);
  await replacement;
  assert.ok(held.removed);
  assert.notEqual(motion.overlay, held);

  const pending = motion.play('out');
  motion.cancel();
  resolveClip(clip);
  assert.equal(await pending, false, 'a cancelled request cannot restore an old pose');
  assert.equal(motion.overlay, null);
});

test('a clip plays its 320 px copy where the plan says so, and the original where there is none', async () => {
  const { clipFile } = await import('./native-motion.js');
  const entry = { url: '/motion/a.webp?v=1', variants: { 320: { url: '/motion/a.320.webp?v=2' } } };
  assert.equal(clipFile(entry, 'full').url, '/motion/a.webp?v=1');
  assert.equal(clipFile(entry, '320').url, '/motion/a.320.webp?v=2');
  assert.equal(clipFile({ url: '/motion/b.webp' }, '320').url, '/motion/b.webp');
});

test('the close-up plays full size on a phone with a good connection, small on a light plan', async () => {
  const { sizeFor } = await import('./native-motion.js');
  const phone = { clips: '320', light: false }, light = { clips: '320', light: true }, desktop = { clips: 'full', light: false };
  assert.equal(sizeFor('content-to-disappointed', phone), '320');  // the camera's moving: small is enough
  assert.equal(sizeFor('disappointed-idle', phone), 'full');
  assert.equal(sizeFor('content-wave', phone), '320');
  assert.equal(sizeFor('disappointed-idle', light), '320');
  assert.equal(sizeFor('content-wave', desktop), 'full');
});
