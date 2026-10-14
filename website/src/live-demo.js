import {
  LOOP, beats, beatAt, awayFor, cues, cueRuns, shownDay, formatClock, formatFocus, scenes, sceneOrder, sceneAt, seamOpacity,
  PIECE_LANDS, PICKED_AT, WELCOME_FROM, WELCOME_SOON, CAMERA, cameraAt, pushEase, pullEase, quietLine, stills, workForVisit,
  captionAt, captionText,
} from './demo-timeline.js';
import { CompanionActor } from './demo-actor.js';
import { awayClips, clipsFor, momentsFor } from './companions.js';
import { loadMotion } from './native-motion.js';
import * as loadingPlan from './loading-plan.js';

// The hero: the loop from demo-timeline.js, played on a quiet Mac in index.html,
// the companion small in its corner, as on a real Mac. One camera films it: a wide
// shot while you work, a push-in on the companion's face when you drift, and back
// out when you return. One kind of work per visit (the picker above the screen
// changes it). Each frame writes only transforms, opacity, a few text nodes and the
// scene's own state; windows change by data attribute when their moment comes.

// The front app's menus, as each one's menu bar has them.
const menus = {
  'Google Chrome': ['File', 'Edit', 'View', 'History', 'Bookmarks', 'Profiles', 'Tab', 'Window', 'Help'],
  Notes: ['File', 'Edit', 'Format', 'View', 'Window', 'Help'],
  Figma: ['File', 'Edit', 'View', 'Object', 'Text', 'Arrange', 'Plugins', 'Window', 'Help'],
  Preview: ['File', 'Edit', 'View', 'Go', 'Tools', 'Window', 'Help'],
  Cursor: ['File', 'Edit', 'Selection', 'View', 'Go', 'Run', 'Terminal', 'Window', 'Help'],
  Terminal: ['Shell', 'Edit', 'View', 'Window', 'Help'],
};
// How long the piece that lands stays up beside the companion.
const LANDING_SECONDS = 2.4;
// The longest a beat waits at its boundary for clips still loading.
const HOLD_MS = 1000;
// Tetsu's hologram of today's rocket when a piece lands (RobotTalents.swift: 4.6 s).
const HOLOGRAM_SECONDS = 4.6;
// Tetsu's visor in its corner, in hundredths of the corner's width: where its beam starts.
const VISOR = [51, 43];
// The pointer has to be off the page this long before the companion notices.
const POINTER_AWAY_MS = 600;
// The visible notice: the camera closes in over this long, as the face falls.
const NOTICE_SECONDS = 1.2;

const nextPaint = () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
const clamp = (value, low, high) => Math.min(high, Math.max(low, value));

// The camera: one scale on the whole desk (.desk-inner) about one fixed point, so the
// world scales together and proportions hold. The point is chosen so that in the
// close-up the companion's face sits a little right of centre, with the windows out of
// frame (nothing else in it while it holds): the ones beside it end above the close-up,
// the others before its left edge. The wallpaper reaches past the screen's edges for it
// (live-demo.css). The zoom is what the companion's 640 px clips can fill on this
// screen, between 1.6 and 2.2 times.
const FACE = [.52, .42];      // the face in the companion's corner, as fractions of the corner
const FRAMED_AT = [.6, .5];   // where the face sits in the close-up, as fractions of the screen
const FRAMED_LEFTMOST = .3;   // ...or further left, as far as this, to leave the windows out
// The wallpaper reaches this far past the screen's right and bottom edges (live-demo.css).
const WALL_REACH = 1.25;
function cameraFor(desk) {
  const inner = desk.querySelector('.desk-inner');
  const corner = desk.querySelector('.desk-moku');
  const width = inner.offsetWidth, height = inner.offsetHeight, size = corner?.offsetWidth;
  if (!width || !height || !size) return null;
  const face = [corner.offsetLeft + size * FACE[0], corner.offsetTop + size * FACE[1]];
  const zoom = clamp(640 * 1.15 / (size * (window.devicePixelRatio || 1)), 1.6, 2.2);
  // The fixed point of the scale: the face moves in a straight line from where it is
  // to where it's framed. The close-up never looks past the wallpaper's reach.
  const furthest = (side) => side * (WALL_REACH - 1 / zoom) / (1 - 1 / zoom);
  const fixed = (target, i) => clamp((target - zoom * face[i]) / (1 - zoom), 0, furthest([width, height][i]));
  // The close-up's top edge (origin * (1 - 1 / zoom)): windows that end above it are
  // out of frame already. Its left edge clears the others' right edge, with a little
  // room, when the face is framed no further right than zoom * (face - windows). All
  // four kinds of work share the windows' places.
  const top = fixed(height * FRAMED_AT[1], 1) * (1 - 1 / zoom);
  const scene = desk.querySelector('.scene.is-active') ?? desk.querySelector('.scene');
  const below = [...(scene?.querySelectorAll('.win') ?? [])].filter((win) => win.offsetWidth && win.offsetTop + win.offsetHeight > top - height * .01);
  const windows = Math.max(0, ...below.map((win) => scene.offsetLeft + win.offsetLeft + win.offsetWidth)) + width * .02;
  const framedX = clamp(zoom * (face[0] - windows), width * FRAMED_LEFTMOST, width * FRAMED_AT[0]);
  const origin = [fixed(framedX, 0), fixed(height * FRAMED_AT[1], 1)];
  inner.style.transformOrigin = `${origin[0].toFixed(1)}px ${origin[1].toFixed(1)}px`;
  return { inner, zoom, scale: (z) => 1 + (zoom - 1) * z };
}

