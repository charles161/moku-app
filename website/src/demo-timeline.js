// The hero's script: one 24-second loop of a working day, played on a simulated
// Mac. It is plain data and pure functions, so the beats are testable without a
// browser.
import { houseProgress } from './house.js';

export const LOOP = 24;

// The three beats. The drift starts when the feed comes forward (the wallpaper
// greys); the comeback when the work window is clicked again (colour returns). A
// beat also waits at its start for its clips (live-demo.js).
export const beats = [
  { id: 'work', start: 0, end: 7.6 },
  { id: 'drift', start: 7.6, end: 15.65 },
  { id: 'back', start: 15.65, end: LOOP },
];

export const beatAt = (t) => beats.find((beat) => t < beat.end) ?? beats[beats.length - 1];

// The camera. The desk is a wide shot: someone working, the companion small in its
// corner. The drift plays out in the wide shot first: the feed comes forward and is
// scrolled for a few seconds, so you see yourself drifting. Only then does the camera
// push in, slowly, on the companion as its face falls, and hold there with nothing
// else in frame. When the work window is clicked again, it pulls back slowly, so
// you see the work in front again before the cheer. 0 is the wide shot, 1 the
// close-up (live-demo.js turns it into one scale on the whole desk).
export const CAMERA = { pushIn: [11.2, 13.2], pullBack: [15.72, 17.52] };

// A CSS cubic-bezier as a function of progress (0 to 1).
export function cubicBezier(x1, y1, x2, y2) {
  const at = (a, b, s) => 3 * a * s * (1 - s) ** 2 + 3 * b * s * s * (1 - s) + s ** 3;
  return (p) => {
    if (p <= 0) return 0;
    if (p >= 1) return 1;
    let lo = 0, hi = 1;
    for (let i = 0; i < 40; i++) {
      const mid = (lo + hi) / 2;
      if (at(x1, x2, mid) < p) lo = mid; else hi = mid;
    }
    return at(y1, y2, (lo + hi) / 2);
  };
}
// In: eases in and out, like a hand on a dolly. Out: leaves the still close-up softly
// and settles for a long time, as weight does.
export const pushEase = cubicBezier(.6, 0, .35, 1);
export const pullEase = cubicBezier(.4, 0, .2, 1);

export function cameraAt(t) {
  const [inFrom, inTo] = CAMERA.pushIn, [outFrom, outTo] = CAMERA.pullBack;
  if (t < inFrom || t >= outTo) return 0;
  if (t < inTo) return pushEase((t - inFrom) / (inTo - inFrom));
  if (t < outFrom) return 1;
  return 1 - pullEase((t - outFrom) / (outTo - outFrom));
}

// The state, named over the desk, one at a time: working (and on what), drifting,
// the companion noticing (in the close-up, above its head), and back to focus. Each
// fades in and out on its own; none is up while the camera moves in, and the last
// one is gone as the cheer and the piece take the stage.
export const CAPTION_FADE = { in: .45, out: .5 };
export const captions = [
  { id: 'working', from: .5, to: 3.9, place: 'centre', tone: 'work' },
  { id: 'drifting', from: 8.45, to: 11.1, place: 'centre', tone: 'drift' },
  { id: 'noticed', from: 13.4, to: 15.3, place: 'top', tone: 'drift' },
  { id: 'back', from: 17.0, to: 18.75, place: 'centre', tone: 'work' },
];
const fade = (p) => p <= 0 ? 0 : p >= 1 ? 1 : p < .5 ? 2 * p * p : 1 - (-2 * p + 2) ** 2 / 2;

// The caption at t, with its opacity; null between them. `skip` leaves some out (the
// tab-leave moment's own words say the companion noticed).
export function captionAt(t, { skip = [] } = {}) {
  for (const caption of captions) {
    if (t < caption.from || t >= caption.to || skip.includes(caption.id)) continue;
    const opacity = Math.min(fade((t - caption.from) / CAPTION_FADE.in), fade((caption.to - t) / CAPTION_FADE.out));
    return { ...caption, opacity };
  }
  return null;
}

// What a caption says: the state, and a word on it.
export function captionText(id, { companion, scene }) {
  if (id === 'working') return { word: 'Working', detail: scene.doing };
  if (id === 'drifting') return { word: 'Drifting', detail: 'Scrolling Instagram' };
  if (id === 'noticed') return { word: `${companion.name} noticed`, detail: '' };
  return { word: 'Back to focus', detail: scene.backTo };
}

