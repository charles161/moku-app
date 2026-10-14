import { NativeMotion, loadMotion } from './native-motion.js';
import { plan } from './loading-plan.js';

// Moku and Tetsu (index.html, 02): the two companions side by side, each in its
// own world, playing its own clips from the app's renderer. They say hello in turn as
// they come into view, 0.45 s apart, as the welcome's tiles do (Onboarding.swift);
// then each lives a little while you look; picking one makes it yours across the page
// (main.js), and it says hello again, as a tile does when it's chosen.

const HELLO = 'content-wave';
const HELLO_GAP = 450;
// Small moves from the app's own idle life, light enough to load for all three.
const LIFE = ['content-blink', 'content-slow-blink', 'content-ear-left', 'content-nose', 'content-paw'];
const lifeDelay = () => 2600 + Math.random() * 3800;
// A card shows its companion about twice as big as the hero's corner does, so it keeps the
// full-size clips unless the connection is slow or saving data (loading-plan.js).
const size = plan.light ? plan.clips : 'full';

export function initFriends(section, { companions, settings, current, onPick, after = Promise.resolve() }) {
  if (!section) return null;
  const enabled = () => !settings.paused && !settings.reduced.matches;
  let sectionVisible = false, near = false, heroLoaded = false, scrolled = scrollY > 0, loading = null, nextHello = 0;

  const cards = [...section.querySelectorAll('[data-friend]')].map((element) => {
    const companion = companions.find(({ id }) => id === element.dataset.friend);
    const button = element.querySelector('.friend-pick');
    // A companion without exported clips keeps its still, and can't be picked yet.
    if (!companion) { element.classList.add('is-still'); if (button) button.hidden = true; return null; }
    for (const [name, value] of Object.entries(companion.theme)) element.style.setProperty(name, value);
    const actor = element.querySelector('.friend-actor');
    const { manifest, poster } = companion.motion;
    const card = {
      element, companion, button,
      motion: new NativeMotion(actor, (name) => loadMotion(name, manifest, size), (mood) => poster(mood, size)),
      line: element.querySelector('.friend-line'),
      seen: false, visible: false, queued: null, last: null, timer: 0,
    };
    button?.addEventListener('click', () => onPick(companion));
    return card;
  }).filter(Boolean);

  // Plays a clip on a card, never over another: a hello waits for the move under way.
  function play(card, clip, line) {
    if (!enabled()) return;
    if (card.motion.busy) { if (line || !card.queued) card.queued = { clip, line }; return; }
    card.motion.play(clip, {
      onFinish: () => {
        if (line) card.line.classList.remove('on');
        const queued = card.queued;
        card.queued = null;
        if (queued) setTimeout(() => play(card, queued.clip, queued.line), 60);
      },
    }).then((started) => {
      if (started && line) { card.line.textContent = line; card.line.classList.add('on'); }
    });
  }
  const hello = (card) => play(card, HELLO, `Hi! I’m ${card.companion.name}.`);

  // The roll call: each says hello the first time it's well in view, in turn.
  function greet(card) {
    if (card.seen || !enabled()) return;
    card.seen = true;
    const now = performance.now();
    nextHello = Math.max(now + 250, nextHello + HELLO_GAP);
    setTimeout(() => hello(card), nextHello - now);
  }

  // A little life while you look: one small move at a time, at its own pace.
  function live(card) {
    clearTimeout(card.timer);
    card.timer = setTimeout(() => {
      if (card.visible && !document.hidden && enabled() && !card.motion.busy) {
        const choices = LIFE.filter((clip) => clip !== card.last);
        card.last = choices[Math.floor(Math.random() * choices.length)];
        play(card, card.last);
      }
      live(card);
    }, lifeDelay());
  }

  // Clips load once the visitor scrolls with the section near and the hero's loop in
  // (`after`), or as soon as the section shows: the hellos first, then the small
  // moves. Someone who never scrolls never downloads them.
  function load() {
    if (!(sectionVisible || (near && heroLoaded && scrolled))) return;
    loading ??= (async () => {
      for (const clip of [HELLO, ...LIFE]) {
        await Promise.all(cards.map(({ companion }) => loadMotion(clip, companion.motion.manifest, size).catch(() => null)));
      }
    })();
  }
  after.then(() => { heroLoaded = true; load(); });
  new IntersectionObserver(([entry]) => { near = entry.isIntersecting; load(); }, { rootMargin: '700px 0px' }).observe(section);
  addEventListener('scroll', () => { scrolled = true; load(); }, { passive: true, once: true });
  new IntersectionObserver(([entry]) => { sectionVisible = entry.intersectionRatio > 0; load(); }, { threshold: [0, .02] }).observe(section);
  const watch = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      const card = cards.find(({ element }) => element === entry.target);
      card.visible = entry.intersectionRatio >= .55;
      if (card.visible) greet(card);
    }
  }, { threshold: [0, .55] });
  cards.forEach((card) => { watch.observe(card.element); live(card); });

  // Paused or reduced: every card shows its still.
  function sync() {
    if (enabled()) return;
    for (const card of cards) { card.queued = null; card.line.classList.remove('on'); card.motion.cancel(); }
  }
  document.addEventListener('moku:motion-change', sync);
  document.addEventListener('visibilitychange', () => { if (document.hidden) sync(); });

  // The one that keeps you company: its card shows it, and it says hello.
  function setPicked(companion, { greet: wave = true } = {}) {
    for (const card of cards) {
      const picked = card.companion.id === companion.id;
      card.element.classList.toggle('is-picked', picked);
      card.button?.setAttribute('aria-pressed', String(picked));
      if (picked && wave && sectionVisible) { card.seen = true; hello(card); }
    }
    section.querySelectorAll('[data-picked-name]').forEach((node) => { node.textContent = companion.name; });
    // A pick here points back up to the hero, where it's about to say hello.
    const watch = section.querySelector('.friends-watch');
    if (watch && wave && sectionVisible && enabled()) {
      watch.classList.remove('is-fresh');
      watch.getBoundingClientRect();
      watch.classList.add('is-fresh');
    }
  }
  setPicked(current, { greet: false });
  return { setPicked };
}