// Typing that never moves the layout: every character is laid out from the start
// and only its colour changes, and the caret moves by transform. A keystroke costs
// a repaint, never a reflow or a layout shift. Characters keep their token's class
// (the editor's colours).
class TypedText {
  constructor(element) {
    this.element = element;
    this.text = element.textContent;
    this.chars = [];
    const walk = (node, token) => {
      for (const child of node.childNodes) {
        if (child.nodeType === Node.TEXT_NODE) {
          for (const char of child.textContent) this.chars.push(Object.assign(document.createElement('span'), { textContent: char, className: token }));
        } else walk(child, child.className || token);
      }
    };
    walk(element, '');
    this.caret = Object.assign(document.createElement('span'), { className: 'caret' });
    element.replaceChildren(...this.chars, this.caret);
    element.classList.add('typed-text');
    this.count = -1;
    this.set(0);
  }

  set(fraction) {
    const count = Math.round(fraction * this.chars.length);
    if (count === this.count) return false;
    const [from, to] = this.count < 0 ? [0, this.chars.length] : [Math.min(count, this.count), Math.max(count, this.count)];
    for (let i = from; i < to; i++) this.chars[i].classList.toggle('t', i < count);
    this.count = count;
    this.placeCaret();
    return true;
  }

  // Colour changes leave layout clean, so these reads cost nothing.
  placeCaret() {
    const anchor = this.chars[Math.max(0, this.count - 1)];
    if (!anchor) return;
    const x = this.count ? anchor.offsetLeft + anchor.offsetWidth : anchor.offsetLeft;
    this.caret.style.transform = `translate(${x}px, ${anchor.offsetTop}px)`;
    this.caret.style.height = `${anchor.offsetHeight}px`;
  }

  get words() { return this.text.slice(0, this.count).split(/\s+/).filter(Boolean).length; }
}

function setText(node, text) {
  if (node && node.textContent !== text) node.textContent = text;
}

// A scene's windows, bound to its tracks (demo-timeline.js): front, type:, caret,
// scroll:, and the scene's own state:, var: and text: tracks, which CSS reads.
function bindLayer(element, scene) {
  const all = (selector) => [...element.querySelectorAll(selector)];
  const typed = new Map(all('[data-type]').map((node) => [`type:${node.dataset.type}`, new TypedText(node)]));
  const scrolls = new Map(all('[data-scroll]').map((node) => [`scroll:${node.dataset.scroll}`, node]));
  const texts = new Map(all('[data-text]').map((node) => [`text:${node.dataset.text}`, node]));
  const windows = new Map(all('[data-win]').map((node) => [node.dataset.win, node]));
  const words = element.querySelector('[data-words]');
  const seams = all('[data-seam]');
  const pointer = element.querySelector('.pointer');
  const ring = element.querySelector('.pointer-ring');
  const last = {};
  let targets = new Map();

  // Targets in the desk's own (unzoomed) pixels, whatever the camera is doing.
  function measure(desk, scale = 1) {
    if (element.hidden) return;
    typed.forEach((text) => text.placeCaret());  // a new width rewraps the text
    const box = desk.querySelector('.desk-inner').getBoundingClientRect();
    targets = new Map(all('[data-at]').map((node) => {
      const rect = node.getBoundingClientRect();
      return [node.dataset.at, { x: (rect.left + rect.width / 2 - box.left) / scale, y: (rect.top + rect.height / 2 - box.top) / scale }];
    }));
  }

  function write(key, apply, value) {
    if (last[key] === value) return;
    last[key] = value;
    apply(value);
  }

  function apply(t, seam) {
    const state = sceneAt(scene, t);
    let typedChanged = false;
    for (const [name, value] of Object.entries(state.values)) {
      const [kind, id] = name.split(':');
      if (kind === 'type') {
        const text = typed.get(name);
        if (!text) continue;
        typedChanged = text.set(value) || typedChanged;
        write(`${name}/typing`, (typing) => text.element.classList.toggle('is-typing', typing), state.typing[name]);
      } else if (kind === 'front') {
        write(name, (front) => {
          element.dataset.front = front;
          windows.forEach((node, win) => node.classList.toggle('is-front', win === front));
        }, value);
      } else if (kind === 'caret') write(name, (caret) => typed.forEach((text, key) => text.element.classList.toggle('has-caret', key === `type:${caret}`)), value);
      else if (kind === 'scroll') write(name, (percent) => { scrolls.get(name).style.transform = `translate3d(0, ${(-percent).toFixed(2)}%, 0)`; }, value);
      else if (kind === 'state') write(name, (value) => { element.dataset[id] = value; }, value);
      else if (kind === 'var') write(name, (value) => element.style.setProperty(`--${id}`, value), Math.round(value * 1000) / 1000);
      else if (kind === 'text') write(name, (value) => setText(texts.get(name), value), value);
    }
    if (typedChanged && words) {
      const count = Number(words.dataset.words) + [...typed.values()].reduce((sum, text) => sum + text.words, 0);
      setText(words, count.toLocaleString('en-US'));
    }
    write('seam', (opacity) => seams.forEach((node) => { node.style.opacity = opacity === 1 ? '' : opacity.toFixed(3); }), seam);
    movePointer(state.cursor);
    return state;
  }

  function movePointer({ from, to, progress, press, clickAge, visible }) {
    if (!pointer) return;
    const a = targets.get(from), b = targets.get(to) || a;
    if (!a) return;
    let x = a.x + (b.x - a.x) * progress, y = a.y + (b.y - a.y) * progress;
    const distance = Math.hypot(b.x - a.x, b.y - a.y);
    if (distance > 1) {
      // A slight arc, as a wrist moves a trackpad.
      const arc = Math.sin(progress * Math.PI) * distance * .08;
      x += -(b.y - a.y) / distance * arc;
      y += (b.x - a.x) / distance * arc;
    }
    write('pointer', (transform) => { pointer.style.transform = transform; }, `translate3d(${x.toFixed(1)}px, ${y.toFixed(1)}px, 0) scale(${(1 - press * .14).toFixed(3)})`);
    write('pointer-visible', (opacity) => { pointer.style.opacity = opacity; }, visible.toFixed(2));
    const ringOpacity = clickAge >= 0 ? (.55 * (1 - clickAge / .45)).toFixed(3) : '0';
    write('ring', (opacity) => { ring.style.opacity = opacity; }, ringOpacity);
    if (clickAge >= 0) write('ring-transform', (transform) => { ring.style.transform = transform; }, `translate3d(${b.x.toFixed(1)}px, ${b.y.toFixed(1)}px, 0) scale(${(.35 + clickAge / .45).toFixed(3)})`);
  }

  return { element, scene, measure, apply };
}