// One quiet line under the stage. It invites the tab-leave moment (live-demo.js),
// says so while the companion has noticed, and welcomes the visitor back with how
// long they were away.
export const lines = {
  invite: 'Look away. It’ll notice.',
  away: '{name} noticed you left.',
  back: 'You came back.',
  backAfter: 'Gone {away}. You came back.',
};

export function quietLine(companion, { state = 'invite', away = null } = {}) {
  const text = state === 'back' ? (away ? lines.backAfter.replace('{away}', away) : lines.back) : lines[state] ?? lines.invite;
  return text.replace('{name}', companion.name);
}

// How long the visitor was away, as the line says it.
export function awayFor(seconds) {
  if (!(seconds >= 1)) return null;
  const say = (n, unit) => `${n} ${unit}${n === 1 ? '' : 's'}`;
  if (seconds < 60) return say(Math.round(seconds), 'second');
  if (seconds < 3600) return say(Math.round(seconds / 60), 'minute');
  return 'a while';
}

// With reduced motion, or paused before it ever played: one still per beat, the
// middle one in the camera's close-up.
export const stills = [
  { t: 3.2, mood: 'content', caption: 'You’re working.' },
  { t: 14.4, mood: 'disappointed', caption: '{name} notices.' },
  { t: 19.6, mood: 'happy', caption: 'That counts.' },
];

// The tab-leave moment picks the loop up here, in the close-up: a beat of the sad
// face, the pointer heading back to the work, then the comeback, as the visitor's own.
export const WELCOME_FROM = 14.2;
// When the visitor has been watching the close-up all along (the pointer left, but
// the page stayed in sight), their comeback answers sooner: the face lifts just
// over half a second after they're back.
export const WELCOME_SOON = 15.2;

// The companion's performance. Moments are named here and resolved to clips by the
// companion (companions.js). Transitions (`sad`, `perk`, `settle`) are the seams
// between moods, so nothing cuts mid-motion.
export const cues = [
  { at: 0.6, moment: 'hello', loops: 'first' },  // the greeting: once per page load, and when another companion takes the corner
  { at: 1.5, moment: 'glance', loops: 'later' },
  { at: 4.4, moment: 'slowBlink' },
  { at: 7.7, moment: 'notice' },                  // a sniff: a new window has come forward
  { at: 11.3, moment: 'sad' },                    // after the feed has had the stage: a sad little face, as the camera pushes in
  { at: 15.75, moment: 'perk' },                  // the work window is back in front; the camera pulls back
  { at: 18.65, moment: 'cheer' },                 // the piece lands beside it at 19 s, in the same glance
  { at: 22.0, moment: 'settle' },
  { at: 23.75, moment: 'blink' },                 // across the seam, so the loop never sits still
];

// The hello's loop is the first, or the one a newly picked companion starts with
// (live-demo.js); the glance stands in for it in every other loop.
export const cueRuns = (cue, loop, helloLoop = 0) => cue.loops === 'first' ? loop === helloLoop : cue.loops === 'later' ? loop !== helloLoop : true;

// Where a newly picked companion picks up the loop: just before its hello, so it
// greets you, then acts out the drift and the comeback.
export const PICKED_AT = .3;

// The day, sped up. Work runs as a time-lapse; the drift runs only 7x, so the
// companion's reactions keep the app's real order (BehaviorLadder.swift): sad after
// the grace second, and the drift ends before the one-minute mark where Moku would
// turn cross. The menu bar says "sped up" throughout.
export const DRIFT_STARTS = 7.6;
export const RETURN_CLICK = 15.65;
export const PIECE_LANDS = 19;
export const COMEBACK_COUNTED = 15.85;
const START = { clock: (10 * 60 + 41) * 60, focus: 151 * 60, comebacks: 2 };
const WORK_RATE = 60;
const DRIFT_RATE = 7;
const focusBeforeDrift = START.focus + DRIFT_STARTS * WORK_RATE;
// Fast enough that the 16th piece lands exactly at 2h 40m, when the beat says it does.
const RETURN_RATE = (160 * 60 - focusBeforeDrift) / (PIECE_LANDS - RETURN_CLICK);
export const lapse = [
  { from: 0, to: DRIFT_STARTS, rate: WORK_RATE, focused: true },
  { from: DRIFT_STARTS, to: RETURN_CLICK, rate: DRIFT_RATE, focused: false },
  { from: RETURN_CLICK, to: PIECE_LANDS, rate: RETURN_RATE, focused: true },
  { from: PIECE_LANDS, to: LOOP, rate: 10, focused: true },
];

