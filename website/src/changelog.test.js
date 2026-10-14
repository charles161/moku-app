import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { PAGE, SOURCE, inline, longDate, parseChangelog, renderChangelog } from '../scripts/changelog.mjs';

const SAMPLE = `# Changelog

Preamble that isn't shown, with \`scripts/release.sh\`.

## Unreleased

### Added
- Something not out yet.

## 0.1.9 (2026-10-07)

### Security
- An internal hardening note.

### Fixed
- The popover's "Back to work" <button> works.

### Added
- **What's new after an update**: the companion says so.
  A second line of the same item.

### Removed
- The confetti.

### Privacy
- One more usage note.

## 0.1.8 (2026-10-05)

### Security
- Only internals here.

## Before 0.1.3

- 2026-09-23, **v0** (\`d431760\`, tag \`v0\`): the first Moku.
`;

test('the committed page is CHANGELOG.md as it is now (run npm run changelog after editing it)', { skip: !existsSync(SOURCE) }, () => {
  assert.equal(readFileSync(PAGE, 'utf8'), renderChangelog(readFileSync(SOURCE, 'utf8')));
});

test('every released version is an anchor, newest first; unreleased work is not shown', () => {
  const { releases, before } = parseChangelog(SAMPLE);
  assert.deepEqual(releases.map((r) => r.version), ['0.1.9', '0.1.8']);
  const html = renderChangelog(SAMPLE);
  assert.match(html, /<section class="release" id="0\.1\.9"/);
  assert.match(html, /<a href="#0\.1\.9">0\.1\.9<\/a> <span class="date">October 7, 2026<\/span>/);
  assert.ok(html.indexOf('id="0.1.9"') < html.indexOf('id="0.1.8"'));
  assert.doesNotMatch(html, /not out yet|Unreleased|Preamble/);
  assert.equal(before?.title, 'Before 0.1.3');
});

test('only what a person notices: Added, Changed, Fixed and Privacy, in that order', () => {
  const [latest, older] = parseChangelog(SAMPLE).releases;
  assert.deepEqual(latest.sections.map((s) => s.title), ['Added', 'Fixed', 'Privacy']);
  assert.deepEqual(latest.sections[0].items, ['**What\'s new after an update**: the companion says so. A second line of the same item.']);
  const html = renderChangelog(SAMPLE);
  assert.doesNotMatch(html, /hardening|internals|confetti/);
  assert.deepEqual(older.sections, []);
  assert.match(html, /id="0\.1\.8"[\s\S]*?Changes under the hood only\./);
});

test('markdown becomes plain HTML, escaped, with curly quotes and no git references', () => {
  assert.equal(inline('**Bold** and `code` and "quotes" aren\'t straight'),
    '<strong>Bold</strong> and <code>code</code> and “quotes” aren’t straight');
  assert.equal(inline('**"Today counted"**: a card'), '<strong>“Today counted”</strong>: a card');
  assert.equal(inline('A <button> & more'), 'A &lt;button&gt; &amp; more');
  assert.equal(inline('**v0** (`d431760`, tag `v0`): the first Moku.'), '<strong>v0</strong>: the first Moku.');
  assert.equal(longDate('2026-10-05'), 'October 5, 2026');
  assert.match(renderChangelog(SAMPLE), /<li>September 23, 2026, <strong>v0<\/strong>: the first Moku\.<\/li>/);
});

test('the page is light: no images, no scripts but the visit counters, small, and part of the build', () => {
  const html = renderChangelog(existsSync(SOURCE) ? readFileSync(SOURCE, 'utf8') : SAMPLE);
  assert.doesNotMatch(html, /<img|<video|<picture/);
  assert.deepEqual(html.match(/<script[^>]*>/g), ['<script type="module" src="/src/visits.js">', '<script type="module" src="/src/vercel-insights.js">']);
  assert.ok(Buffer.byteLength(html) < 40_000, `${Buffer.byteLength(html)} bytes`);
  assert.match(readFileSync(new URL('../vite.config.js', import.meta.url), 'utf8'), /changelog: page\('changelog\.html'\)/);
});