// Shows one scene on a stage (the live one, or a still's copy) and hides the rest.
function showScene(desk, id) {
  for (const node of desk.querySelectorAll('.scene[data-scene]')) {
    const on = node.dataset.scene === id;
    node.hidden = !on;
    node.classList.toggle('is-active', on);
  }
}

// What the stage shares around the windows: the menu bar, the home chip, the piece
// that lands beside the companion, and the beat (the wallpaper greys while you drift).
// The clock and the chip change only at the payoff, when the piece lands.
function bindShared(desk, companion) {
  const nodes = {
    app: desk.querySelector('[data-app-name]'), menus: desk.querySelector('[data-app-menus]'), clock: desk.querySelector('[data-clock]'),
    focus: desk.querySelector('[data-focus]'), comebacks: desk.querySelector('[data-comebacks]'),
    next: desk.querySelector('[data-house-next]'), tag: desk.querySelector('[data-piece-tag]'), piece: desk.querySelector('[data-piece]'),
    seams: [...desk.querySelectorAll(':scope .desk-inner > .menubar [data-seam], :scope .house-chip [data-seam]')],
  };
  setText(desk.querySelector('[data-home-name]'), companion.home.name);
  // The home's renders before and after the loop's piece lands; the piece's own tag
  // shows the home as it is once the piece is on.
  const homeImage = (node, t) => {
    const minutes = shownDay(t).house.built * 10;
    // The chip's 160 px renders (4 KB each): the page already starts from them, so the full renders aren't fetched too.
    const src = companion.home.thumb?.(minutes) ?? companion.home.image(minutes);
    if (node && node.getAttribute('src') !== src) node.src = src;
  };
  homeImage(desk.querySelector('[data-house-now]'), 0);
  homeImage(nodes.next, PIECE_LANDS);
  homeImage(desk.querySelector('[data-piece-thumb]'), PIECE_LANDS);
  // A companion with a hologram (Tetsu) projects its home, as far as it's built,
  // over its head when the piece lands, as the app does.
  const hologram = desk.querySelector('[data-hologram]');
  const projects = Boolean(hologram && companion.home.hologram);
  if (hologram) {
    hologram.hidden = !projects;
    hologram.classList.remove('is-on');
    if (projects) hologram.querySelector('img').src = companion.home.hologram(shownDay(PIECE_LANDS).house.stage + 1);
  }
  const last = {};
  const write = (key, value, apply) => { if (last[key] !== value) { last[key] = value; apply(value); } };

  // A still holds the landed piece's tag; the live loop lets it rise and go.
  return function apply(t, seam, app, { still = false } = {}) {
    const day = shownDay(t);
    write('app', app, (name) => {
      // A new name and new menus, as a Mac redraws its menu bar: no box on the page moves
      // (the old menus sliding over for a longer name was a layout shift, in Chromium's count).
      if (!nodes.app || !nodes.menus) return;
      const named = Object.assign(nodes.app.cloneNode(false), { textContent: name });
      const list = nodes.menus.cloneNode(false);
      list.append(...menus[name].map((label) => Object.assign(document.createElement('span'), { textContent: label })));
      nodes.app.replaceWith(named);
      nodes.menus.replaceWith(list);
      Object.assign(nodes, { app: named, menus: list });
    });
    write('clock', formatClock(day.clock), (text) => setText(nodes.clock, text));
    write('focus', formatFocus(day.focusMinutes), (text) => setText(nodes.focus, text));
    write('comebacks', String(day.comebacks), (text) => setText(nodes.comebacks, text));
    const landed = t >= PIECE_LANDS;
    write('landed', landed, (on) => {
      nodes.next?.classList.toggle('on', on);
      setText(nodes.piece, `+ ${companion.home.pieceNames[day.house.built - 1]}`);
    });
    write('landing', still ? landed : landed && t < PIECE_LANDS + LANDING_SECONDS, (on) => nodes.tag?.classList.toggle(still ? 'is-landed' : 'is-landing', on));
    if (projects) write('projecting', !still && t >= PIECE_LANDS && t < PIECE_LANDS + HOLOGRAM_SECONDS, (on) => hologram.classList.toggle('is-on', on));
    write('seam', seam, (opacity) => nodes.seams.forEach((node) => { node.style.opacity = opacity === 1 ? '' : opacity.toFixed(3); }));
    write('beat', beatAt(t).id, (id) => { desk.dataset.beat = id; });
  };
}

