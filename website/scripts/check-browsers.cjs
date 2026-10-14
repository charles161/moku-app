// hellomoku.com in every engine and on every screen, with checks that fail.
//
//   npm run check:browsers                       builds, serves dist/ on 127.0.0.1:5192 with vercel.json's headers, checks, stops
//   node scripts/check-browsers.cjs [url]        checks a running server or the live site (https://hellomoku.com/)
//     --engines chromium,webkit,firefox          any subset (default: all three)
//     --devices desktop,laptop,ipad,ipad-wide,iphone,iphone-se,android
//     --pages /,/privacy,/changelog
//     --dist <dir>                               serves another build instead of dist/ (an older one, to compare)
//     --out <dir>                                writes the frames and the report there instead of review/browsers
//
// Each engine runs in its own headless browser, the three side by side. On each device it opens
// each page fresh (a new profile: empty cache, nothing remembered) and records:
//   - console errors, page errors, CSP violations and failed requests (aborted ones are only noted);
//   - horizontal overflow (the page scrolls sideways, or the layout viewport grows), with the culprits;
//   - text under 11 px (the pretend Mac's own apps are a miniature, so they don't count), and words
//     that run out past their own pill or card;
//   - on touch devices, tap targets under 44 px (inline links in a sentence are exempt, as WCAG has it);
//   - images that don't load, fonts that don't load, and buttons, links and images without a name;
//   - layout shifts after the load event: landmarks' layout boxes (every engine) and, in Chromium,
//     its own layout-shift entries;
// and on the home page:
//   - the hero demo: it plays, a clip animates (WebP decoding), the camera reaches its close-up, then
//     the comeback, and the piece lands;
//   - the tab-leave moment (page visibility): the title, the icon, the cut to the close-up, "You came
//     back" and the camera pulling back;
//   - reduced motion (emulateMedia): switched on while the loop plays, and on a fresh visit: the three
//     stills, no loop, no endless animations, no pinned scroll story; leaving the tab changes only the title;
//   - the house section: its 3D, or its fallback render;
//   - predictable controls: the work tabs, the companion pickers, the friends' cards, pause, the FAQ,
//     "What Moku reads", the house slider and its buttons each do one thing, the same every time;
//     every link resolves; on desktops, Tab reaches every control, visibly, with a name.
// Frame sheets (the hero at its key moments, each section, the stills, the other pages) land in
// review/browsers/<engine>-<device>/, with sheet.png beside them; report.json has every run.
// Any problem exits 1.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { pathToFileURL } = require('node:url');
const { preview, playwright } = require('./preview.cjs');

const args = process.argv.slice(2);
const option = (name) => { const i = args.indexOf(name); return i < 0 ? null : args.splice(i, 2)[1].split(','); };
const only = { engines: option('--engines'), devices: option('--devices'), pages: option('--pages') };
const distDir = option('--dist')?.[0];  // another build to serve, e.g. an older one to compare against
const outDir = option('--out')?.[0];    // where the frames and the report go (default review/browsers)
const given = args.find((arg) => /^https?:/.test(arg));
const PORT = 5192;
// Over the internet (the live site) everything arrives later than from 127.0.0.1: the waits for the
// first clip, the 3D and the stills are this many times longer there.
const PATIENCE = given ? 2.5 : 1;
const output = outDir ? path.resolve(outDir) : path.resolve(__dirname, '../review/browsers');


