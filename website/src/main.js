import './error-reports.js';  // first: it hears errors from everything after it
import { track } from './visits.js';  // next: the visit counts even if the page breaks after
import './vercel-insights.js';  // Vercel's page views and speed, once the page has loaded
import { initHouse } from './house.js';
import { initPageMotion } from './page-motion.js';
import { initMotionSettings } from './motion-settings.js';
import { initLiveDemo } from './live-demo.js';
import { initFriends } from './friends.js';
import { initYourDay } from './your-day.js';
import { defaultCompanion, availableCompanions, awayClips } from './companions.js';
import { later } from './native-motion.js';
import { loadNear } from './near-images.js';

// The companions this build has clips for (vite.config.js looks in public/). Moku
// is the default, and greets every visit; ?companion=<id> starts with another one.
/* global __COMPANION_FILES__ */
const companions = availableCompanions(typeof __COMPANION_FILES__ === 'undefined' ? {} : __COMPANION_FILES__);
const first = companions.find(({ id }) => id === new URLSearchParams(location.search).get('companion')) ?? defaultCompanion;
// Where clips load a few ahead (a phone, a slow connection), the tab-leave moment's
// clips wait until the loop has come round once (loading-plan.js, native-motion.js).
for (const companion of companions) later(companion.motion.manifest, awayClips(companion));

// A companion's palette, a little different from Moku's (moku-and-friends.md). Every
// companion sets the same keys, so going back to Moku restores it exactly.
function wear(companion) {
  const html = document.documentElement;
  for (const [name, value] of Object.entries(companion.theme)) html.style.setProperty(name, value);
  html.dataset.companion = companion.id;
}
if (first !== defaultCompanion) wear(first);

const settings = initMotionSettings();
const demo = initLiveDemo(document.querySelector('.live-demo'), { settings, companion: first });
const house = initHouse(first === defaultCompanion ? undefined : first);

// Who keeps you company, chosen in the hero or among the friends: the page wears
// its palette, the hero's corner plays it, and its home, its day and the closing
// follow. One choice for the whole page.
let current = first;
const pills = [];
function choose(companion, where = 'hero') {
  if (companion === current) return;
  current = companion;
  track('companion_picked', { companion: companion.id, where });
  wear(companion);
  demo?.setCompanion?.(companion);
  house.setHome(companion.home);
  friends?.setPicked(companion);
  yourDay?.setCompanion(companion);
  pills.forEach((pill) => pill.setAttribute('aria-pressed', String(pill.dataset.companion === companion.id)));
  follow(companion);
}

// The rest of the page that names the companion or its home.
function follow(companion) {
  const one = (selector) => document.querySelector(selector);
  const set = (selector, apply) => { const node = one(selector); if (node) apply(node); };
  set('[data-closing-home]', (node) => { node.textContent = companion.home.name; });
  set('[data-closing-plot]', (node) => { node.src = companion.home.image(10); });
  set('[data-closing-companion]', (node) => { node.src = companion.motion.poster(companion.restingMood); });
  set('[data-closing-art]', (node) => node.setAttribute('aria-label', `${companion.name} waits beside a fresh plot, where ${companion.home.name.toLowerCase()} will go up`));
}
if (first !== defaultCompanion) follow(first);

// The hero's switcher, shown when there's a choice: a face and a name per companion,
// on the page down the screen's left side (a row under the caption on phones).
const pickers = [document.querySelector('.companion-dock'), document.querySelector('.companion-pills')].filter(Boolean);
const choice = pickers.length && companions.length > 1 && demo?.setCompanion;
// The dock's column is in the page from its first paint (index.html), so the screen doesn't jump
// 92 px when this script runs (Chromium: 0.17 of layout shift on desktops); without a choice it goes.
document.querySelector('.live-demo')?.classList.toggle('has-dock', Boolean(choice));
if (choice) {
  for (const box of pickers) {
    const vertical = box.classList.contains('companion-dock');
    const buttons = companions.map((companion) => {
      const pill = Object.assign(document.createElement('button'), { type: 'button', className: vertical ? 'dock-pick' : 'scene-pill companion-pill' });
      const face = Object.assign(document.createElement('span'), { className: 'pill-face' });
      face.style.backgroundImage = `url("${companion.motion.poster(companion.restingMood)}")`;
      pill.append(face, Object.assign(document.createElement('span'), { textContent: companion.name }));
      pill.dataset.companion = companion.id;
      pill.setAttribute('aria-pressed', String(companion === current));
      pill.setAttribute('aria-label', `${companion.name}, the ${companion.species}`);
      pill.addEventListener('click', () => choose(companion));
      return pill;
    });
    pills.push(...buttons);
    box.replaceChildren(...buttons);
    box.hidden = false;
  }
}
// Your day: an example day of the kind of work on show in the hero, by its companion.
// Its own tabs pick the work in the hero too.
const yourDay = initYourDay(document.querySelector('#your-day'), { companion: first, work: demo?.scene ?? 'writing', pickWork: (id) => demo?.setScene?.(id) });
document.addEventListener('moku:work', (event) => yourDay?.setWork(event.detail.id));
const friends = companions.length > 1 && demo?.setCompanion
  ? initFriends(document.querySelector('#friends'), { companions, settings, current, onPick: (companion) => choose(companion, 'friends'), after: demo.ready })
  : null;
document.querySelector('#friends')?.classList.toggle('has-choice', Boolean(friends));

// "What Moku reads" opens its answer in the questions.
document.querySelectorAll('[data-open-answer]').forEach((link) => {
  link.addEventListener('click', () => { document.querySelector(link.hash)?.setAttribute('open', ''); });
});
if (location.hash.length > 1) document.querySelector(`details#${CSS.escape(location.hash.slice(1))}`)?.setAttribute('open', '');

loadNear();
document.querySelector('#year').textContent = new Date().getFullYear();
initPageMotion({ settings, house });