// The state over the desk (demo-timeline.js's captions), one at a time. It follows the
// loop's own fades; when the loop jumps (a new pick, the tab-leave moment), it fades
// out what's up before the next one fades in, so a caption never pops.
const CAPTION_RATE = 1 / .28;
function bindCaption(desk) {
  const node = desk.querySelector('[data-state-label]');
  const word = node?.querySelector('[data-state-word]'), detail = node?.querySelector('[data-state-detail]');
  let shown = null, opacity = 0, written = '';
  const draw = () => {
    const value = opacity.toFixed(3);
    if (value === written) return;
    written = value;
    // Shown or not by the value written, so a fade that ends a hair above 0 (written as 0) still
    // hides it. Out of the layout while hidden: the next caption (its words, its place) is a new
    // box, never a moved one (a layout shift).
    const on = value !== '0.000';
    node.style.opacity = value;
    node.style.visibility = on ? 'visible' : 'hidden';
    node.style.display = on ? '' : 'none';
    node.style.transform = `translateY(${((1 - opacity) * 6).toFixed(2)}px)`;
  };
  const show = (caption, words) => {
    shown = caption;
    node.dataset.place = caption.place;
    node.dataset.tone = caption.tone;
    setText(word, words.word);
    setText(detail, words.detail);
  };
  return function apply(t, { companion, scene, skip = [], hidden = false, dt = Infinity }) {
    if (!node) return;
    const target = hidden ? null : captionAt(t, { skip });
    const step = dt * CAPTION_RATE;
    if (shown && (!target || target.id !== shown.id)) {
      // The one up fades out first, at the loop's pace if it's leaving on time.
      opacity = Math.max(0, opacity - step);
      // Gone: out of the layout for a frame before the next one shows, so the next caption
      // (its words, its place) is a new box, never a moved one (a layout shift).
      if (opacity === 0) { shown = null; draw(); return; }
    }
    if (target && !shown) show(target, captionText(target.id, { companion, scene }));
    if (target && shown?.id === target.id) opacity = clamp(target.opacity, opacity - step, opacity + step);
    draw();
  };
}

// Tetsu's scan beam (RobotTalents.swift's ScanBeam), drawn from its config in
// companions.js (`scanBeam`): a thin cyan line in a narrow wedge from the visor,
// fading with distance, sweeping from high on the work window to its foot.
function drawScanBeam(svg, beam) {
  if (!svg || !beam) return;
  const [x, y] = VISOR, { reach } = beam, half = Math.tan(5 * Math.PI / 180) * reach;
  svg.innerHTML = `<defs><radialGradient id="scan-fade" gradientUnits="userSpaceOnUse" cx="${x}" cy="${y}" r="${reach}"><stop offset=".3" stop-color="#fff" /><stop offset="1" stop-color="#fff" stop-opacity="0" /></radialGradient>`
    + `<mask id="scan-mask" maskUnits="userSpaceOnUse" x="-100" y="-100" width="300" height="300"><rect x="-100" y="-100" width="300" height="300" fill="url(#scan-fade)" /></mask></defs>`
    + `<g mask="url(#scan-mask)"><g class="scan-beam"><path class="scan-wedge" d="M${x} ${y}L${x - reach} ${(y - half).toFixed(1)}L${x - reach} ${(y + half).toFixed(1)}Z" />`
    + `<line class="scan-line" x1="${x - 9}" y1="${y}" x2="${x - reach}" y2="${y}" /></g></g>`;
  svg.style.setProperty('--scan-seconds', `${beam.seconds}s`);
  svg.style.setProperty('--scan-from', `${beam.from}deg`);
  svg.style.setProperty('--scan-to', `${beam.to}deg`);
  svg.style.setProperty('--scan-origin', `${x}px ${y}px`);
}