export function dayAt(t) {
  let clock = START.clock, focus = START.focus, drift = 0;
  for (const { from, to, rate, focused } of lapse) {
    const seconds = Math.max(0, Math.min(t, to) - from) * rate;
    clock += seconds;
    if (focused) focus += seconds; else drift += seconds;
  }
  const focusMinutes = Math.floor(focus / 60 + 1e-9);
  return {
    clock, focusMinutes, driftSeconds: drift,
    comebacks: START.comebacks + (t >= COMEBACK_COUNTED ? 1 : 0),
    house: houseProgress(focusMinutes),
  };
}

// What the menu bar and the home chip show: they change only at the payoff, when the
// piece lands (one focal point at a time). Before it, the minute before the 16th
// piece; after it, 2h 40m, the comeback counted and the clock a minute on.
export function shownDay(t) {
  const before = dayAt(PIECE_LANDS - 1e-3);
  const minute = Math.floor(before.clock / 60) * 60;
  if (t < PIECE_LANDS) return { ...before, clock: minute, comebacks: START.comebacks };
  const after = dayAt(PIECE_LANDS);
  return { ...after, clock: minute + 60, comebacks: START.comebacks + 1 };
}

export const formatClock = (seconds) => {
  const minutes = Math.floor(seconds / 60);
  return `Tue ${Math.floor(minutes / 60)}:${String(minutes % 60).padStart(2, '0')}`;
};
export const formatFocus = (minutes) => `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, '0')}m`;

// The scenes: one kind of work each, two or three real apps laid out side by side,
// on the same beats, so the companion's performance and the day are the same in
// every one. The drift is the same everywhere: a social feed in the browser behind
// the work. Track names say how the stage binds them (live-demo.js):
//   front            the frontmost window        caret        the typed block holding the caret
//   type:<id>        typed fraction, 0 to 1      scroll:<id>  scrolled percent
//   state:<id>       a data-<id> on the scene    var:<id>     a --<id> on the scene (CSS uses it)
//   text:<id>        the text of [data-text=<id>]
// Every scene: the work moves between its windows; a click on the browser's tab
// peeking out behind them brings the feed forward at 7.5 s, and it's scrolled in the
// wide shot; a click on the work brings it back at 15.72 s. The work picks up again
// at about 19.4 s, after the payoff, so the companion's cheer and the piece landing
// beside it have the stage to themselves.
const steps = (...keys) => ({ kind: 'step', keys });
const ramps = (...segments) => ({ kind: 'ramp', segments });
export const FEED_FRONT = 7.5;
export const WORK_FRONT = 15.72;
const front = (work, ...between) => steps([0, work], ...between, [FEED_FRONT, 'browser'], [WORK_FRONT, work]);
const toDrift = [
  { from: 6.95, to: 7.45, target: 'tab', click: true },
  { from: 7.75, to: 8.2, target: 'drift-rest' },
];
const toWork = { from: 15.0, to: 15.6, target: 'work-click', click: true };
// The feed: the stories and the first post for a moment, then three flicks of a
// trackpad, each easing out like momentum scrolling, until the camera moves.
const flicks = (distance) => ramps(
  [8.55, 9.35, 0, distance, 'out'], [9.5, 10.3, distance, distance * 2, 'out'], [10.4, 11.15, distance * 2, distance * 3, 'out'],
);
const FEED = 'scroll:feed';

