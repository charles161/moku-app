import test from 'node:test';
import assert from 'node:assert/strict';
import { companions, defaultCompanion, availableCompanions, momentsFor, awayClips } from './companions.js';
import { turnFor } from './demo-actor.js';
import { cues } from './demo-timeline.js';
import house from './house-data.json' with { type: 'json' };
import { existsSync, readFileSync } from 'node:fs';

test('Moku alone until another companion’s clips are exported', () => {
  assert.deepEqual(availableCompanions().map(({ id }) => id), ['moku']);
  assert.deepEqual(availableCompanions({ tetsu: { clips: false, home: true } }).map(({ id }) => id), ['moku']);
  assert.deepEqual(availableCompanions({ tetsu: { clips: true, home: true } }).map(({ id }) => id), ['moku', 'tetsu']);
  assert.deepEqual(Object.keys(companions), ['moku', 'tetsu'], 'the bunny and the robot (Charles, 2026-10-04: no cat)');
  assert.equal(availableCompanions()[0], defaultCompanion);
});

test('a companion without its home’s renders builds the cottage, in its own name', () => {
  const [, tetsu] = availableCompanions({ tetsu: { clips: true, home: false } });
  assert.equal(tetsu.home.image(150), '/images/house/150.webp');
  assert.equal(tetsu.home.model, true);
  assert.match(tetsu.home.pitch, /Tetsu’s home/);
  const [, own] = availableCompanions({ tetsu: { clips: true, home: true } });
  assert.equal(own.home.image(150), '/images/house/tetsu/150.webp');
  assert.equal(own.home.model, false);
});

test('every home has the cottage’s 24 pieces in its five stages, and every theme the same keys', () => {
  const keys = Object.keys(defaultCompanion.theme).sort();
  for (const companion of Object.values(companions)) {
    assert.equal(companion.home.pieceNames.length, house.pieces, companion.id);
    assert.deepEqual(companion.home.stages.map(({ first }) => first), house.stages.map(({ first }) => first), companion.id);
    assert.deepEqual(Object.keys(companion.theme).sort(), keys, `${companion.id}: switching back must restore every value`);
    assert.deepEqual(Object.keys(companion.moments).sort(), Object.keys(defaultCompanion.moments).sort(), companion.id);
    assert.equal(companion.moments.hello.line, `Hi! I’m ${companion.name}.`);
  }
});

test('each companion introduces itself: a species, a personality, what it builds; only Tetsu claims a talent', () => {
  for (const companion of Object.values(companions)) {
    assert.ok(companion.species && companion.personality && companion.home.builds, companion.id);
  }
  assert.deepEqual(Object.values(companions).filter(({ talent }) => talent).map(({ id }) => id), ['tetsu'], 'Moku’s talents aren’t built yet');
  assert.equal(companions.tetsu.home.hologram(4), '/images/house/tetsu/hologram/stage-4.png');
  const [, tetsu] = availableCompanions({ tetsu: { clips: true, home: false } });
  assert.equal(tetsu.home.hologram, undefined, 'no rocket hologram over a borrowed cottage');
});


test('every clip a companion’s moments name is in its exported manifest', () => {
  for (const companion of Object.values(companions)) {
    const file = new URL(`../public${companion.motion.manifest}`, import.meta.url);
    if (!existsSync(file)) continue;  // not exported yet: the site leaves it out
    const manifest = JSON.parse(readFileSync(file));
    for (const [moment, { clip }] of Object.entries({ ...companion.moments, ...companion.helloMoments })) assert.ok(manifest[clip], `${companion.id}: ${moment} needs ${clip}`);
    for (const mood of companion.moods) assert.ok(manifest[`${mood}-idle`], `${companion.id}: the ${mood} poster`);
  }
});

test('Tetsu scans once a loop: after its hello in the hello loop, in place of the glance in the others', () => {
  const scans = (hello) => cues.filter(({ moment, loops }) => (loops !== 'first' || hello) && (loops !== 'later' || !hello) && momentsFor(companions.tetsu, { hello })[moment].talent === 'scan');
  assert.deepEqual(scans(true).map(({ moment }) => moment), ['slowBlink']);
  assert.deepEqual(scans(false).map(({ moment }) => moment), ['glance']);
  const { seconds, reach, from, to } = companions.tetsu.scanBeam;
  assert.ok(seconds >= 2 && seconds <= 2.5, 'a clear, unhurried sweep');
  assert.ok(reach > 0 && from > to);
  assert.equal(momentsFor(companions.moku, { hello: true }), companions.moku.moments);
});

test('the tab-leave moment can turn every companion sad from any mood, and back, with clips it has', () => {
  for (const companion of Object.values(companions)) {
    const folder = companion.id === 'moku' ? '' : `${companion.id}/`;
    const manifest = JSON.parse(readFileSync(new URL(`../public/motion/${folder}manifest.json`, import.meta.url)));
    for (const clip of awayClips(companion)) assert.ok(manifest[clip], `${companion.id}: ${clip}`);
    for (const mood of companion.moods.filter((each) => each !== 'disappointed')) {
      assert.ok(turnFor(companion.moments, mood, 'disappointed'), `${companion.id}: ${mood} to sad`);
    }
    assert.equal(turnFor(companion.moments, 'disappointed', 'happy').clip, 'disappointed-to-happy', `${companion.id}: the comeback`);
    assert.equal(companion.moments.waitingBlink.mood, 'disappointed');
  }
});

test('every home has a small copy of each render, for the hero’s chip (scripts/house-thumbs.py)', () => {
  for (const companion of availableCompanions({ tetsu: { clips: true, home: true } })) {
    for (let minutes = 0; minutes <= house.goalMinutes; minutes += house.minutesPerPiece) {
      const [full, small] = [companion.home.image(minutes), companion.home.thumb(minutes)];
      assert.ok(existsSync(new URL(`../public${small}`, import.meta.url)), `${companion.id}: ${small}`);
      assert.equal(small.replace('/thumb/', '/'), full);
    }
  }
});
