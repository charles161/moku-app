// The website's /changelog, written from CHANGELOG.md at the repo root so the two never drift apart.
//
//   node scripts/changelog.mjs           writes changelog.html (npm run build runs it first, as prebuild)
//   node scripts/changelog.mjs --check   exits 1 when changelog.html is out of date (src/changelog.test.js checks the same)
//
// Each released version gets an anchor (#0.1.9, #0.1.8 …): the app's "What's new" bubble links to its own. Only what a person
// notices is shown: Added, Changed, Fixed and Privacy. Unreleased work, Removed and Security notes stay in CHANGELOG.md.
// The page is light: one HTML file, its styles inline, no images, and no scripts but the visit counter (src/visits.js)
// and Vercel's page views and speed (src/vercel-insights.js).
//
// Vercel builds with website/ as its root. When CHANGELOG.md isn't there (files outside the root not included), the
// committed changelog.html is kept as it is: commit it whenever CHANGELOG.md changes (the test fails until you do).
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export const SOURCE = fileURLToPath(new URL('../../CHANGELOG.md', import.meta.url));
export const PAGE = fileURLToPath(new URL('../changelog.html', import.meta.url));

/** The sections a person reads, in this order. */
export const SHOWN = ['Added', 'Changed', 'Fixed', 'Privacy'];

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

/**
 * CHANGELOG.md → its releases, newest first: `{ version, date, sections: [{ title, items }] }`, plus the "Before …" notes.
 * Unreleased is left out: it isn't in anyone's hands yet.
 * @param {string} markdown
 */
