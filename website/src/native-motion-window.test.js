import test from 'node:test';
import assert from 'node:assert/strict';

// Only the clips the loop needs next: a phone's plan loads three ahead of the ones playing,
// and the tab-leave moment's clips wait for the loop's second round (loading-plan.js).
test('clips load a few ahead of the ones playing, and the ones for later after a round', async (t) => {
  globalThis.window = globalThis;
  globalThis.matchMedia = () => ({ matches: true });  // a phone
  globalThis.document = { documentElement: { dataset: {} } };
  const fetched = [];
  globalThis.fetch = async (url) => {
    if (url.endsWith('manifest.json')) {
      const entries = Object.fromEntries('abcdefgh'.split('').map((name) => [name, { duration: 10, url: `/${name}.webp`, variants: { 320: { url: `/${name}.320.webp` } } }]));
      return { ok: true, json: async () => entries };
    }
    fetched.push(url);
    return { ok: true, blob: async () => new Blob(['x']) };
  };
  t.after(() => { delete globalThis.window; delete globalThis.matchMedia; delete globalThis.document; delete globalThis.fetch; });
  const { loadMotion, later, NativeMotion } = await import(`./native-motion.js?window`);
  const settle = () => new Promise((resolve) => setTimeout(resolve, 10));
  later('/m/manifest.json', ['h']);
  const order = 'abcdefgh'.split('');
  const pending = order.map((name) => loadMotion(name, '/m/manifest.json'));
  await settle();
  assert.deepEqual(fetched, ['/a.320.webp', '/b.320.webp', '/c.320.webp'], 'the first three, in their half size');

  // Playing a clip lets the next one load.
  const art = { querySelector: () => ({}), append() {} };
  const root = { querySelector: () => art, dataset: {}, classList: { add() {}, remove() {} } };
  globalThis.Image = class { setAttribute() {} async decode() {} remove() {} };
  globalThis.URL.createObjectURL = () => 'blob:x';
  globalThis.URL.revokeObjectURL = () => {};
  const motion = new NativeMotion(root, (name) => loadMotion(name, '/m/manifest.json'));
  for (const name of 'abcd') { await motion.play(name); motion.cancel(); }
  await settle();
  assert.deepEqual(fetched.slice(3), ['/d.320.webp', '/e.320.webp', '/f.320.webp', '/g.320.webp']);
  for (const name of 'efg') { await motion.play(name); motion.cancel(); }
  await settle();
  assert.ok(!fetched.includes('/h.320.webp'), 'the clip for later waits for the loop to come round');
  await motion.play('a'); motion.cancel();
  await settle();
  assert.ok(fetched.includes('/h.320.webp'), 'a clip played again: the loop came round');
  await Promise.all(pending);
});
