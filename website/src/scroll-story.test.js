import test from 'node:test';
import assert from 'node:assert/strict';
import { storyProgress } from './scroll-story.js';
import { houseStoryProgress } from './house.js';

test('a pinned story progresses over its scroll distance, excluding its screen height', () => {
  assert.equal(storyProgress(100, 100, 1800, 900), 0);
  assert.equal(storyProgress(550, 100, 1800, 900), .5);
  assert.equal(storyProgress(1000, 100, 1800, 900), 1);
  assert.equal(storyProgress(-200, 100, 1800, 900), 0);
  assert.equal(storyProgress(3000, 100, 1800, 900), 1);
});
test('the scroll cottage finishes construction before revealing evening', () => {
  assert.equal(houseStoryProgress(0).minutes, 0);
  assert.equal(houseStoryProgress(.06).minutes, 0);
  assert.equal(houseStoryProgress(.44).minutes, 120);
  assert.equal(houseStoryProgress(.82).minutes, 240);
  assert.equal(houseStoryProgress(.82).evening, 0);
  assert.ok(houseStoryProgress(.91).evening > .4);
  assert.equal(houseStoryProgress(1).evening, 1);
  assert.equal(houseStoryProgress(2).minutes, 240);
});
