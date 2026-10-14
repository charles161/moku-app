import test from 'node:test';
import assert from 'node:assert/strict';
import { houseProgress } from './house.js';
import house from './house-data.json' with { type: 'json' };

test('a fresh daily plot starts with no pieces and the stakes next', () => {
  const home = houseProgress(0);
  assert.equal(home.built, 0);
  assert.equal(home.percent, 0);
  assert.equal(home.image, '/images/house/000.webp');
  assert.deepEqual(home.next, { name: 'the stakes and string', minutes: 10 });
});

test('a piece only appears after its ten focused minutes', () => {
  assert.equal(houseProgress(39.9).built, 3);
  assert.deepEqual(houseProgress(39.9).next, { name: 'the floor', minutes: 1 });
  assert.equal(houseProgress(40).built, 4);
  assert.equal(houseProgress(40).title, 'The frame');
});

test('construction stages match the native daily house milestones', () => {
  for (const [minutes, title] of [[0, 'The ground'], [40, 'The frame'], [80, 'The walls'], [140, 'The roof'], [180, 'The home']]) {
    assert.equal(houseProgress(minutes).title, title);
  }
});

test('Your day’s example card is true to the house: 3h 12m has just put up the porch', () => {
  const day = houseProgress(3 * 60 + 12);
  assert.equal(day.built, 19);
  assert.equal(house.pieceNames[day.built - 1], 'the porch');
});

test('partial pieces wait for their ten focused minutes', () => {
  const monday = houseProgress(198), tuesday = houseProgress(222);
  assert.equal(monday.percent, 82);
  assert.equal(monday.built, 19);
  assert.equal(monday.image, '/images/house/190.webp');
  assert.deepEqual(monday.next, { name: 'the flower boxes', minutes: 2 });
  assert.equal(tuesday.percent, 92);
  assert.equal(tuesday.built, 22);
  assert.deepEqual(tuesday.next, { name: 'the garden', minutes: 8 });
});

test('four hours finishes one house and additional focus does not start a second', () => {
  assert.equal(houseProgress(239).complete, false);
  const done = houseProgress(240);
  assert.equal(done.built, 24);
  assert.equal(done.percent, 100);
  assert.equal(done.complete, true);
  assert.equal(done.next, null);
  assert.deepEqual(houseProgress(480), done);
});

test('invalid or negative minutes leave an empty plot', () => {
  for (const minutes of [-20, NaN, undefined]) assert.deepEqual(houseProgress(minutes), houseProgress(0));
});