export const scenes = {
  // An essay in Google Docs, its outline in Notes, a word looked up in Dictionary.
  writing: {
    id: 'writing',
    label: 'Writing',
    doing: 'Writing an essay',
    backTo: 'The essay again',
    apps: { doc: 'Google Chrome', notes: 'Notes', browser: 'Google Chrome' },
    work: 'doc',
    tracks: {
      front: front('doc', [4.0, 'notes'], [6.25, 'doc']),
      'type:p2': ramps([0.3, 3.35, 0, 1]),
      'state:tick': steps([0, 'open'], [4.0, 'done']),
      'type:n1': ramps([4.3, 5.6, 0, 1]),
      'type:p3': ramps([19.45, 22.9, 0, 1]),
      caret: steps([0, 'p2'], [4.0, 'n1'], [6.25, 'p2'], [19.4, 'p3']),
      [FEED]: flicks(15),
    },
    // Hidden while typing, as macOS hides it.
    cursor: {
      rest: 'work-click',
      hidden: [[0, 3.45], [4.25, 5.65], [19.4, LOOP]],
      moves: [
        { from: 3.5, to: 3.95, target: 'notes-tick', click: true },
        { from: 5.7, to: 6.2, target: 'work-click', click: true },
        ...toDrift,
        toWork,
      ],
    },
    // Tracks whose end differs from their start; their elements fade through the seam.
    seam: ['type:p2', 'state:tick', 'type:n1', 'type:p3', 'caret', FEED],
  },

  // An app screen in Figma, a reference board in Preview: the button is selected,
  // nudged up three times and filled; a reference is looked at; back, the title is retyped.
  design: {
    id: 'design',
    label: 'Design',
    doing: 'Designing an app screen',
    backTo: 'The screen again',
    apps: { canvas: 'Figma', refs: 'Preview', browser: 'Google Chrome' },
    work: 'canvas',
    tracks: {
      front: front('canvas', [4.65, 'refs'], [6.05, 'canvas']),
      'state:sel': steps([0, 'none'], [0.32, 'button'], [4.1, 'none'], [19.65, 'title'], [22.2, 'none']),
      'var:nudge': steps([0, 0], [1.2, 1], [1.5, 2], [1.8, 3]),
      'text:y': steps([0, '412'], [1.2, '404'], [1.5, '396'], [1.8, '388']),
      'state:picker': steps([0, 'closed'], [2.62, 'open'], [3.72, 'closed']),
      'state:fill': steps([0, 'grey'], [3.42, 'green']),
      'state:ref': steps([0, 'none'], [4.65, 'on']),
      'state:title': steps([0, 'old'], [19.65, 'selected'], [20.0, 'new']),
      'type:dtitle': ramps([20.05, 21.9, 0, 1]),
      caret: steps([0, 'dtitle']),
      [FEED]: flicks(15),
    },
    cursor: {
      rest: 'cv-rest',
      hidden: [[20.0, 22.1]],
      moves: [
        { from: 0.05, to: 0.3, target: 'cv-button', click: true },
        { from: 0.55, to: 0.95, target: 'cv-rest' },
        { from: 2.2, to: 2.6, target: 'cv-fill', click: true },
        { from: 3.0, to: 3.4, target: 'cv-swatch', click: true },
        { from: 4.1, to: 4.6, target: 'ref-tile', click: true },
        { from: 5.5, to: 6.0, target: 'cv-rest', click: true },
        ...toDrift,
        toWork,
        { from: 19.4, to: 19.62, target: 'cv-title', click: true },
        { from: 22.25, to: 22.85, target: 'cv-rest' },
      ],
    },
    seam: ['var:nudge', 'text:y', 'state:fill', 'state:ref', 'state:title', 'type:dtitle', FEED],
  },

  // Code in Cursor, tests in Terminal, the docs in the browser: a fix typed, the
  // tests run and pass; back, the next function.
  code: {
    id: 'code',
    label: 'Code',
    doing: 'Fixing a bug',
    backTo: 'The code again',
    apps: { editor: 'Cursor', term: 'Terminal', browser: 'Google Chrome' },
    work: 'editor',
    tracks: {
      front: front('editor', [5.25, 'term']),
      'type:c1': ramps([0.3, 2.45, 0, 1]),
      'type:c2': ramps([2.65, 4.6, 0, 1]),
      'type:cmd': ramps([5.45, 5.95, 0, 1]),
      'var:out': steps([0, 0], [6.15, 1], [6.35, 2], [6.55, 3], [6.75, 4], [6.95, 5], [7.1, 6], [7.25, 7]),
      'type:c3': ramps([19.5, 21.2, 0, 1]),
      'type:c4': ramps([21.35, 22.6, 0, 1]),
      caret: steps([0, 'c1'], [2.55, 'c2'], [5.25, 'cmd'], [19.45, 'c3'], [21.3, 'c4']),
      [FEED]: flicks(15),
    },
    // Hidden while typing; the click that brings the work back lands in the editor.
    cursor: {
      rest: 'work-click',
      hidden: [[0, 4.75], [5.4, 6.1], [19.4, LOOP]],
      moves: [
        { from: 4.8, to: 5.2, target: 'term-click', click: true },
        ...toDrift,
        toWork,
      ],
    },
    seam: ['type:c1', 'type:c2', 'type:cmd', 'var:out', 'type:c3', 'type:c4', 'caret', FEED],
  },

  // A lecture's slides in Preview, notes typed in Notes: a highlight, a note; back,
  // another highlight and another note.
  study: {
    id: 'study',
    label: 'Study',
    doing: 'Studying for a quiz',
    backTo: 'The lecture again',
    apps: { reader: 'Preview', notes: 'Notes', browser: 'Google Chrome' },
    work: 'reader',
    tracks: {
      front: steps([0, 'reader'], [1.8, 'notes'], [4.95, 'reader'], [FEED_FRONT, 'browser'], [WORK_FRONT, 'reader'], [20.85, 'notes'], [23.65, 'reader']),
      'var:hl1': ramps([0.45, 1.35, 0, 1]),
      'type:n1': ramps([2.0, 4.4, 0, 1]),
      'var:hl2': ramps([19.65, 20.35, 0, 1]),
      'type:n2': ramps([20.95, 23.0, 0, 1]),
      caret: steps([0, 'n1'], [20.85, 'n2']),
      [FEED]: flicks(15),
    },
    cursor: {
      rest: 'rd-rest',
      hidden: [[1.95, 4.45], [20.9, 23.1]],
      moves: [
        { from: 0.1, to: 0.4, target: 'hl1-start' },
        { from: 0.45, to: 1.35, target: 'hl1-end' },   // the drag that highlights
        { from: 1.45, to: 1.75, target: 'notes-click', click: true },
        { from: 4.5, to: 4.9, target: 'rd-rest', click: true },
        ...toDrift,
        toWork,
        { from: 19.4, to: 19.6, target: 'hl2-start' },
        { from: 19.65, to: 20.35, target: 'hl2-end' },
        { from: 20.45, to: 20.8, target: 'notes-click', click: true },
        { from: 23.15, to: 23.6, target: 'rd-rest', click: true },
      ],
    },
    seam: ['var:hl1', 'type:n1', 'var:hl2', 'type:n2', 'caret', FEED],
  },
};

