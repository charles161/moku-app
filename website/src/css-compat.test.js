import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';

// What the engines the site supports need from its CSS that no headless browser can show:
// Playwright's WebKit is the newest Safari, but visitors bring older ones (an iPhone on iOS 17).
const root = new URL('../', import.meta.url);
const sheets = readdirSync(new URL('src/', root)).filter((name) => name.endsWith('.css')).map((name) => [`src/${name}`, readFileSync(new URL(`src/${name}`, root), 'utf8')]);
const pages = ['index.html', 'privacy.html', 'changelog.html'].map((name) => [name, readFileSync(new URL(name, root), 'utf8')]);

// Each rule's declarations, by the selector they belong to (comments out, nesting flattened).
function rules(css) {
  const out = [];
  const text = css.replace(/\/\*[\s\S]*?\*\//g, '');
  const stack = [];
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '{') { stack.push(text.slice(start, i).trim()); start = i + 1; }
    else if (text[i] === '}') {
      const body = text.slice(start, i);
      const selector = stack.pop();
      if (body.includes(':')) out.push({ selector, body, within: [...stack] });
      start = i + 1;
    }
  }
  return out;
}

test('backdrop-filter carries its -webkit- twin (Safari before 18 knows only that)', () => {
  const missing = [];
  for (const [file, css] of [...sheets, ...pages]) {
    for (const { selector, body } of rules(css)) {
      if (/(^|[;\s])backdrop-filter\s*:/.test(body) && !/-webkit-backdrop-filter\s*:/.test(body)) missing.push(`${file}: ${selector}`);
    }
  }
  assert.deepEqual(missing, []);
});

test('the pages link stylesheets that the build makes', () => {
  const broken = [];
  for (const [file, html] of pages) {
    for (const [, href] of html.matchAll(/<link rel="stylesheet" href="([^"]+)"/g)) {
      if (!href.startsWith('/src/') || !readdirSync(new URL('src/', root)).includes(href.slice(5))) broken.push(`${file}: ${href}`);
    }
  }
  assert.deepEqual(broken, []);
});

// A tap leaves :hover on what it touched until the next tap elsewhere: a card that lifts or a
// button that darkens under a mouse stays lifted and dark on a phone or an iPad. Hover looks
// belong where there's hover.
test('hover looks only where there is hover', () => {
  const bare = [];
  for (const [file, css] of sheets) {
    for (const { selector, within } of rules(css)) {
      if (/:hover/.test(selector) && !within.some((at) => /@media[^{]*\(hover:\s*hover\)/.test(at))) bare.push(`${file}: ${selector}`);
    }
  }
  assert.deepEqual(bare, []);
});
