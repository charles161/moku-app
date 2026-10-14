import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { houseProgress } from './house.js';

// What the browsers visitors bring need from the site's JavaScript. Vite lowers new syntax but adds no missing methods,
// and the newest headless engines have them all. A visitor on Chrome for macOS (2026-10-07) lost the whole hero to
// `findLastIndex is not a function`: the house, Your day's stages and the companion picker never set up.
const root = new URL('../', import.meta.url);
const scripts = readdirSync(new URL('src/', root)).filter((name) => name.endsWith('.js') && !name.endsWith('.test.js'))
  .map((name) => [`src/${name}`, readFileSync(new URL(`src/${name}`, root), 'utf8')]);

// ES2023 and later, which Safari before 15.4 / 16 and Chrome before 97 / 110 lack.
const tooNew = [/\.findLast(Index)?\(/, /\.to(Sorted|Reversed|Spliced)\(/, /\.with\(\d/, /\bObject\.groupBy\(/, /\bMap\.groupBy\(/, /\bArray\.fromAsync\(/, /\.isWellFormed\(/];

test('the site uses no array or object method newer than the browsers it supports', () => {
  const found = [];
  for (const [file, text] of scripts) {
    text.split('\n').forEach((line, i) => { for (const pattern of tooNew) if (pattern.test(line)) found.push(`${file}:${i + 1} ${line.trim()}`); });
  }
  assert.deepEqual(found, []);
});

test('the house finds its stage on a browser without findLastIndex', () => {
  const descriptor = Object.getOwnPropertyDescriptor(Array.prototype, 'findLastIndex');
  delete Array.prototype.findLastIndex;
  try {
    assert.equal(houseProgress(0).title, 'The ground');
    assert.equal(houseProgress(120).title, 'The walls');
    assert.equal(houseProgress(240).title, 'Home, sweet home.');
  } finally {
    Object.defineProperty(Array.prototype, 'findLastIndex', descriptor);
  }
});