export function initLiveDemo(root, { settings, companion: first }) {
  if (!root) return null;
  let companion = first;
  const params = new URLSearchParams(location.search);
  const frame = root.querySelector('.desk-frame');
  const desk = root.querySelector('.desk');
  const stillsBox = root.querySelector('.demo-stills');
  const announcer = root.querySelector('[data-announcer]');
  const quiet = root.querySelector('[data-line]');
  const lineNode = desk.querySelector('[data-moku-line]');
  const scan = desk.querySelector('[data-scan]');
  // Who's in the corner: its theme, its description, its menu bar symbol, its beam.
  function dress() {
    for (const [name, value] of Object.entries(companion.theme)) root.style.setProperty(name, value);
    root.dataset.companion = companion.id;
    desk.setAttribute('aria-label', `A sped-up demo on a pretend Mac. Someone is at work in two or three apps; they drift to Instagram and ${companion.name}, ${companion.kind} in the corner, turns sad; they come back and ${companion.name} cheers as a piece of ${companion.home.name.toLowerCase()} lands.`);
    desk.querySelector('.menubar-moku use')?.setAttribute('href', companion.icon);
    scan?.classList.remove('is-on');
    drawScanBeam(scan, companion.scanBeam);
  }
  dress();
  const poster = desk.querySelector('.desk-moku .moku-art > img');
  if (poster.getAttribute('src') !== companion.motion.poster(companion.restingMood)) poster.src = companion.motion.poster(companion.restingMood);
  root.classList.add('is-live');

  const stillAt = Number.parseFloat(params.get('still'));
  // One kind of work per visit: ?work=<id>, or the one this tab drew (a reload keeps
  // it), or a fresh draw. Nothing is kept beyond the tab. A still is of writing.
  function drawWork() {
    if (Number.isFinite(stillAt)) return sceneOrder[0];
    try {
      const kept = sessionStorage.getItem('moku:work');
      if (scenes[kept]) return kept;
      const work = workForVisit(Math.floor(Math.random() * sceneOrder.length));
      sessionStorage.setItem('moku:work', work);
      return work;
    } catch { return sceneOrder[0]; }
  }
  let picked = scenes[params.get('work')] ? params.get('work') : drawWork();
  const sceneFor = () => scenes[picked];
  const layers = {};
  const sceneNodes = new Map([...desk.querySelectorAll('.scene[data-scene]')].map((node) => [node.dataset.scene, node]));
  const layerFor = (id) => (layers[id] ??= bindLayer(sceneNodes.get(id), scenes[id]));
  let onStage = null;
  function stage(scene) {
    if (onStage === scene.id) return layers[scene.id];
    onStage = scene.id;
    showScene(desk, scene.id);
    const layer = layerFor(scene.id);
    layer.measure(desk, camera ? camera.scale(zoom) : 1);
    tabs.forEach((tab) => tab.setAttribute('aria-pressed', String(tab.dataset.work === scene.id)));
    // Your day follows the kind of work on show (your-day.js).
    root.dispatchEvent(new CustomEvent('moku:work', { bubbles: true, detail: { id: scene.id } }));
    return layer;
  }

  let shared = bindShared(desk, companion);
  const caption = bindCaption(desk);
  let captionClock = null;
  const onLine = (text) => {
    if (text) lineNode.textContent = text;
    lineNode.classList.toggle('on', Boolean(text));
  };
  // Tetsu's scan beam sweeps across the work as its display scans.
  const corner = desk.querySelector('.desk-moku');
  const onTalent = (talent) => {
    if (talent !== 'scan' || !scan || !companion.scanBeam) return;
    // Its reach is the config's, or as far as it takes to cross most of the work window
    // when a wide desk has set the window further off.
    const work = desk.querySelector('.scene.is-active .win-work')?.getBoundingClientRect();
    const box = corner.getBoundingClientRect();
    if (work && box.width) {
      const needed = (box.left + box.width * VISOR[0] / 100 - (work.left + work.width * .3)) / box.width * 100;
      drawScanBeam(scan, { ...companion.scanBeam, reach: Math.round(Math.max(companion.scanBeam.reach, needed)) });
    }
    scan.removeAttribute('hidden');  // an SVG element has no hidden property
    scan.classList.remove('is-on');
    scan.getBoundingClientRect();  // restarts the sweep
    scan.classList.add('is-on');
  };
  let actor = new CompanionActor(corner, companion, { onLine, onTalent, isReady: clipReady });

  let elapsed = 0, lastFrame = null, raf = 0, running = false, started = false, played = false, visible = false;
  // Seconds of frames played: the camera's own moves (the notice) run on it.
  let clock = 0;
  // Settles once the first companion's loop has loaded, so the rest of the page can wait its turn.
  let loopLoaded;
  const loopReady = new Promise((resolve) => { loopLoaded = resolve; });
  // The loop (by index) whose comeback is the visitor's own, after the tab-leave moment.
  let welcomeLoop = -1;
  // The loop that opens with a hello: the first, or the one a picked companion starts.
  let helloLoop = 0;
  // Clips that have arrived, per companion (`<manifest>#<clip>`).
  const ready = new Set();
  const clipKey = (clip) => `${companion.motion.manifest}#${clip}`;
  // Hoisted, so the first actor (above) can ask it once the loop runs.
  function clipReady(clip) { return !clip || ready.has(clipKey(clip)); }

  // The work picker above the screen: a tab per kind of work, the one on show marked.
  const tabsBox = root.querySelector('.work-tabs');
  const tabs = sceneOrder.map((id) => {
    const tab = Object.assign(document.createElement('button'), { type: 'button', className: 'work-tab', textContent: scenes[id].label });
    tab.dataset.work = id;
    tab.setAttribute('aria-pressed', 'false');
    tab.addEventListener('click', () => setScene(id));
    return tab;
  });
  if (tabsBox) {
    tabsBox.replaceChildren(...tabs);
    tabsBox.hidden = false;
  }

  // The camera (cameraFor): the loop's own moves (demo-timeline.js), or, while the
  // companion notices you leaving, a move of its own on the frame clock (`lens`).
  let camera = null, zoom = 0, filmed = '', lens = null;
  function measure() {
    camera = cameraFor(desk);
    filmed = '';
    if (onStage) layers[onStage].measure(desk, camera ? camera.scale(zoom) : 1);
  }
  function film(z) {
    zoom = z;
    if (!camera) return;
    const value = camera.scale(z).toFixed(4);
    if (value === filmed) return;
    filmed = value;
    // The wide shot carries no transform at all, so the work's own changes paint as
    // they always have.
    camera.inner.style.transform = z > 0 ? `scale(${value})` : '';
  }
  function zoomAt(t) {
    const loopZoom = cameraAt(t);
    if (!lens) return loopZoom;
    const z = lens.at(clock, loopZoom);
    if (lens.release && clock >= lens.until) lens = null;
    return z;
  }
  // Closes in on the companion: the loop's own push-in if it's under way, so the move
  // never breaks its stride, or a push-in of its own from wherever the camera is.
  function closeIn() {
    const t = elapsed % LOOP, [inFrom, inTo] = CAMERA.pushIn, c0 = clock, from = zoom;
    if (t > inFrom && t < inTo && cameraAt(t) === zoom) {
      lens = { at: (c) => cameraAt(Math.min(inTo, t + c - c0)), until: c0 + inTo - t };
    } else {
      const seconds = NOTICE_SECONDS * Math.max(.4, 1 - from);
      lens = { at: (c) => from + (1 - from) * pushEase(clamp((c - c0) / seconds, 0, 1)), until: c0 + seconds };
    }
  }
  // Eases from wherever the camera is back to the loop's.
  function release(seconds = .85) {
    const from = zoom, c0 = clock;
    lens = { at: (c, loopZoom) => from + (loopZoom - from) * pullEase(clamp((c - c0) / seconds, 0, 1)), until: c0 + seconds, release: true };
  }

  // One quiet line under the stage (demo-timeline.js's quietLine).
  let lineState = 'invite', away = null;
  function say(state, { announce = false } = {}) {
    lineState = state;
    const text = quietLine(companion, { state, away });
    if (announce && announcer) announcer.textContent = text;
    if (!quiet || quiet.textContent === text) return;
    quiet.textContent = text;
    quiet.animate?.([{ opacity: 0, transform: 'translateY(.25em)' }, { opacity: 1, transform: 'none' }], { duration: 480, easing: 'cubic-bezier(.22, 1, .36, 1)' });
  }

  function render() {
    const loop = Math.floor(elapsed / LOOP), t = elapsed - loop * LOOP;
    const layer = stage(sceneFor());
    const seam = seamOpacity(t, loop === 0);
    const state = layer.apply(t, seam);
    shared(t, seam, state.app);
    film(zoomAt(t));
    // While the companion notices you've gone, the stage is its alone; the tab-leave
    // moment says it noticed in its own words, under the stage. A cut (out of sight)
    // clears it at once.
    const dt = captionClock == null || desk.classList.contains('is-cut') ? Infinity : clock - captionClock;
    caption(t, { companion, scene: sceneFor(), hidden: held || Boolean(noticing), skip: loop === welcomeLoop ? ['noticed'] : [], dt });
    captionClock = clock;
    // Since when the visitor has had the sad close-up in sight.
    if (held && zoom > .999 && !closeSeenAt && visible && !document.hidden) closeSeenAt = performance.now();
    // The welcome back stays until its loop ends.
    if (lineState === 'back' && loop > welcomeLoop) say('invite');
  }

  // A beat waits at its quiet boundary for its clips, but only for a moment
  // (HOLD_MS): on a slow connection the loop goes on, and the companion shows the
  // stills of any clip still on its way (demo-actor.js), never stuck sad. The clips
  // themselves load from the first paint, in the order the loop needs them.
  const windows = beats.map(({ start, end }) => [start, end]);
  let hold = null;
  function gate(from, to, now) {
    for (let loop = Math.floor(from / LOOP); loop <= Math.floor(to / LOOP); loop++) {
      const moments = momentsFor(companion, { hello: loop === helloLoop });
      for (const [start, end] of windows) {
        const boundary = loop * LOOP + start;
        if (boundary <= from || boundary > to) continue;
        const needed = cues.filter((cue) => cueRuns(cue, loop, helloLoop) && cue.at >= start && cue.at < end).map((cue) => moments[cue.moment]?.clip);
        if (needed.every((clip) => !clip || ready.has(clipKey(clip)))) continue;
        if (hold?.boundary !== boundary) hold = { boundary, since: now };
        // On a light plan (Save-Data, a slow connection) no beat waits: the stills tell it (loading-plan.js).
        if (now - hold.since < (loadingPlan.plan.light ? 0 : HOLD_MS)) return boundary - 1e-4;
      }
    }
    return to;
  }

  function tick(now) {
    raf = requestAnimationFrame(tick);
    // A long frame (a busy tab, a resume) advances the loop at most a tenth of a second.
    const step = lastFrame == null ? 0 : Math.min(.1, (now - lastFrame) / 1000);
    lastFrame = now;
    clock += step;
    // While you're away, the loop holds; the camera and the companion still move.
    if (!held) elapsed = gate(elapsed, elapsed + step, now);
    render();
    actor.update(elapsed);
    if (held) settle();
  }

  function play() {
    if (running) return;
    running = played = true;
    lastFrame = null;
    root.classList.remove('is-paused');
    raf = requestAnimationFrame(tick);
  }

  function stop() {
    if (!running) return;
    running = false;
    cancelAnimationFrame(raf);
    clearInterval(resting);
    resting = 0;
    actor.freeze();
    root.classList.add('is-paused');
  }

  // The three beats as stills, in the kind of work on show, the drift in close-up.
  function renderStills() {
    stillsBox.replaceChildren();
    const scene = sceneFor();
    for (const { t, mood, caption } of stills) {
      const figure = document.createElement('figure');
      const copy = frame.cloneNode(true);
      const copyDesk = copy.querySelector('.desk');
      const text = caption.replace('{name}', companion.name);
      copyDesk.setAttribute('aria-label', `${text} ${companion.describe[mood]}.`);
      delete copyDesk.dataset.away;
      copy.querySelector('.desk-inner').style.transform = '';
      copy.querySelector('.desk-moku .moku-art').replaceChildren(Object.assign(new Image(), { src: companion.motion.poster(mood), alt: '', width: 640, height: 640 }));
      const figcaption = document.createElement('figcaption');
      figcaption.textContent = text;
      figure.append(copy, figcaption);
      stillsBox.append(figure);
      showScene(copyDesk, scene.id);
      const copyLayer = bindLayer(copy.querySelector(`.scene[data-scene="${scene.id}"]`), scene);
      copyLayer.measure(copyDesk);
      const state = copyLayer.apply(t, 1);
      bindShared(copyDesk, companion)(t, 1, state.app, { still: true });
      const lens = cameraFor(copyDesk);
      if (lens) lens.inner.style.transform = `scale(${lens.scale(cameraAt(t)).toFixed(4)})`;
    }
  }

  // Reduced motion shows the three beats as stills; so does a pause chosen before
  // the loop ever played. A pause mid-loop freezes the frame it's on.
  const showsStills = () => settings.reduced.matches || (settings.paused && !played);
  function sync() {
    const stillMode = showsStills();
    root.classList.toggle('shows-stills', stillMode);
    stillsBox.hidden = !stillMode;
    if (stillMode) {
      stop();
      renderStills();
      return;
    }
    stillsBox.replaceChildren();
    if (started && visible && !document.hidden && !settings.paused) play();
    else stop();
  }

  // The tab-leave moment: it notices you. Leave the tab, take the pointer off the page
  // for a moment, or scroll the demo out of view, and the companion notices: its face
  // falls, the screen greys and the camera holds the close-up while the loop waits.
  // Leaving the tab also says so in its title and icon. Come back and the loop's
  // comeback is yours: a beat of the sad face, the pointer heads back to the work, the
  // camera pulls back, "Gone 14 seconds. You came back.", and the companion says
  // "There you are!" as the piece lands. Out of sight it cuts straight to the
  // close-up; in sight (the pointer) it plays out, once the companion is free. With
  // reduced motion or a pause, only the tab's title and icon change.
  const reasons = new Set();
  let held = false, atWelcome = false, noticing = null, leftAt = 0, closeSeenAt = 0;
  const live = () => started && !showsStills() && !settings.paused;
  const onScreen = () => visible && !document.hidden;
  const title = document.title;
  const icon = document.querySelector('link[rel="icon"]');
  const iconHref = icon?.getAttribute('href');

  function leave(reason) {
    if (reasons.has(reason)) return;
    const first = reasons.size === 0;
    reasons.add(reason);
    if (reason === 'tab') {
      document.title = `${companion.name} noticed…`;
      icon?.setAttribute('href', '/favicon-sad.svg');
    }
    if (first) leftAt = performance.now() - (reason === 'pointer' ? POINTER_AWAY_MS : 0);
    if (!live() || (atWelcome && !noticing)) return;
    if (reason === 'pointer' && onScreen()) { if (!noticing) notice(); }
    else toWelcome(true);
  }

  // In sight: the companion turns sad as soon as it's free (or now, if it already is),
  // and the loop holds from that moment while the camera closes in.
  function notice() {
    const noticed = noticing = { turned: false, back: false };
    const turn = () => {
      if (noticing !== noticed || noticed.turned) return;
      noticed.turned = held = true;
      desk.dataset.away = '';
      say('away');
      closeIn();
    };
    actor.react('disappointed', turn);
    if (actor.heading === 'disappointed') turn();
  }

  // The loop picks up at its welcome point, in the close-up, the face already sad.
  // From a notice the windows are out of frame, so nothing visibly changes.
  function toWelcome(cut) {
    const loop = Math.floor(elapsed / LOOP) + (elapsed % LOOP > WELCOME_FROM ? 1 : 0);
    elapsed = loop * LOOP + WELCOME_FROM;
    welcomeLoop = loop;
    held = atWelcome = true;
    noticing = null;
    lens = null;
    if (cut) {
      actor.show('disappointed');
      scan?.classList.remove('is-on');
      desk.dataset.away = '';
      say('away');
    }
    actor.react('disappointed');  // it waits there, blinking now and then
    actor.welcomeLoop = loop;
    actor.position = { loop, index: cues.findIndex((cue) => cue.at > WELCOME_FROM) };
    if (cut) desk.classList.add('is-cut');
    render();
    if (cut) {
      desk.getBoundingClientRect();  // the cut lands without transitions
      desk.classList.remove('is-cut');
    }
  }

  function comeBack(reason) {
    if (!reasons.delete(reason)) return;
    if (reason === 'tab') {
      if (document.title !== title) document.title = title;
      if (iconHref) icon.setAttribute('href', iconHref);
    }
    if (reasons.size) return;
    away = awayFor((performance.now() - leftAt) / 1000);
    // Back before the companion was free to notice: nothing happened.
    if (noticing && !noticing.turned) {
      noticing = null;
      actor.live = null;
      return;
    }
    if (noticing) noticing.back = true;  // the close-up lands first (settle)
    else if (atWelcome) welcome();
  }

  function welcome() {
    // Watched all along: the comeback answers at once. Back from out of sight: a beat
    // of the sad face first, so it's seen to have noticed.
    if (closeSeenAt && performance.now() - closeSeenAt >= 1000) elapsed = Math.max(elapsed, welcomeLoop * LOOP + WELCOME_SOON);
    closeSeenAt = 0;
    held = atWelcome = false;
    actor.live = null;
    delete desk.dataset.away;
    say('back', { announce: true });
    wake();
  }

  // While held: a notice lands in the close-up and picks up at the welcome point;
  // once all is still, the stage stops drawing frames until the companion blinks or
  // you come back.
  let resting = 0;
  function settle() {
    if (noticing) {
      if (!noticing.turned || actor.motion.busy || actor.mood !== 'disappointed' || (lens && clock < lens.until)) return;
      const { back } = noticing;
      toWelcome(false);
      if (back) welcome();
      return;
    }
    if ((lens && clock < lens.until) || actor.motion.busy || resting) return;
    cancelAnimationFrame(raf);
    raf = 0;
    resting = setInterval(() => actor.update(elapsed), 500);
  }
  function wake() {
    if (!resting) return;
    clearInterval(resting);
    resting = 0;
    if (running) {
      lastFrame = null;
      raf = requestAnimationFrame(tick);
    }
  }

  document.addEventListener('visibilitychange', () => {
    if (document.hidden) leave('tab'); else comeBack('tab');
    sync();
  });
  // The pointer, where there is one: off the page for a moment, while the demo is in view.
  const hovers = matchMedia('(hover: hover) and (pointer: fine)');
  let pointerTimer = 0;
  document.addEventListener('mouseout', (event) => {
    if (event.relatedTarget || !hovers.matches || !visible) return;
    clearTimeout(pointerTimer);
    pointerTimer = setTimeout(() => leave('pointer'), POINTER_AWAY_MS);
  });
  document.addEventListener('mouseover', () => {
    clearTimeout(pointerTimer);
    comeBack('pointer');
  });

  // A new pick (another companion, or another kind of work) starts a fresh loop.
  // The screen and the corner fade out, the camera eases back to the wide shot, and
  // the loop picks up just before the hello: a new companion greets you, then acts
  // out the drift and the comeback within seconds; new work gets its glance (Tetsu's
  // scan) instead. Clips load in the loop's order, and the loop waits at the next beat
  // for them.
  let switching = 0;
  async function restart(change) {
    const generation = ++switching;
    root.classList.add('is-switching');
    await new Promise((resolve) => setTimeout(resolve, 200));  // the fade out (live-demo.css)
    if (generation !== switching) return;
    const greets = change();
    const loop = Math.floor(elapsed / LOOP) + 1;
    elapsed = loop * LOOP + PICKED_AT;
    if (greets) helloLoop = loop;
    welcomeLoop = -1;
    noticing = null;
    held = atWelcome = false;
    closeSeenAt = 0;
    delete desk.dataset.away;
    if (lineState !== 'invite') say('invite');
    release(.7);
    // The state over the desk has faded out with the screen (live-demo.css): the old one is cleared.
    captionClock = null;
    actor.retire();
    scan?.classList.remove('is-on');
    actor = new CompanionActor(corner, companion, { onLine, onTalent, isReady: clipReady });
    actor.position = { loop, index: 0 };
    actor.helloLoop = helloLoop;
    wake();
    render();
    if (root.classList.contains('shows-stills')) renderStills();
    await actor.motion.setPoster(companion.restingMood);
    if (generation === switching) root.classList.remove('is-switching');
  }

  // Another companion takes the corner, in the same work.
  let target = companion.id;
  function setCompanion(next) {
    if (!next || next.id === target) return;
    target = next.id;
    loadClips(next);
    restart(() => {
      if (next.id === companion.id) return false;
      companion = next;
      dress();
      shared = bindShared(desk, companion);
      if (lineState !== 'invite') say(lineState);
      return true;
    });
  }

  // Another kind of work: it stays for this visit, until another is picked.
  function setScene(id) {
    if (!scenes[id]) return;
    const already = id === picked;
    picked = id;
    try { sessionStorage.setItem('moku:work', id); } catch { /* Storage is optional. */ }
    if (already || id === onStage) {
      tabs.forEach((tab) => tab.setAttribute('aria-pressed', String(tab.dataset.work === id)));
      return;
    }
    restart(() => false);
  }

  // The clips a companion needs, in the order the loop needs them, then the ones only
  // the tab-leave moment plays.
  function loadClips(who) {
    const order = [...new Set([...clipsFor(who, cues.filter((cue) => cueRuns(cue, 0))), ...clipsFor(who, cues), ...awayClips(who)])];
    return { order, done: (async () => {
      for (const clip of order) {
        try { await loadMotion(clip, who.motion.manifest); } catch { /* The actor falls back to stills. */ }
        ready.add(`${who.motion.manifest}#${clip}`);
      }
    })() };
  }

  const resize = new ResizeObserver(() => { measure(); if (!running) render(); });
  resize.observe(desk);
  document.fonts?.ready.then(() => measure());
  // In view (15% or more) the loop plays; fully out of view, the companion notices
  // you've gone; half back in view, you're back.
  let seen = false;
  new IntersectionObserver(([entry]) => {
    const ratio = entry.isIntersecting ? entry.intersectionRatio : 0;
    visible = ratio >= .15;
    if (ratio >= .5) {
      seen = true;
      comeBack('scroll');
    } else if (ratio === 0 && seen) leave('scroll');
    sync();
  }, { threshold: [0, .15, .5] }).observe(frame);
  document.addEventListener('moku:motion-change', sync);

  measure();
  if (Number.isFinite(stillAt)) {
    // A single frame on request, for the og:image and visual checks. The mood is
    // the last mood change that was well under way by then.
    elapsed = clamp(stillAt, 0, LOOP - .01);
    const layer = stage(sceneFor());
    const state = layer.apply(elapsed, 1);
    shared(elapsed, 1, state.app, { still: true });
    film(cameraAt(elapsed));
    caption(elapsed, { companion, scene: sceneFor() });
    const change = cues.filter((cue) => companion.moments[cue.moment].to && cue.at + 1 <= elapsed).at(-1);
    actor.show(change ? companion.moments[change.moment].to : companion.restingMood);
    root.classList.add('is-still');
    loopLoaded();
    return { layer, ready: loopReady };
  }
  render();
  sync();

  // Clips load after the first paint, in the order the loop needs them.
  (async () => {
    await nextPaint();
    actor.motion.prepare(companion.moods);
    const { order, done: loading } = loadClips(companion);
    const firstClips = order.filter((clip) => cues.some((cue) => cue.at < beats[0].end && cueRuns(cue, 0) && momentsFor(companion, { hello: true })[cue.moment]?.clip === clip));
    // Start once the first beat can play, or after a moment without its hello; on a light plan at once, in stills.
    if (!loadingPlan.plan.light) {
      await Promise.race([
        (async () => { while (!firstClips.every((clip) => ready.has(clipKey(clip)))) await new Promise((resolve) => setTimeout(resolve, 50)); })(),
        new Promise((resolve) => setTimeout(resolve, 2500)),
      ]);
    }
    started = true;
    sync();
    await loading;
    loopLoaded();
    new Image().src = companion.home.thumb?.(160) ?? companion.home.image(160);
  })();

  // For checks in headless browsers; nothing on the page depends on it.
  root.liveDemo = {
    get elapsed() { return elapsed; }, get running() { return running; }, get actor() { return actor; }, get companion() { return companion.id; },
    get scene() { return onStage; }, get zoom() { return zoom; }, get held() { return held; }, get away() { return [...reasons]; },
    get resting() { return Boolean(resting); }, get line() { return lineState; },
    setCompanion, setScene, ready: loopReady,
  };
  return root.liveDemo;
}