// The kinds of work, in the picker's order. A visit plays one kind of work, loop
// after loop, with no timer on show, until the visitor picks another: live-demo.js
// draws one per tab session (nothing is kept beyond it).
export const sceneOrder = ['writing', 'design', 'code', 'study'];
export const scene = scenes.writing;
export const workForVisit = (visit) => sceneOrder[((Math.floor(visit) % sceneOrder.length) + sceneOrder.length) % sceneOrder.length] ?? sceneOrder[0];

const easings = {
  linear: (p) => p,
  out: (p) => 1 - (1 - p) ** 3,
  inOut: (p) => p < .5 ? 4 * p ** 3 : 1 - (-2 * p + 2) ** 3 / 2,
};

export function trackValue(track, t) {
  if (track.kind === 'step') {
    let value = track.keys[0][1];
    for (const [time, next] of track.keys) if (t >= time) value = next;
    return value;
  }
  if (track.kind === 'ramp') {
    let value = track.segments[0][2];
    for (const [from, to, start, end, ease = 'linear'] of track.segments) {
      if (t >= to) value = end;
      else if (t >= from) return start + (end - start) * easings[ease]((t - from) / (to - from));
    }
    return value;
  }
  throw new Error(`Unknown track kind: ${track.kind}`);
}

// Whether a typing ramp is mid-word at t: a typing caret is solid, an idle one blinks.
export function isTyping(track, t) {
  return track.kind === 'ramp' && track.segments.some(([from, to]) => t >= from && t < to);
}

// The pointer between two named targets (the stage measures where they are), with
// a press and a fading ring for each click.
export function cursorAt(cursor, t) {
  let from = cursor.rest, to = cursor.rest, progress = 1, press = 0, clickAge = -1;
  for (const move of cursor.moves) {
    if (t < move.from) break;
    from = to;
    to = move.target;
    progress = t >= move.to ? 1 : easings.inOut((t - move.from) / (move.to - move.from));
    if (move.click && t >= move.to && t < move.to + .18) press = Math.sin((t - move.to) / .18 * Math.PI);
    if (move.click && t >= move.to && t < move.to + .45) clickAge = t - move.to;
  }
  // Visibility eases over a tenth of a second at the edges of each hidden range.
  let visible = 1;
  for (const [start, end] of cursor.hidden) {
    if (t >= start && t < end) {
      const fadeOut = start > 0 ? Math.max(0, 1 - (t - start) / .1) : 0;
      const fadeIn = end < LOOP ? Math.max(0, 1 - (end - t) / .1) : 0;
      visible = Math.max(fadeOut, fadeIn);
    }
  }
  return { from, to, progress, press, clickAge, visible };
}

export function sceneAt(scene, t) {
  const values = {};
  const typing = {};
  for (const [name, track] of Object.entries(scene.tracks)) {
    values[name] = trackValue(track, t);
    if (name.startsWith('type:')) typing[name] = isTyping(track, t);
  }
  return { values, typing, cursor: cursorAt(scene.cursor, t), app: scene.apps[values.front] };
}

// Opacity for whatever changes between the loop's end and start: out over the
// last half second, in over the first third. The very first start doesn't fade in.
export function seamOpacity(t, firstLoop = false) {
  const out = LOOP - .5;
  if (t >= out) return 1 - easings.inOut((t - out) / .5);
  if (!firstLoop && t < .35) return easings.inOut(t / .35);
  return 1;
}