const ENGINES = ['chromium', 'webkit', 'firefox'];
// Firefox has no isMobile (Playwright): its phones are a small touch screen with a desktop's viewport rules.
const DEVICES = {
  desktop: { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 },
  laptop: { viewport: { width: 1280, height: 720 }, deviceScaleFactor: 1 },
  ipad: { viewport: { width: 820, height: 1180 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true },
  'ipad-wide': { viewport: { width: 1024, height: 768 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true },
  iphone: { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true },
  'iphone-se': { viewport: { width: 375, height: 667 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true },
  android: { viewport: { width: 412, height: 915 }, deviceScaleFactor: 2.625, isMobile: true, hasTouch: true },
};
const PAGES = ['/', '/privacy', '/changelog'];
// The hero plays one kind of work per visit, drawn at random; each device is given one, so a run
// is the same every time and every kind of work plays on a big screen and a small one.
const WORK = { desktop: 'writing', laptop: 'code', ipad: 'study', 'ipad-wide': 'design', iphone: 'writing', 'iphone-se': 'code', android: 'study' };
const MIN_TEXT = 11;
const MIN_TAP = 44;

// Headless Chromium draws WebGL on the CPU (SwiftShader), where the cottage's first frame takes
// seconds; a Mac's Chrome draws it on the GPU, as this does (no window opens).
const launchArgs = { chromium: process.platform === 'darwin' ? ['--enable-gpu', '--use-angle=metal'] : [] };

const engines = ENGINES.filter((name) => !only.engines || only.engines.includes(name));
const devices = Object.keys(DEVICES).filter((name) => !only.devices || only.devices.includes(name));
const pages = PAGES.filter((name) => !only.pages || only.pages.includes(name));

// CHECK_TRACE=1 prints each step as it starts, to find one that hangs.
const trace = (run, step) => { run.step = step; if (process.env.CHECK_TRACE) console.log(`  · ${run.engine} ${run.device} ${run.page}: ${step}`); };
// The longest a run may take; past it the run fails, naming the step it was on, and the next one starts.
const RUN_LIMIT_MS = 300000;
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const short = (url) => { try { const u = new URL(url); return u.pathname + u.search; } catch { return String(url).slice(0, 80); } };
const ABORTED = /ERR_ABORTED|NS_BINDING_ABORTED|cancelled|Load request cancelled/i;

// In every page, before its own scripts: CSP violations, layout shifts, the landmarks at load,
// the hero demo's moments as they happen, and the helpers the checks below call.
function probe() {
  const chk = window.__chk = { csp: [], shifts: [], demo: { clips: [], maxZoom: 0 } };
  const text = (el) => (el.getAttribute?.('aria-label') || el.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 36);
  chk.describe = (el) => {
    if (!el || el.nodeType !== 1) return String(el);
    // Classes that say a state (is-picked, at-hello, on) change as the page plays; a name keeps to the rest.
    const name = (node) => `${node.tagName.toLowerCase()}${node.id ? `#${node.id}` : ''}${[...node.classList].filter((c) => !/^(is-|at-|has-|on$|on-)/.test(c)).slice(0, 2).map((c) => `.${c}`).join('')}`;
    const words = text(el);
    return `${!el.id && el.parentElement && el.parentElement !== document.body ? `${name(el.parentElement)} > ` : ''}${name(el)}${words ? ` "${words}"` : ''}`;
  };
  document.addEventListener('securitypolicyviolation', (event) => {
    chk.csp.push(`${event.violatedDirective} blocked ${event.blockedURI || 'inline'}${event.sourceFile ? ` (${event.sourceFile.split('/').pop()}:${event.lineNumber})` : ''}`);
  });
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) {
        if (!entry.hadRecentInput) chk.shifts.push({ at: Math.round(entry.startTime), value: entry.value, sources: (entry.sources || []).map((source) => chk.describe(source.node)) });
      }
    }).observe({ type: 'layout-shift', buffered: true });
  } catch { /* Only Chromium reports layout shifts; the landmarks cover every engine. */ }

  // Layout boxes, which transforms (the page's own motion) never move.
  chk.landmarks = () => {
    const boxes = {};
    document.querySelectorAll('h1, h2, h3, .button, .desk-frame, .demo-bar, .day-window, .friend-list, .faq-list, .site-footer, main > *').forEach((el, i) => {
      if (!el.getClientRects().length) return;
      let x = 0, y = 0;
      for (let node = el; node; node = node.offsetParent) { x += node.offsetLeft; y += node.offsetTop; }
      boxes[`${i} ${chk.describe(el)}`] = [x, y];
    });
    return boxes;
  };
  // The page as first shown after the load event, its fonts applied: a layout the load event sees
  // a frame before a font lands is never painted (Chromium's own layout-shift entries, below, judge
  // what is painted, font swaps included).
  addEventListener('load', () => {
    chk.loadAt = Math.round(performance.now());
    document.fonts.ready.then(() => requestAnimationFrame(() => requestAnimationFrame(() => { chk.atLoad = chk.landmarks(); })));
  });

  // The hero's moments, frame by frame: the loop running, the close-up, the comeback, the piece landing.
  const watch = () => {
    const root = document.querySelector('.live-demo'), demo = root?.liveDemo;
    if (demo) {
      const d = chk.demo, beat = root.querySelector('.desk')?.dataset.beat;
      if (demo.running && d.startedAt == null) d.startedAt = Math.round(performance.now());
      d.maxZoom = Math.max(d.maxZoom, demo.zoom);
      if (d.closeUpAt == null && demo.zoom >= .99 && beat === 'drift' && !demo.held) d.closeUpAt = demo.elapsed;
      if (d.closeUpAt != null && d.comebackAt == null && beat === 'back' && demo.zoom <= .02) d.comebackAt = demo.elapsed;
      if (d.landedAt == null && root.querySelector('.moku-piece.is-landing')) d.landedAt = demo.elapsed;
      const motion = root.querySelector('.desk-moku')?.dataset.motion;
      if (motion && d.clips.at(-1) !== motion) d.clips.push(motion);
    }
    requestAnimationFrame(watch);
  };
  requestAnimationFrame(watch);

  const shown = (el) => {
    if (!el || !el.getClientRects().length) return false;
    let opacity = 1;
    for (let node = el; node; node = node.parentElement) opacity *= Number(getComputedStyle(node).opacity);
    return getComputedStyle(el).visibility === 'visible' && opacity > .05;
  };
  chk.shown = shown;

  // The page scrolls sideways, or (a phone) the layout viewport grew past the screen.
  chk.overflow = (expected) => {
    const doc = document.scrollingElement || document.documentElement;
    const [x0, y0] = [scrollX, scrollY];
    scrollTo({ left: 99999, top: y0, behavior: 'instant' });
    const scrolled = scrollX;
    scrollTo({ left: x0, top: y0, behavior: 'instant' });
    if (doc.scrollWidth <= doc.clientWidth + 1 && scrolled === 0 && Math.abs(innerWidth - expected) <= 1) return null;
    const width = doc.clientWidth, culprits = [];
    const clipped = (el) => {
      for (let node = el.parentElement; node && node !== document.documentElement; node = node.parentElement) {
        const style = getComputedStyle(node);
        if (style.overflowX !== 'visible' || style.position === 'fixed') return true;
      }
      return false;
    };
    for (const el of document.body.getElementsByTagName('*')) {
      const box = el.getBoundingClientRect();
      if (!box.width || (box.right <= width + 1 && box.left >= -1)) continue;
      if (getComputedStyle(el).position === 'fixed' || clipped(el) || culprits.some(({ node }) => node.contains(el))) continue;
      culprits.push({ node: el, text: `${chk.describe(el)} spans ${Math.round(box.left)}…${Math.round(box.right)}` });
      if (culprits.length >= 5) break;
    }
    return { scrollWidth: doc.scrollWidth, clientWidth: width, innerWidth, scrolled, culprits: culprits.map(({ text: t }) => t) };
  };

  // Text a visitor reads, under `min` px as drawn (font size times any scale on the way).
  chk.smallText = (min) => {
    const skip = '.desk .scene, .desk .menubar, .chip-thumb, .sr-only, script, style, noscript, svg, [hidden]';
    const found = new Map();
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (!/[\p{L}\p{N}]/u.test(node.textContent)) continue;
      const el = node.parentElement;
      // A letter or two in a hidden tile is an icon (Your day's app tiles), not text to read.
      if (node.textContent.trim().length <= 2 && el?.closest('[aria-hidden="true"]')) continue;
      if (!el || el.closest(skip) || !el.getClientRects().length) continue;
      const style = getComputedStyle(el);
      // As drawn: the font size times every scale on the way up (transforms and the scale
      // property), except the demo camera's, which only ever makes text bigger.
      let scale = 1;
      for (let up = el; up; up = up.parentElement) {
        if (up.classList.contains('desk-inner')) continue;
        const own = getComputedStyle(up);
        if (own.transform && own.transform !== 'none') { const m = new DOMMatrix(own.transform); scale *= Math.hypot(m.a, m.b); }
        if (own.scale && own.scale !== 'none') scale *= parseFloat(own.scale);
      }
      const size = parseFloat(style.fontSize) * scale;
      if (size < min - .05) {
        const key = chk.describe(el);
        if (!found.has(key)) found.set(key, Math.round(size * 10) / 10);
      }
    }
    return [...found].map(([el, size]) => `${el}: ${size}px`);
  };

  // Words that run out past their own pill or card (a background that ends before they do; a
  // border alone is a divider, not a box). The pretend Mac's apps and anything that clips are left out.
  chk.spills = () => {
    const out = [];
    for (const el of document.body.getElementsByTagName('*')) {
      if (!el.getClientRects().length || el.closest('.desk .scene, .desk .menubar, [hidden], svg')) continue;
      const style = getComputedStyle(el);
      if (style.display === 'inline' || style.overflowX !== 'visible') continue;
      const painted = style.backgroundColor !== 'rgba(0, 0, 0, 0)' || style.backgroundImage !== 'none';
      if (painted && el.scrollWidth > el.clientWidth + 2) out.push(`${chk.describe(el)}: ${el.scrollWidth} px of content in ${el.clientWidth} px`);
    }
    return out;
  };

  // Controls a finger can press that are smaller than `min` px either way.
  chk.tapTargets = (min) => {
    const out = [];
    for (const el of document.querySelectorAll('a[href], button, summary, input:not([type="hidden"]), select, textarea, [role="button"], [tabindex]:not([tabindex="-1"])')) {
      if (el.disabled || el.closest('[hidden], [inert]') || !shown(el)) continue;
      const style = getComputedStyle(el);
      if (style.pointerEvents === 'none') continue;
      const box = el.getBoundingClientRect();
      if (box.bottom + scrollY < 0 || box.right + scrollX < 0) continue;  // parked off the page (the skip link)
      const parent = el.parentElement;
      if (el.tagName === 'A' && style.display === 'inline' && parent && parent.textContent.trim().length > el.textContent.trim().length + 3) continue;
      if (box.width < min - .5 || box.height < min - .5) out.push(`${chk.describe(el)}: ${Math.round(box.width)}×${Math.round(box.height)}`);
    }
    return out;
  };

  // An accessible name, close to how a screen reader gets one.
  const visibleText = (el) => {
    let words = '';
    for (const node of el.childNodes) {
      if (node.nodeType === 3) words += node.textContent;
      else if (node.nodeType === 1 && node.getAttribute('aria-hidden') !== 'true' && getComputedStyle(node).display !== 'none') words += node.tagName === 'IMG' ? (node.getAttribute('alt') || '') : visibleText(node);
    }
    return words;
  };
  chk.nameOf = (el) => {
    const by = el.getAttribute('aria-labelledby');
    if (by) return by.split(/\s+/).map((id) => document.getElementById(id)?.textContent || '').join(' ').trim();
    if (el.getAttribute('aria-label')) return el.getAttribute('aria-label').trim();
    if (el.tagName === 'IMG') return el.getAttribute('alt');
    if (el.labels?.length) return [...el.labels].map((label) => label.textContent).join(' ').trim();
    return (visibleText(el) || el.getAttribute('title') || '').trim();
  };
  chk.names = () => {
    const out = [];
    for (const el of document.querySelectorAll('a[href], button, summary, input:not([type="hidden"]), select, [role="button"], [role="img"], [role="group"], img')) {
      if (el.closest('[aria-hidden="true"], [hidden]') || !el.getClientRects().length) continue;
      if (el.tagName === 'IMG') { if (!el.hasAttribute('alt')) out.push(`${chk.describe(el)}: no alt`); continue; }
      if (!chk.nameOf(el)) out.push(`${chk.describe(el)}: no accessible name`);
    }
    return out;
  };

  chk.images = () => {
    const out = [];
    for (const img of document.images) {
      if (img.closest('[hidden]') || !img.getClientRects().length || getComputedStyle(img).display === 'none') continue;
      if (img.dataset.nearSrc && !img.getAttribute('src')) { out.push(`${chk.describe(img)}: never asked for ${img.dataset.nearSrc}`); continue; }
      if (!img.getAttribute('src')) continue;
      if (!img.complete) out.push(`${chk.describe(img)}: still loading ${img.currentSrc || img.src}`);
      else if (!img.naturalWidth) out.push(`${chk.describe(img)}: broken ${img.currentSrc || img.src}`);
    }
    return out;
  };

  chk.fonts = () => {
    const faces = [...document.fonts].map((face) => ({ family: face.family.replace(/["']/g, ''), style: face.style, weight: face.weight, status: face.status }));
    const primary = (el) => el && getComputedStyle(el).fontFamily.split(',')[0].replace(/["']/g, '').trim();
    const used = [...new Set([document.body, document.querySelector('h1'), document.querySelector('h1 em'), document.querySelector('p')].map(primary).filter(Boolean))];
    return {
      used,
      notLoaded: used.filter((family) => faces.some((face) => face.family === family) && !faces.some((face) => face.family === family && face.status === 'loaded')),
      failed: faces.filter((face) => face.status === 'error').map((face) => `${face.family} ${face.style} ${face.weight}`),
      loaded: [...new Set(faces.filter((face) => face.status === 'loaded').map((face) => `${face.family} ${face.style} ${face.weight}`))],
    };
  };

  // What Tab should reach: every control that shows.
  chk.focusables = () => [...document.querySelectorAll('a[href], button, summary, input:not([type="hidden"]), select, textarea, [tabindex]')]
    .filter((el) => el.tabIndex >= 0 && !el.disabled && !el.closest('[hidden], [inert]') && el.getClientRects().length && getComputedStyle(el).visibility === 'visible')
    .filter((el) => el.matches('summary') || !el.closest('details:not([open])'))
    .map((el) => chk.describe(el));
  chk.focusInfo = () => {
    const el = document.activeElement;
    if (!el || el === document.body || el === document.documentElement) return null;
    const box = el.getBoundingClientRect(), style = getComputedStyle(el);
    const inView = box.width > 0 && box.height > 0 && box.bottom > 0 && box.right > 0 && box.top < innerHeight && box.left < innerWidth;
    return {
      key: chk.describe(el),
      name: chk.nameOf(el),
      visible: inView && shown(el),
      ring: (style.outlineStyle !== 'none' && parseFloat(style.outlineWidth) > 0) || style.boxShadow !== 'none',
      hidden: Boolean(el.closest('[aria-hidden="true"], [inert]')),
    };
  };
}

// The page told it's hidden or visible, as a tab switch would (a headless page never really is).
const setHidden = (page, hidden) => page.evaluate((h) => {
  Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => (h ? 'hidden' : 'visible') });
  Object.defineProperty(document, 'hidden', { configurable: true, get: () => h });
  document.dispatchEvent(new Event('visibilitychange'));
}, hidden);
const restoreVisibility = (page) => page.evaluate(() => { delete document.visibilityState; delete document.hidden; });
const demoState = (page) => page.evaluate(() => {
  const root = document.querySelector('.live-demo'), demo = root?.liveDemo;
  return demo && { elapsed: demo.elapsed, running: demo.running, zoom: demo.zoom, held: demo.held, scene: demo.scene, companion: demo.companion, line: demo.line, stills: root.classList.contains('shows-stills') };
});
const untilDemo = (page, condition, arg, timeout) => page.waitForFunction(condition, arg, { timeout, polling: 50 }).then(() => true, () => false);
const scrollToY = (page, y) => page.evaluate((top) => scrollTo({ top, left: 0, behavior: 'instant' }), y);

// One run: an engine, a device, a page. Returns its problems, notes, facts and frames.
class Run {
  constructor(engine, device, pagePath) {
    Object.assign(this, { engine, device, page: pagePath, problems: [], notes: [], facts: {}, frames: [] });
  }
  problem(check, detail) { if (!this.problems.some((p) => p.check === check && p.detail === detail)) this.problems.push({ check, detail }); }
  note(check, detail) { if (!this.notes.some((p) => p.check === check && p.detail === detail)) this.notes.push({ check, detail }); }
}

function listen(page, run) {
  const state = { closing: false };
  page.on('console', (message) => {
    if (state.closing || message.type() !== 'error') return;
    const text = message.text();
    // A failed request is reported once, as a failed request.
    if (/^Failed to load resource/.test(text)) return;
    run.problem('console error', text.slice(0, 240));
  });
  page.on('pageerror', (error) => { if (!state.closing) run.problem('page error', String(error?.message ?? error).slice(0, 240)); });
  page.on('requestfailed', (request) => {
    if (state.closing) return;
    const reason = request.failure()?.errorText ?? 'failed';
    if (ABORTED.test(reason)) run.note('aborted request', `${short(request.url())} (${reason})`);
    else run.problem('failed request', `${short(request.url())}: ${reason}`);
  });
  page.on('response', (response) => {
    if (!state.closing && response.status() >= 400) run.problem('failed request', `${short(response.url())}: HTTP ${response.status()}`);
  });
  return state;
}

async function frame(page, run, dir, name, caption, locator) {
  const file = `${String(++run.counter.frames).padStart(2, '0')}-${name}.png`;
  try {
    await (locator ? locator.screenshot({ path: path.join(dir, file), scale: 'css', timeout: 10000 }) : page.screenshot({ path: path.join(dir, file), scale: 'css', timeout: 10000 }));
    run.frames.push({ file, caption: `${run.page} · ${caption}` });
  } catch (error) { run.note('frame', `${name}: ${String(error.message).split('\n')[0]}`); }
}

async function overflow(page, run, when) {
  const wide = await page.evaluate((width) => window.__chk.overflow(width), DEVICES[run.device].viewport.width);
  if (wide) run.problem('horizontal overflow', `${when}: page ${wide.scrollWidth}px wide in ${wide.clientWidth}px (scrolls ${wide.scrolled}px, viewport ${wide.innerWidth}px)${wide.culprits.length ? `; ${wide.culprits.join('; ')}` : ''}`);
}

// Distinct pictures of a locator over a moment: a clip that animates gives more than one.
async function distinctShots(locator, count, gap) {
  const hashes = new Set();
  for (let i = 0; i < count; i++) {
    const shot = await locator.screenshot({ scale: 'css', timeout: 5000 }).catch(() => null);
    if (shot) hashes.add(crypto.createHash('sha1').update(shot).digest('hex'));
    await wait(gap);
  }
  return hashes.size;
}

// Whatever a page has, checked once it has loaded and been scrolled through.
async function staticChecks(page, run, touch) {
  // The site's own floor for phones and tablets (mobile.css); desktops keep their small labels by design, noted.
  for (const issue of await page.evaluate((min) => window.__chk.smallText(min), MIN_TEXT)) (touch ? run.problem : run.note).call(run, 'text under 11 px', issue);
  if (touch) for (const issue of await page.evaluate((min) => window.__chk.tapTargets(min), MIN_TAP)) run.problem('tap target under 44 px', issue);
  for (const issue of await page.evaluate(() => window.__chk.names())) run.problem('no name', issue);
  for (const issue of await page.evaluate(() => window.__chk.spills())) run.problem('text spills out of its box', issue);
  // Images still on their way get a moment.
  await page.waitForFunction(() => [...document.images].every((img) => img.complete || !img.getClientRects().length), null, { timeout: 6000 }).catch(() => {});
  for (const issue of await page.evaluate(() => window.__chk.images())) run.problem('image not loaded', issue);
  const csp = await page.evaluate(() => window.__chk.csp);
  for (const violation of csp) run.problem('CSP violation', violation);
}

async function fontChecks(page, run) {
  await page.evaluate(() => document.fonts.ready.then(() => true));
  const fonts = await page.evaluate(() => window.__chk.fonts());
  run.facts.fonts = fonts;
  for (const family of fonts.notLoaded) run.problem('font not loaded', `${family} is used but never loaded`);
  for (const face of fonts.failed) run.problem('font not loaded', `${face} failed to load`);
}

async function shiftChecks(page, run) {
  const { atLoad, now, shifts, loadAt } = await page.evaluate(() => ({ atLoad: window.__chk.atLoad, now: window.__chk.landmarks(), shifts: window.__chk.shifts, loadAt: window.__chk.loadAt }));
  if (!atLoad) return run.note('layout shift', 'no load event seen');
  for (const [key, [x, y]] of Object.entries(atLoad)) {
    const later = now[key];
    if (later && (Math.abs(later[0] - x) > 2 || Math.abs(later[1] - y) > 2)) run.problem('layout shift after load', `${key.replace(/^\d+ /, '')} moved ${Math.round(later[0] - x)}, ${Math.round(later[1] - y)} px`);
  }
  const after = shifts.filter((shift) => shift.at >= loadAt);
  const score = after.reduce((sum, shift) => sum + shift.value, 0);
  run.facts.layoutShiftAfterLoad = Math.round(score * 10000) / 10000;
  if (score > .001) run.problem('layout shift after load', `Chromium scored ${score.toFixed(4)}: ${[...new Set(after.flatMap((shift) => shift.sources))].slice(0, 4).join('; ')}`);
}

// Scrolls a page through in screens, so lazy pictures load as they would for a reader.
async function scrollThrough(page) {
  const height = await page.evaluate(() => document.scrollingElement.scrollHeight);
  const step = Math.round(page.viewportSize().height * .8);
  for (let y = 0; y < height; y += step) { await scrollToY(page, y); await wait(120); }
  await scrollToY(page, height);
  await wait(400);
}

const press = (locator, touch) => (touch ? locator.tap({ timeout: 5000 }) : locator.click({ timeout: 5000 }));
async function pressOrReport(locator, touch, run, what) {
  try { await press(locator, touch); return true; } catch (error) {
    // Playwright's log says why: what intercepts the pointer, or that it never held still.
    const lines = String(error.message).split('\n');
    const why = lines.filter((line) => /intercepts pointer|not stable|not visible|outside of the viewport|not enabled/.test(line)).at(-1)?.trim();
    run.problem('control', `couldn't press ${what}: ${(why ?? `${lines[0]} (${lines.filter((line) => /^\s+-/.test(line)).slice(-2).map((line) => line.trim()).join(' ')})`).slice(0, 260)}`);
    return false;
  }
}
// True if the hero restarted (a fresh pick) within the next half second.
const restartsWithin = (page, ms = 500) => page.evaluate(async (ms) => {
  const root = document.querySelector('.live-demo');
  let switching = false;
  for (const until = performance.now() + ms; performance.now() < until;) {
    switching ||= root.classList.contains('is-switching');
    await new Promise((resolve) => setTimeout(resolve, 16));
  }
  return switching;
}, ms);

async function checkWorkTabs(page, run, touch) {
  const tabs = page.locator('.work-tabs .work-tab');
  if (!(await tabs.count()) || !(await tabs.first().isVisible())) return run.note('control', 'no work tabs show');
  const ids = await tabs.evaluateAll((nodes) => nodes.map((node) => node.dataset.work));
  const start = (await demoState(page)).scene;
  const pressed = () => page.evaluate(() => ({
    hero: [...document.querySelectorAll('.work-tabs .work-tab[aria-pressed="true"]')].map((tab) => tab.dataset.work).join(),
    day: [...document.querySelectorAll('[data-day-work][aria-pressed="true"]')].map((tab) => tab.dataset.dayWork).join(),
    card: document.querySelector('[data-your-day]')?.dataset.work,
  }));
  for (const id of [...ids.filter((each) => each !== start), start]) {
    const tab = page.locator(`.work-tabs .work-tab[data-work="${id}"]`);
    if (!(await pressOrReport(tab, touch, run, `the ${id} tab`))) continue;
    if (!(await untilDemo(page, (want) => { const root = document.querySelector('.live-demo'); return root.liveDemo.scene === want && !root.classList.contains('is-switching'); }, id, 4000))) {
      run.problem('control', `the ${id} tab: the demo never showed ${id}`);
      continue;
    }
    const state = await pressed();
    if (state.hero !== id) run.problem('control', `the ${id} tab: the hero's tabs say ${state.hero || 'none'} is picked`);
    if (state.day !== id || state.card !== id) run.problem('control', `the ${id} tab: Your day shows ${state.card} (its tabs: ${state.day || 'none'})`);
    await press(tab, touch).catch(() => {});
    if (await restartsWithin(page)) run.problem('control', `the ${id} tab pressed again restarted the demo`);
  }
  // Your day's own tabs pick the hero's work too.
  const other = ids.find((id) => id !== start) ?? start;
  const dayTab = page.locator(`[data-day-work="${other}"]`);
  if (await pressOrReport(dayTab, touch, run, `Your day's ${other} tab`)) {
    if (!(await untilDemo(page, (want) => document.querySelector('.live-demo').liveDemo.scene === want, other, 4000))) run.problem('control', `Your day's ${other} tab didn't pick ${other} in the hero`);
    const state = await pressed();
    if (state.hero !== other || state.day !== other) run.problem('control', `Your day's ${other} tab: hero ${state.hero}, day ${state.day}`);
  }
  await page.locator(`.work-tabs .work-tab[data-work="${start}"]`).evaluate((tab) => tab.click());
  await untilDemo(page, (want) => document.querySelector('.live-demo').liveDemo.scene === want, start, 4000);
}

async function checkCompanions(page, run, touch) {
  const picker = await page.evaluate(() => {
    const visible = (el) => el && !el.hidden && window.__chk.shown(el);
    return visible(document.querySelector('.companion-dock')) ? '.companion-dock .dock-pick' : visible(document.querySelector('.companion-pills')) ? '.companion-pills .companion-pill' : null;
  });
  if (!picker) return run.note('control', 'no companion picker shows');
  const state = () => page.evaluate(() => ({
    pills: [...document.querySelectorAll('.dock-pick[aria-pressed="true"], .companion-pill[aria-pressed="true"]')].map((pill) => pill.dataset.companion),
    page: document.documentElement.dataset.companion ?? 'moku',
    card: [...document.querySelectorAll('.friend.is-picked')].map((card) => card.dataset.friend).join(),
    cardButtons: [...document.querySelectorAll('.friend-pick[aria-pressed="true"]')].map((button) => button.closest('.friend').dataset.friend).join(),
    named: document.querySelector('[data-picked-name]')?.textContent,
  }));
  const settled = (want) => untilDemo(page, (id) => { const root = document.querySelector('.live-demo'); return root.liveDemo.companion === id && !root.classList.contains('is-switching'); }, want, 5000);
  const expect = async (want, what) => {
    if (!(await settled(want))) return run.problem('control', `${what}: the hero never showed ${want}`);
    const now = await state();
    if (now.pills.some((id) => id !== want) || !now.pills.length) run.problem('control', `${what}: pickers pressed ${now.pills.join() || 'none'}`);
    if (now.page !== want || now.card !== want || now.cardButtons !== want) run.problem('control', `${what}: page ${now.page}, friends' card ${now.card}, its button ${now.cardButtons}`);
    if (now.named?.toLowerCase() !== want) run.problem('control', `${what}: "Watch ${now.named} notice a drift"`);
  };
  for (const [id, again] of [['tetsu', false], ['tetsu', true], ['moku', false]]) {
    const pill = page.locator(`${picker}[data-companion="${id}"]`);
    if (!(await pressOrReport(pill, touch, run, `the ${id} picker`))) continue;
    if (again) { if (await restartsWithin(page)) run.problem('control', `the ${id} picker pressed again restarted the demo`); continue; }
    await expect(id, `the ${id} picker`);
  }
  // The friends' cards pick too, and say so.
  for (const id of ['tetsu', 'moku']) {
    const button = page.locator(`.friend[data-friend="${id}"] .friend-pick`);
    if (!(await button.count())) continue;
    if (!(await pressOrReport(button, touch, run, `the ${id} card`))) continue;
    await expect(id, `the ${id} card`);
  }
}

async function checkPause(page, run, touch) {
  const toggle = page.locator('[data-motion-toggle]');
  await page.locator('.live-demo > .desk-frame').scrollIntoViewIfNeeded();
  if (!(await pressOrReport(toggle, touch, run, 'pause'))) return;
  await wait(250);
  let state = await demoState(page);
  const label = async () => toggle.evaluate((node) => [node.textContent.trim(), node.getAttribute('aria-pressed')]);
  let [text, pressedNow] = await label();
  if (state.running || pressedNow !== 'true' || !/Resume/.test(text)) run.problem('control', `pause: running ${state.running}, pressed ${pressedNow}, "${text}"`);
  if (!(await pressOrReport(toggle, touch, run, 'resume'))) return;
  await page.locator('.live-demo > .desk-frame').scrollIntoViewIfNeeded();
  await untilDemo(page, () => document.querySelector('.live-demo').liveDemo.running, null, 3000);
  state = await demoState(page);
  [text, pressedNow] = await label();
  if (!state.running || pressedNow !== 'false' || !/Pause/.test(text)) run.problem('control', `resume: running ${state.running}, pressed ${pressedNow}, "${text}"`);
}

async function checkQuestions(page, run, touch) {
  const count = await page.locator('.faq-list details').count();
  for (let i = 0; i < count; i++) {
    const details = page.locator('.faq-list details').nth(i);
    const summary = details.locator('summary');
    const open = () => details.evaluate((node) => node.open);
    if (await open()) await summary.evaluate((node) => node.click());
    for (const want of [true, false]) {
      if (!(await pressOrReport(summary, touch, run, `question ${i + 1}`))) break;
      await wait(120);
      if ((await open()) !== want) run.problem('control', `question ${i + 1}: pressed, it's ${want ? 'still closed' : 'still open'}`);
    }
    // The keyboard does the same.
    await summary.focus();
    for (const want of [true, false]) {
      await page.keyboard.press('Enter');
      await wait(80);
      if ((await open()) !== want) run.problem('control', `question ${i + 1}: Enter left it ${want ? 'closed' : 'open'}`);
    }
  }
  // "What Moku reads" opens its answer and brings it into view.
  await scrollToY(page, 0);
  const link = page.locator('[data-open-answer]').first();
  if (await link.count()) {
    await page.locator('#what-moku-reads').evaluate((node) => { node.open = false; });
    if (await pressOrReport(link, touch, run, '"What Moku reads"')) {
      // A smooth scroll: it has up to 3 s to arrive.
      const { open, inView } = await page.locator('#what-moku-reads').evaluate(async (node) => {
        const at = () => { const box = node.querySelector('summary').getBoundingClientRect(); return box.top >= -1 && box.bottom <= innerHeight + 1; };
        for (let i = 0; i < 30 && !at(); i++) await new Promise((resolve) => setTimeout(resolve, 100));
        return { open: node.open, inView: at() };
      });
      if (!open || !inView) run.problem('control', `"What Moku reads": answer ${open ? 'open' : 'closed'}, ${inView ? 'in view' : 'out of view'}`);
    }
  }
}

async function checkHouseControls(page, run, touch) {
  const slider = page.locator('#world-progress');
  await slider.scrollIntoViewIfNeeded();
  await slider.focus();
  await page.keyboard.press('End');
  await page.keyboard.press('ArrowLeft');
  await wait(150);
  const after = await page.evaluate(() => ({ value: document.querySelector('#world-progress').value, percent: document.querySelector('#house-percent').textContent, text: document.querySelector('#world-progress').getAttribute('aria-valuetext') }));
  if (after.value !== '230' || after.percent !== '95%' || !/3h 50m/.test(after.text)) run.problem('control', `the house slider: End then ← gave ${after.value}, ${after.percent}, "${after.text}"`);
  await page.keyboard.press('End');
  // Replay: one press starts the build, the next pauses it, the same each time.
  const replay = page.locator('.house-replay');
  const label = () => replay.getAttribute('aria-label');
  const first = await label();
  if (await pressOrReport(replay, touch, run, 'the house replay')) {
    await wait(150);
    const second = await label();
    if (second === first) run.problem('control', `the house replay: its label stayed "${first}"`);
    if (/Pause/.test(second) && await pressOrReport(replay, touch, run, 'the house pause')) {
      await wait(150);
      if ((await label()) !== first) run.problem('control', `the house replay: pausing left "${await label()}"`);
    }
  }
  const light = page.locator('.house-light-toggle');
  if (await light.isVisible()) {
    const before = await light.getAttribute('aria-pressed');
    for (const want of [before === 'true' ? 'false' : 'true', before]) {
      if (!(await pressOrReport(light, touch, run, 'the house lighting'))) break;
      await wait(120);
      const now = await light.getAttribute('aria-pressed');
      if (now !== want) run.problem('control', `the house lighting: pressed, aria-pressed ${now}`);
    }
  }
}

const linkStatus = new Map();
async function checkLinks(page, run) {
  const links = await page.evaluate(() => [...document.querySelectorAll('a[href]')].map((a) => ({ href: a.getAttribute('href'), url: a.href, label: window.__chk.describe(a) })));
  for (const { href, url, label } of links) {
    if (href.startsWith('#')) {
      if (href.length > 1 && !(await page.evaluate((id) => Boolean(document.getElementById(id)), decodeURIComponent(href.slice(1))))) run.problem('link', `${label}: ${href} goes nowhere`);
      continue;
    }
    if (/^mailto:/.test(href)) { if (!/^mailto:[^?]*(\?.+)?$/.test(href)) run.problem('link', `${label}: ${href}`); continue; }
    const target = new URL(url);
    if (target.origin !== new URL(page.url()).origin) continue;
    target.hash = '';
    if (!linkStatus.has(target.href)) linkStatus.set(target.href, page.request.get(target.href, { maxRedirects: 0, timeout: 15000 }).then((response) => response.status(), () => 0));
    const status = await linkStatus.get(target.href);
    if (!status || status >= 400) run.problem('link', `${label}: ${short(target.href)} answers ${status || 'nothing'}`);
  }
}

// Safari's Tab skips links unless its setting says otherwise; Option-Tab reaches everything, as Safari's keyboard users press it.
async function checkKeyboard(page, run) {
  const tab = run.engine === 'webkit' ? 'Alt+Tab' : 'Tab';
  await scrollToY(page, 0);
  // Tab starts from the top of the page, as on a fresh visit (blurring would leave it where focus was).
  await page.evaluate(() => {
    const start = Object.assign(document.createElement('span'), { tabIndex: -1 });
    document.body.prepend(start);
    start.focus({ preventScroll: true });
    start.addEventListener('blur', () => start.remove(), { once: true });
  });
  const stops = [];
  for (let i = 0; i < 160; i++) {
    await page.keyboard.press(tab);
    // Focus scrolls the page (smoothly, here): the stop is judged once it has come to rest.
    const info = await page.evaluate(async () => {
      let last = -1;
      for (let i = 0; i < 60 && scrollY !== last; i++) { last = scrollY; await new Promise((resolve) => setTimeout(resolve, 50)); }
      return window.__chk.focusInfo();
    });
    if (!info) { if (stops.length) break; continue; }
    if (stops.length && info.key === stops[0].key) break;
    stops.push(info);
    if (info.hidden) run.problem('keyboard', `Tab reaches ${info.key}, hidden from screen readers`);
    if (!info.visible) run.problem('keyboard', `Tab reaches ${info.key}, which can't be seen`);
    if (!info.name) run.problem('keyboard', `Tab reaches ${info.key}, with no name`);
    if (!info.ring) run.problem('keyboard', `Tab reaches ${info.key}, with no focus ring`);
  }
  run.facts.tabStops = stops.map((stop) => stop.key);
  const reached = new Set(stops.map((stop) => stop.key));
  for (const key of await page.evaluate(() => window.__chk.focusables())) if (!reached.has(key)) run.problem('keyboard', `Tab never reaches ${key}`);
}

async function checkHero(page, run, dir, timeline) {
  const { CAMERA, PIECE_LANDS } = timeline;
  const inView = await page.evaluate(() => {
    const box = document.querySelector('.live-demo > .desk-frame').getBoundingClientRect();
    return Math.max(0, Math.min(box.bottom, innerHeight) - Math.max(box.top, 0)) / box.height;
  });
  run.facts.demoInViewAtLoad = Math.round(inView * 100) / 100;
  // A phone's visitor scrolls down to it.
  if (inView < .5) await page.locator('.live-demo > .desk-frame').evaluate((node) => node.scrollIntoView({ block: 'center', behavior: 'instant' }));
  if (!(await untilDemo(page, () => document.querySelector('.live-demo')?.liveDemo?.running, null, 15000 * PATIENCE))) {
    run.problem('hero', 'the demo never started playing');
    await frame(page, run, dir, 'hero-not-playing', 'the demo, not playing');
    return false;
  }
  // A clip on screen animates (its WebP decodes frame by frame).
  if (await untilDemo(page, () => document.querySelector('.desk-moku')?.dataset.motion, null, 8000 * PATIENCE)) {
    const clip = await page.evaluate(() => document.querySelector('.desk-moku').dataset.motion);
    const distinct = await distinctShots(page.locator('.desk-moku'), 4, 140);
    run.facts.firstClip = { clip, distinctFrames: distinct };
    if (distinct < 2) run.problem('hero', `the ${clip} clip shows but doesn't animate`);
  } else run.problem('hero', `no clip played in the first ${8 * PATIENCE} s`);

  const at = async (t, name, caption) => {
    if (!(await untilDemo(page, (want) => document.querySelector('.live-demo').liveDemo.elapsed >= want, t, 30000))) {
      run.problem('hero', `the loop never reached ${t} s (${caption})`);
      return false;
    }
    await frame(page, run, dir, name, caption);
    await overflow(page, run, caption);
    return true;
  };
  await at(5.5, 'hero-work', 'the hero, at work');
  if (await at(CAMERA.pushIn[1] + .7, 'hero-close-up', 'the hero, the close-up of the sad face')) {
    const zoom = (await demoState(page)).zoom;
    if (zoom < .99) run.problem('hero', `the camera's close-up: zoom ${zoom.toFixed(2)} at ${(CAMERA.pushIn[1] + .7).toFixed(1)} s`);
  }
  await at(PIECE_LANDS + .5, 'hero-comeback', 'the hero, the comeback and the piece');
  const demo = await page.evaluate(() => window.__chk.demo);
  run.facts.demo = demo;
  if (demo.closeUpAt == null) run.problem('hero', `the camera never reached its close-up (max zoom ${demo.maxZoom.toFixed(2)})`);
  if (demo.comebackAt == null) run.problem('hero', 'the camera never pulled back for the comeback');
  if (demo.landedAt == null) run.problem('hero', 'the piece never landed');

  // The tab-leave moment.
  await setHidden(page, true);
  await wait(1200);
  const away = await page.evaluate(() => ({ title: document.title, icon: document.querySelector('link[rel="icon"]').getAttribute('href'), held: document.querySelector('.live-demo').liveDemo.held, zoom: document.querySelector('.live-demo').liveDemo.zoom }));
  if (!/noticed/.test(away.title)) run.problem('tab-leave', `title while away: "${away.title}"`);
  if (!/sad/.test(away.icon)) run.problem('tab-leave', `icon while away: ${away.icon}`);
  if (!away.held || away.zoom < .99) run.problem('tab-leave', `while away: held ${away.held}, zoom ${away.zoom.toFixed(2)} (the cut to the close-up)`);
  await setHidden(page, false);
  await wait(400);
  const back = await page.evaluate(() => ({ title: document.title, icon: document.querySelector('link[rel="icon"]').getAttribute('href'), line: document.querySelector('[data-line]').textContent, said: document.querySelector('[data-announcer]').textContent }));
  if (/noticed/.test(back.title) || /sad/.test(back.icon)) run.problem('tab-leave', `back: title "${back.title}", icon ${back.icon}`);
  if (!/came back/.test(back.line) || !/came back/.test(back.said)) run.problem('tab-leave', `back: line "${back.line}", announced "${back.said}"`);
  await frame(page, run, dir, 'hero-back-from-tab', `the hero, back from another tab: "${back.line}"`);
  if (!(await untilDemo(page, () => { const d = document.querySelector('.live-demo').liveDemo; return d.zoom <= .02 && !d.held && d.running; }, null, 10000))) run.problem('tab-leave', 'the camera never pulled back after the visitor came back');
  await restoreVisibility(page);
  // Layout shifts, from the load event to here: a visit's first loop and its tab-leave moment.
  await shiftChecks(page, run);

  // Reduced motion, switched on while the loop plays: the three stills, and back.
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await wait(600);
  const reduced = await page.evaluate(() => ({ stills: document.querySelectorAll('.demo-stills:not([hidden]) figure').length, running: document.querySelector('.live-demo').liveDemo.running, pinned: document.documentElement.classList.contains('motion-enabled') }));
  if (reduced.stills !== 3 || reduced.running || reduced.pinned) run.problem('reduced motion', `switched on mid-loop: ${reduced.stills} stills, loop running ${reduced.running}, scroll story ${reduced.pinned ? 'still pinned' : 'released'}`);
  await page.emulateMedia({ reducedMotion: 'no-preference' });
  await page.locator('.live-demo > .desk-frame').scrollIntoViewIfNeeded();
  if (!(await untilDemo(page, () => document.querySelector('.live-demo').liveDemo.running, null, 4000))) run.problem('reduced motion', 'switched off again, the loop never resumed');
  return true;
}

async function checkHouse(page, run) {
  const has3d = await page.evaluate(() => { const canvas = document.createElement('canvas'); return Boolean(canvas.getContext('webgl2') || canvas.getContext('webgl')); });
  await page.waitForFunction(() => document.querySelector('.house-scene')?.classList.contains('has-model'), null, { timeout: (has3d ? 12000 : 3000) * PATIENCE }).catch(() => {});
  const house = await page.evaluate(() => {
    const scene = document.querySelector('.house-scene'), canvas = scene.querySelector('canvas'), image = document.querySelector('#world-image');
    return {
      model: scene.classList.contains('has-model'),
      canvas: canvas ? [canvas.width, canvas.height] : null,
      canvasShown: window.__chk.shown(canvas),
      fallbackShown: window.__chk.shown(image),
      fallbackLoaded: image.complete && image.naturalWidth > 0,
      button: Boolean(scene.querySelector('.house-3d')),
    };
  });
  run.facts.house = { webgl: has3d, ...house };
  const showing3d = house.model && house.canvasShown && house.canvas?.[0] > 0;
  const showingFallback = house.fallbackShown && house.fallbackLoaded;
  if (!showing3d && !showingFallback) run.problem('house', `neither the 3D nor its fallback shows (${JSON.stringify(house)})`);
  if (has3d && !house.model && !house.button) run.problem('house', 'WebGL is there but the 3D cottage never showed');
}

// The sections, a frame each (the house story at its start, middle and end where it pins).
async function sections(page, run, dir) {
  const list = [['friends', '#friends'], ['home', '#world'], ['your-day', '#your-day'], ['questions', '#questions'], ['closing', '.closing'], ['footer', '.site-footer']];
  for (const [name, selector] of list) {
    const box = await page.evaluate((s) => { const el = document.querySelector(s); if (!el) return null; const r = el.getBoundingClientRect(); return { top: r.top + scrollY, height: r.height }; }, selector);
    if (!box) { run.problem('page', `${selector} is missing`); continue; }
    const viewport = page.viewportSize().height;
    if (name === 'home') {
      const pinned = await page.evaluate(() => document.documentElement.classList.contains('motion-enabled') && getComputedStyle(document.querySelector('.world-pin')).position === 'sticky');
      const travel = Math.max(0, box.height - viewport);
      await scrollToY(page, box.top + (pinned ? travel * .1 : 0));
      await wait(500);
      await checkHouse(page, run);
      await wait(400);
      if (pinned && travel > 0) {
        await frame(page, run, dir, 'home-start', 'the house story, starting');
        await scrollToY(page, box.top + travel * .5); await wait(1600);
        await frame(page, run, dir, 'home-middle', 'the house story, halfway');
        await scrollToY(page, box.top + travel * .97); await wait(1600);
        await frame(page, run, dir, 'home-end', 'the house story, the lights on');
      } else await frame(page, run, dir, 'home', 'a daily home');
    } else {
      await scrollToY(page, name === 'footer' ? box.top + box.height : box.top);
      await wait(name === 'friends' ? 1500 : 800);
      await frame(page, run, dir, name, name.replace('-', ' '));
    }
    await overflow(page, run, `at ${name}`);
  }
}

async function checkHome(context, run, dir, url, timeline, touch) {
  const page = await context.newPage();
  const state = listen(page, run);
  await page.addInitScript(probe);
  await page.goto(url, { waitUntil: 'load', timeout: 60000 });
  trace(run, 'fontChecks');
  await fontChecks(page, run);
  trace(run, 'overflow');
  await overflow(page, run, 'at load');
  trace(run, 'checkHero');
  const played = await checkHero(page, run, dir, timeline);
  if (!played) await shiftChecks(page, run);
  if (played) {
    trace(run, 'checkWorkTabs');
    await checkWorkTabs(page, run, touch);
    trace(run, 'checkCompanions');
    await checkCompanions(page, run, touch);
    trace(run, 'checkPause');
    await checkPause(page, run, touch);
  }
  trace(run, 'sections');
  await sections(page, run, dir);
  trace(run, 'checkQuestions');
  await checkQuestions(page, run, touch);
  trace(run, 'checkHouseControls');
  await checkHouseControls(page, run, touch);
  trace(run, 'scrollThrough');
  await scrollThrough(page);
  await scrollToY(page, 0);
  await wait(300);
  trace(run, 'staticChecks');
  await staticChecks(page, run, touch);
  trace(run, 'checkLinks');
  await checkLinks(page, run);
  if (!touch) await checkKeyboard(page, run);
  state.closing = true;
  await page.close();
}

// A fresh visit with reduced motion: the stills, nothing endless, and only the title on a tab switch.
async function checkReduced(context, run, dir, url) {
  const page = await context.newPage();
  const state = listen(page, run);
  await page.addInitScript(probe);
  await page.goto(url, { waitUntil: 'load', timeout: 60000 });
  await wait(1500);
  // The stills' pictures get a moment to arrive.
  await page.waitForFunction(() => [...document.querySelectorAll('.demo-stills figure .desk-moku .moku-art img')].every((img) => img.complete), null, { timeout: 6000 * PATIENCE }).catch(() => {});
  const facts = await page.evaluate(() => {
    const root = document.querySelector('.live-demo'), toggle = document.querySelector('[data-motion-toggle]');
    const figures = [...document.querySelectorAll('.demo-stills:not([hidden]) figure')];
    const endless = document.getAnimations().filter((a) => a.playState === 'running' && a.effect?.getTiming?.().iterations === Infinity).map((a) => window.__chk.describe(a.effect?.target));
    return {
      stills: figures.length,
      stillsLoaded: figures.every((figure) => [...figure.querySelectorAll('.desk-moku .moku-art img')].every((img) => img.complete && img.naturalWidth > 0)),
      running: root.liveDemo?.running, pinned: document.documentElement.classList.contains('motion-enabled'),
      toggle: [toggle?.textContent, toggle?.disabled], endless,
    };
  });
  run.facts.reduced = facts;
  if (facts.stills !== 3 || !facts.stillsLoaded) run.problem('reduced motion', `${facts.stills} stills${facts.stillsLoaded ? '' : ', not all loaded'}`);
  if (facts.running) run.problem('reduced motion', 'the loop plays');
  if (facts.pinned) run.problem('reduced motion', 'the scroll story pins');
  if (facts.toggle[0] !== 'Motion reduced' || !facts.toggle[1]) run.problem('reduced motion', `the toggle says "${facts.toggle[0]}"`);
  for (const target of facts.endless) run.problem('reduced motion', `an endless animation runs on ${target}`);
  await frame(page, run, dir, 'reduced-stills', 'reduced motion: the three stills', page.locator('.live-demo'));
  await setHidden(page, true);
  await wait(400);
  const away = await page.evaluate(() => ({ title: document.title, zoom: document.querySelector('.live-demo').liveDemo.zoom, held: document.querySelector('.live-demo').liveDemo.held }));
  if (!/noticed/.test(away.title) || away.zoom > 0 || away.held) run.problem('reduced motion', `leaving the tab: title "${away.title}", zoom ${away.zoom}, held ${away.held}`);
  await setHidden(page, false);
  await wait(200);
  if (/noticed/.test(await page.title())) run.problem('reduced motion', 'back from the tab, the title still says it noticed');
  await scrollThrough(page);
  const csp = await page.evaluate(() => window.__chk.csp);
  for (const violation of csp) run.problem('CSP violation', violation);
  state.closing = true;
  await page.close();
}

async function checkOther(context, run, dir, url, touch) {
  const page = await context.newPage();
  const state = listen(page, run);
  await page.addInitScript(probe);
  await page.goto(url, { waitUntil: 'load', timeout: 60000 });
  await fontChecks(page, run);
  await overflow(page, run, 'at load');
  const name = run.page.replace(/^\//, '');
  await frame(page, run, dir, name, 'the top');
  await wait(1500);
  await shiftChecks(page, run);
  await scrollThrough(page);
  await frame(page, run, dir, `${name}-end`, 'the end');
  await overflow(page, run, 'scrolled to the end');
  await scrollToY(page, 0);
  await staticChecks(page, run, touch);
  await checkLinks(page, run);
  if (!touch) await checkKeyboard(page, run);
  state.closing = true;
  await page.close();
}

async function checkDevice(browser, engine, device, base, timeline) {
  const spec = DEVICES[device];
  const touch = Boolean(spec.hasTouch);
  const options = { viewport: spec.viewport, deviceScaleFactor: spec.deviceScaleFactor, hasTouch: touch, ...(spec.isMobile && engine !== 'firefox' ? { isMobile: true } : {}) };
  const dir = path.join(output, `${engine}-${device}`);
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  const runs = [], counter = { frames: 0 };
  const attempt = async (pagePath, contextOptions, check) => {
    const run = new Run(engine, device, pagePath);
    run.counter = counter;  // the device's frames are numbered in one sequence
    runs.push(run);
    const context = await browser.newContext({ ...options, ...contextOptions });
    // A check of the live site never reports its own visits' errors to PostHog (error-reports.js), and isn't
    // counted as a visit (visits.js): the errors are this check's to show, and the visitors are people.
    await context.route(/^https:\/\/moku-proxy\.vercel\.app\/v1\/web-(error|visit)$/, (route) => route.fulfill({ status: 204 }));
    const started = Date.now();
    let timer;
    const limit = new Promise((resolve) => { timer = setTimeout(() => resolve('timeout'), RUN_LIMIT_MS); });
    try {
      if (await Promise.race([check(context, run), limit]) === 'timeout') run.problem('check hung', `no answer after ${RUN_LIMIT_MS / 1000} s, during ${run.step ?? 'loading'}`);
    } catch (error) { run.problem('check crashed', `${run.step ? `${run.step}: ` : ''}${String(error.message).split('\n')[0].slice(0, 200)}`); }
    finally { clearTimeout(timer); await context.close().catch(() => {}); }
    run.seconds = Math.round((Date.now() - started) / 1000);
    console.log(`${`${engine} ${device}`.padEnd(20)} ${run.page.padEnd(16)} ${String(run.seconds).padStart(3)} s  ${run.problems.length ? `${run.problems.length} problem${run.problems.length === 1 ? '' : 's'}` : 'ok'}`);
  };
  for (const pagePath of pages) {
    const url = new URL(pagePath, base).href;
    if (pagePath === '/') {
      const work = new URL(url); work.searchParams.set('work', WORK[device]);
      await attempt('/', { reducedMotion: 'no-preference' }, (context, run) => checkHome(context, run, dir, work.href, timeline, touch));
      await attempt('/ (reduced)', { reducedMotion: 'reduce' }, (context, run) => checkReduced(context, run, dir, url));
    } else await attempt(pagePath, {}, (context, run) => checkOther(context, run, dir, url, touch));
  }
  // Each device's runs as they finish, so a long check can be read while it runs.
  fs.writeFileSync(path.join(dir, 'runs.json'), JSON.stringify(runs.map(summary), null, 2));
  return runs;
}

const summary = ({ engine, device, page, seconds, problems, notes, facts, frames }) => ({ engine, device, page, seconds, problems, notes, facts, frames: frames.map((f) => f.file) });

async function contactSheet(browser, engine, device, runs) {
  const dir = path.join(output, `${engine}-${device}`);
  const frames = runs.flatMap((run) => run.frames);
  if (!frames.length) return;
  const narrow = DEVICES[device].viewport.width < 700;
  const escape = (text) => String(text).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
  const problems = runs.flatMap((run) => run.problems.map((p) => `${run.page} · ${p.check}: ${p.detail}`));
  fs.writeFileSync(path.join(dir, 'sheet.html'), `<!doctype html><meta charset="utf-8"><title>${engine} ${device}</title>
<style>body{margin:0;padding:24px;font:13px/1.45 -apple-system,system-ui,sans-serif;background:#1d1f1b;color:#e8e8e0}h1{font-size:18px;margin:0 0 6px}
ul{margin:0 0 18px;padding-left:18px;color:#f0b8a8}.grid{display:flex;flex-wrap:wrap;gap:18px;align-items:flex-start}figure{margin:0;width:${narrow ? 230 : 440}px}
img{width:100%;display:block;border:1px solid #3a3d36;border-radius:4px}figcaption{margin-top:6px;color:#b9bcae}</style>
<h1>${escape(engine)} · ${escape(device)} · ${DEVICES[device].viewport.width}×${DEVICES[device].viewport.height}</h1>
${problems.length ? `<ul>${problems.map((p) => `<li>${escape(p)}</li>`).join('')}</ul>` : '<p>No problems.</p>'}
<div class="grid">${frames.map(({ file, caption }) => `<figure><img src="${file}"><figcaption>${escape(caption)}</figcaption></figure>`).join('')}</div>`);
  const page = await browser.newPage({ viewport: { width: 1900, height: 1000 } });
  await page.goto(pathToFileURL(path.join(dir, 'sheet.html')).href);
  await page.waitForFunction(() => [...document.images].every((img) => img.complete), null, { timeout: 20000 }).catch(() => {});
  await page.screenshot({ path: path.join(dir, 'sheet.png'), fullPage: true });
  await page.close();
}

(async () => {
  const timeline = await import(path.resolve(__dirname, '../src/demo-timeline.js'));
  const server = given ? null : await preview(PORT, distDir && path.resolve(distDir));
  const base = given ?? server.url;
  const pw = playwright();
  fs.mkdirSync(output, { recursive: true });
  console.log(`Checking ${base} in ${engines.join(', ')} on ${devices.join(', ')}: ${pages.join(' ')}\n`);
  const runs = [], notRun = {};
  try {
    await Promise.all(engines.map(async (engine) => {
      // An engine that can't start here is reported as not run, never as passing.
      const browser = await pw[engine].launch({ timeout: 45000, args: launchArgs[engine] }).catch((error) => { notRun[engine] = String(error.message).split('\n').filter((line) => /GFX|error|Error/.test(line)).slice(-1)[0]?.trim() ?? String(error.message).split('\n')[0]; });
      if (!browser) return;
      try {
        for (const device of devices) runs.push(...await checkDevice(browser, engine, device, base, timeline));
      } finally { await browser.close(); }
    }));
    const sheets = await pw.chromium.launch();
    try {
      for (const engine of engines.filter((name) => !notRun[name])) for (const device of devices) await contactSheet(sheets, engine, device, runs.filter((run) => run.engine === engine && run.device === device));
    } finally { await sheets.close(); }
  } finally {
    await server?.close();
  }

  // The table: problems per engine and device, page by page.
  const columns = [...new Set(runs.map((run) => run.page))];
  console.log(`\n${'engine · device'.padEnd(22)}${columns.map((c) => c.padEnd(14)).join('')}`);
  for (const engine of engines) {
    if (notRun[engine]) { console.log(`${engine.padEnd(22)}NOT RUN: it couldn't start on this machine (${notRun[engine].slice(0, 120)})`); continue; }
    for (const device of devices) {
      const cells = columns.map((column) => { const run = runs.find((r) => r.engine === engine && r.device === device && r.page === column); return (run ? (run.problems.length ? String(run.problems.length) : 'ok') : '–').padEnd(14); });
      console.log(`${`${engine} · ${device}`.padEnd(22)}${cells.join('')}`);
    }
  }
  const byProblem = new Map();
  for (const run of runs) for (const { check, detail } of run.problems) {
    const key = `${check}: ${detail}`;
    if (!byProblem.has(key)) byProblem.set(key, []);
    byProblem.get(key).push(`${run.engine}·${run.device}${run.page === '/' ? '' : ` ${run.page}`}`);
  }
  fs.writeFileSync(path.join(output, 'report.json'), JSON.stringify({ at: new Date().toISOString(), base, notRun, runs: runs.map(summary) }, null, 2));
  if (byProblem.size) {
    console.log(`\n${byProblem.size} distinct problem${byProblem.size === 1 ? '' : 's'}:`);
    for (const [key, where] of byProblem) console.log(`  ${key}\n      ${where.join(', ')}`);
    process.exitCode = 1;
  } else console.log('\nNo problems.');
  console.log(`\nFrame sheets and report: ${path.relative(process.cwd(), output)}/<engine>-<device>/sheet.png, report.json`);
})().catch((error) => { console.error(error); process.exitCode = 1; });
