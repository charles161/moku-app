import test from 'node:test';
import assert from 'node:assert/strict';
import { choosePlan, earlyMbps, mbps, AHEAD, MEASURABLE_BYTES } from './loading-plan.js';

test('a desktop on a good connection loads as it always has', () => {
  const plan = choosePlan({ effectiveType: '4g', downlink: 9 });
  assert.deepEqual({ ...plan }, { clips: 'full', light: false, ahead: Infinity, house3d: 'auto', reason: 'full' });
  assert.equal(choosePlan().clips, 'full', 'nothing known: full, until a download says otherwise');
});

test('a phone gets the half-size clips, a few ahead, and the 3D as before on a good connection', () => {
  const plan = choosePlan({ phone: true, effectiveType: '4g', downlink: 9 });
  assert.equal(plan.clips, '320');
  assert.equal(plan.ahead, AHEAD);
  assert.equal(plan.light, false);
  assert.equal(plan.house3d, 'auto');
});

test('Save-Data or a slow connection: half-size clips, stills first, 3D on a tap', () => {
  for (const connection of [{ saveData: true, effectiveType: '4g', downlink: 10 }, { effectiveType: '3g' }, { effectiveType: '2g' }, { effectiveType: 'slow-2g' }, { effectiveType: '4g', downlink: 1.2 }, { measuredMbps: .4 }]) {
    const plan = choosePlan(connection);
    assert.equal(plan.clips, '320', JSON.stringify(connection));
    assert.equal(plan.light, true, JSON.stringify(connection));
    assert.equal(plan.house3d, 'tap', JSON.stringify(connection));
  }
  assert.equal(choosePlan({ saveData: true }).reason, 'save-data');
});

test('measured from the first downloads, where the browser can’t say', () => {
  assert.equal(mbps(50_000, 1000), .4, '50 KB a second is slow 3G');
  const at = (bytes, start, end) => ({ encodedBodySize: bytes, requestStart: start - 400, responseStart: start, responseEnd: end });
  assert.equal(earlyMbps([at(1000, 10, 20)]), undefined, 'too small to say');
  assert.ok(earlyMbps([at(48_000, 400, 1360)]) < 1, 'the script over a second: slow');
  assert.equal(earlyMbps([at(48_000, 400, 400)]), Infinity, 'in one burst: fast');
  assert.ok(earlyMbps([at(48_000, 400, 1360), at(MEASURABLE_BYTES, 100, 102)]) > 50, 'the best of them counts');
});