export function parseChangelog(markdown) {
  /** @type {{ version: string, date: string | null, sections: { title: string, items: string[] }[] }[]} */
  const releases = [];
  /** @type {{ title: string, items: string[] } | null} */
  let before = null;
  /** @type {{ title: string, items: string[] } | null} */
  let section = null;
  /** @type {string[] | null} where the lines being read go (null: nowhere, e.g. the preamble or Unreleased) */
  let items = null;
  for (const line of markdown.split('\n')) {
    const release = line.match(/^## (\d+(?:\.\d+){1,3}) \((\d{4}-\d{2}-\d{2})\)\s*$/);
    if (release) {
      releases.push({ version: release[1], date: release[2], sections: [] });
      section = null; items = null;
      continue;
    }
    const older = line.match(/^## (Before .+?)\s*$/);
    if (older) {
      before = { title: older[1], items: [] };
      section = null; items = before.items;
      continue;
    }
    if (/^## /.test(line)) { section = null; items = null; continue; }  // Unreleased, or anything else
    const heading = line.match(/^### (.+?)\s*$/);
    if (heading) {
      const current = releases.at(-1);
      if (current && !before && SHOWN.includes(heading[1])) {
        section = { title: heading[1], items: [] };
        current.sections.push(section);
        items = section.items;
      } else {
        section = null; items = null;
      }
      continue;
    }
    if (!items) continue;
    if (line.startsWith('- ')) items.push(line.slice(2).trim());
    else if (/^\s+\S/.test(line) && items.length) items[items.length - 1] += ` ${line.trim()}`;
  }
  for (const each of releases) each.sections.sort((a, b) => SHOWN.indexOf(a.title) - SHOWN.indexOf(b.title));
  return { releases, before };
}

const escapeHTML = (/** @type {string} */ text) => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

/** Straight quotes to curly ones, as the rest of the site writes them. */
function curly(/** @type {string} */ text) {
  return text
    .replace(/(^|[\s(\[—–*-])"/g, '$1“').replace(/"/g, '”')
    .replace(/(^|[\s(\[—–*-])'/g, '$1‘').replace(/'/g, '’');
}

/**
 * One line of CHANGELOG.md as HTML: **bold**, `code` and quotes; git references in brackets left out (they mean nothing to
 * a reader).
 * @param {string} text
 */
export function inline(text) {
  const cleaned = text.replace(/\s*\([^()]*`[0-9a-f]{7,40}`[^()]*\)/g, '');
  return cleaned.split(/(`[^`]+`)/).map((part) => {
    if (part.startsWith('`') && part.endsWith('`') && part.length > 1) return `<code>${escapeHTML(part.slice(1, -1))}</code>`;
    return curly(escapeHTML(part)).replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
  }).join('');
}

/** 2026-10-05 → October 5, 2026. */
export function longDate(/** @type {string} */ iso) {
  const [year, month, day] = iso.split('-').map(Number);
  return `${MONTHS[month - 1]} ${day}, ${year}`;
}

/**
 * The whole page.
 * @param {string} markdown
 */
export function renderChangelog(markdown) {
  const { releases, before } = parseChangelog(markdown);
  const list = (/** @type {string[]} */ items) => `<ul>\n${items.map((item) => `            <li>${inline(item)}</li>`).join('\n')}\n          </ul>`;
  const blocks = releases.map(({ version, date, sections }) => {
    const body = sections.length
      ? sections.map(({ title, items }) => `          <h3>${title}</h3>\n          ${list(items)}`).join('\n')
      : '          <p class="quiet">Changes under the hood only.</p>';
    return `        <section class="release" id="${version}" aria-labelledby="v${version}">
          <h2 id="v${version}"><a href="#${version}">${version}</a> <span class="date">${date ? longDate(date) : ''}</span></h2>
${body}
        </section>`;
  });
  if (before?.items.length) {
    blocks.push(`        <section class="release before" aria-labelledby="before">
          <h2 id="before">${escapeHTML(before.title)}</h2>
          ${list(before.items.map((item) => item.replace(/^(\d{4}-\d{2}-\d{2}),/, (_, iso) => `${longDate(iso)},`)))}
        </section>`);
  }
  const latest = releases[0]?.version;
  return `<!doctype html>
<!-- Written by scripts/changelog.mjs from CHANGELOG.md: edit that file, then npm run changelog. -->
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <meta name="theme-color" content="#f7f5ee" />
    <meta name="description" content="What changed in each version of Moku, the little companion for your Mac, newest first.${latest ? ` The latest is ${latest}.` : ''}" />
    <title>Changelog · Moku</title>
    <link rel="icon" type="image/svg+xml" href="/favicon.svg" />
    <!-- The text's font, asked for with the HTML, so it's in place before the page shows and never reflows it. -->
    <link rel="preload" href="/src/fonts/sans-normal.woff2" as="font" type="font/woff2" crossorigin />
    <link rel="stylesheet" href="/src/fonts.css" />
    <style>
      :root { --paper: #f7f5ee; --ink: #30372b; --green: #344633; --muted: #6b6d60; --sage: #d8ddc9; --line: #dcded1; --serif: 'Instrument Serif', 'Instrument Serif fallback', Georgia, serif; }
      * { box-sizing: border-box; }
      html { scroll-padding-top: 24px; }
      body { margin: 0; background: var(--paper); color: var(--ink); font: 17px/1.65 'DM Sans', 'DM Sans fallback', system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
      a { color: var(--green); text-underline-offset: 3px; }
      .wrap { max-width: 720px; margin: 0 auto; padding: 0 24px; }
      header { display: flex; justify-content: space-between; align-items: center; padding: 28px 0; }
      .brand { font: 600 26px/1 'DM Sans', 'DM Sans fallback', sans-serif; letter-spacing: -0.03em; color: var(--ink); text-decoration: none; }
      .brand span { color: #91a47c; }
      .brand .beta { font: 600 11px/1 'DM Sans', 'DM Sans fallback', sans-serif; font-style: normal; letter-spacing: 0.14em; text-transform: uppercase; color: #5f6f4c; border: 1px solid #b9c4a5; border-radius: 999px; padding: 4px 8px 3px; margin-left: 8px; vertical-align: middle; position: relative; top: -4px; }
      header nav a { font-size: 15px; color: var(--muted); text-decoration: none; }
      header nav a:hover { color: var(--ink); }
      .eyebrow { font-size: 12px; font-weight: 600; letter-spacing: 0.16em; color: var(--muted); margin: 40px 0 8px; }
      h1 { font: 400 clamp(44px, 8vw, 68px)/1.02 var(--serif); letter-spacing: -0.01em; margin: 0 0 12px; }
      h1 em { color: #6a7b4e; }
      .intro { color: var(--muted); margin: 0 0 40px; }
      .release { border-top: 1px solid var(--line); padding: 30px 0 8px; }
      .release:target { background: #fffdf7; border: 1px solid var(--line); border-radius: 22px; padding: 26px 28px 10px; margin: 0 -28px 24px; }
      .release h2 { font: 400 36px/1.1 var(--serif); margin: 0 0 4px; display: flex; align-items: baseline; gap: 14px; flex-wrap: wrap; }
      .release h2 a { color: inherit; text-decoration: none; }
      .release h2 a:hover { text-decoration: underline; text-decoration-thickness: 1px; }
      .date { font: 400 15px/1 'DM Sans', 'DM Sans fallback', sans-serif; color: var(--muted); }
      h3 { font-size: 12px; font-weight: 600; letter-spacing: 0.16em; text-transform: uppercase; color: #5f6f4c; margin: 22px 0 4px; }
      p, li { color: #3d4437; }
      ul { padding-left: 22px; margin: 0 0 8px; }
      li { margin: 6px 0; }
      .quiet { color: var(--muted); }
      code { font-size: 15px; background: #eeede3; padding: 1px 6px; border-radius: 6px; }
      footer { border-top: 1px solid var(--line); margin-top: 48px; padding: 26px 0 48px; color: var(--muted); font-size: 14px; display: flex; justify-content: space-between; gap: 16px; flex-wrap: wrap; }
      /* Phones and tablets: every link is a 44 px tap; the extra height is padding that negative margins take back, so nothing moves. */
      @media (pointer: coarse) {
        .brand, header nav a, footer > a { display: inline-block; padding-block: 9px; margin-block: -9px; }
        header nav a { min-width: 44px; text-align: center; padding-block: 10px; margin-block: -10px; }
        footer > a { padding-block: 11px; margin-block: -11px; }
        .release h2 a { display: inline-block; padding-block: 5px; margin-block: -5px; }
      }
      @media (max-width: 520px) { body { font-size: 16px; } .release h2 { font-size: 32px; } .release:target { padding: 22px 20px 8px; margin: 0 -20px 20px; } }
    </style>
    <script type="module" src="/src/visits.js"></script>
    <script type="module" src="/src/vercel-insights.js"></script>
  </head>
  <body>
    <div class="wrap">
      <header><a class="brand" href="/">moku<span>✳</span><em class="beta">beta</em></a><nav><a href="/">Home</a></nav></header>
      <main>
        <div class="eyebrow">CHANGELOG</div>
        <h1>What’s new in <em>Moku.</em></h1>
        <p class="intro">Every version, newest first. Moku updates itself quietly while you’re away, then tells you when there’s something new to see here.</p>
${blocks.join('\n')}
      </main>
      <footer><span>© 2026 Moku · <a href="mailto:hello@hellomoku.com">hello@hellomoku.com</a> · <a href="/privacy">Privacy</a></span><a href="/">Back to Moku</a></footer>
    </div>
  </body>
</html>
`;
}

// Run as a script: write the page, or check it.
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  if (!existsSync(SOURCE)) {
    console.log('changelog: CHANGELOG.md is not here (a build from website/ alone); keeping the committed changelog.html');
    process.exit(0);
  }
  const page = renderChangelog(readFileSync(SOURCE, 'utf8'));
  const current = existsSync(PAGE) ? readFileSync(PAGE, 'utf8') : '';
  if (process.argv.includes('--check')) {
    if (page !== current) {
      console.error('changelog: changelog.html is out of date with CHANGELOG.md. Run: npm run changelog');
      process.exit(1);
    }
    console.log('changelog: changelog.html is up to date');
  } else if (page !== current) {
    writeFileSync(PAGE, page);
    console.log('changelog: wrote changelog.html');
  } else {
    console.log('changelog: changelog.html is up to date');
  }
}
