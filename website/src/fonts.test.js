import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';

// The headline's serif is subset to the characters the site uses (scripts/subset-fonts.py). New
// copy with a character it doesn't hold would fall back to another font, so it fails here first.
const root = new URL('../', import.meta.url);
const read = (path) => readFileSync(new URL(path, root), 'utf8');
const unescape = (text) => text
  .replace(/&#x([0-9a-f]+);/gi, (_, hex) => String.fromCodePoint(parseInt(hex, 16)))
  .replace(/&#(\d+);/g, (_, dec) => String.fromCodePoint(Number(dec)))
  .replace(/\\u([0-9a-fA-F]{4})/g, (_, hex) => String.fromCodePoint(parseInt(hex, 16)));

test('the subset serif holds every character the copy uses', () => {
  const held = new Set([...read('src/fonts/characters.txt').replace(/\n$/, '')]);
  const files = ['index.html', 'privacy.html', ...readdirSync(new URL('src/', root)).filter((name) => /\.(js|json|css)$/.test(name) && !name.endsWith('.test.js')).map((name) => `src/${name}`)];
  const missing = new Map();
  for (const file of files) {
    for (const character of unescape(read(file))) {
      const code = character.codePointAt(0);
      if (code > 0x7e && code !== 0xfe0f && !held.has(character)) missing.set(character, file);
    }
  }
  assert.deepEqual([...missing].map(([c, file]) => `${c} (U+${c.codePointAt(0).toString(16).toUpperCase()}) in ${file}`), [], 'run python3 website/scripts/subset-fonts.py');
});
