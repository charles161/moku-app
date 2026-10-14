import house from './house-data.json' with { type: 'json' };
import { plan } from './loading-plan.js';

// A companion is data: its clips for each moment of the loop, its theme and its
// home. The demo, its stills, the home chip and the home section read only this
// (docs/specs/moku-and-friends.md). Moku is the default; Tetsu joins the switcher
// once its clips are exported (scripts/export-motion.py --companion tetsu),
// and their home section once their home's renders are in public/images/house/<id>/.
//
// Moments with `from`/`to` change the mood and are the loop's seams; the others
// play inside one mood. Every clip is the app's own render (scripts/export-motion.py),
// under the same names for every companion.

// Tetsu's talent: its display scans (the clip) as its beam sweeps (live-demo.js).
const scan = { clip: 'content-scan', mood: 'content', talent: 'scan' };

const moments = (hello) => ({
  hello: { clip: 'content-wave', mood: 'content', line: hello },  // the app's hello
  glance: { clip: 'content-glance', mood: 'content' },
  slowBlink: { clip: 'content-slow-blink', mood: 'content' },
  notice: { clip: 'content-nose', mood: 'content' },  // the sniff of a new window (next-wave.md §2)
  sad: { clip: 'content-to-disappointed', from: 'content', to: 'disappointed' },
  perk: { clip: 'disappointed-to-happy', from: 'disappointed', to: 'happy' },
  cheer: { clip: 'happy-head', mood: 'happy' },
  proud: { clip: 'happy-ear-left', mood: 'happy' },
  settle: { clip: 'happy-to-content', from: 'happy', to: 'content' },
  blink: { clip: 'content-blink', mood: 'content' },
  // The tab-leave moment's comeback, in place of the cheer: the same bob, and a word.
  welcome: { clip: 'happy-head', mood: 'happy', line: 'There you are!' },
  // The tab-leave moment's other turn: the face falls from a cheer, too.
  fall: { clip: 'happy-to-disappointed', from: 'happy', to: 'disappointed' },
  // Waiting for you to come back: a blink now and then.
  waitingBlink: { clip: 'disappointed-blink', mood: 'disappointed' },
});

// Clips only the tab-leave moment plays; they load after the loop's (live-demo.js).
export const awayClips = (companion) => ['fall', 'waitingBlink'].map((name) => companion.moments[name]?.clip).filter(Boolean);

// Moku's clips sit at the top of /motion; a companion's in /motion/<id>/. A still comes
// in the size the visit's clips do (loading-plan.js): <mood>-idle.320.webp beside each.
const motion = (folder) => {
  const base = folder ? `/motion/${folder}` : '/motion';
  return { manifest: `${base}/manifest.json`, poster: (mood, clips = plan.clips) => `${base}/${mood}-idle${clips === 'full' ? '' : `.${clips}`}.webp` };
};
const renders = (folder) => (minutes) => `/images/house/${folder ? `${folder}/` : ''}${String(minutes).padStart(3, '0')}.webp`;
// The same renders, 160 px wide (scripts/house-thumbs.py): the hero's home chip and the piece that lands.
const thumbs = (folder) => (minutes) => `/images/house/${folder ? `${folder}/` : ''}thumb/${String(minutes).padStart(3, '0')}.webp`;
const stages = (names) => names.map((name, i) => ({ name, first: house.stages[i].first }));

export const companions = {
  moku: {
    id: 'moku',
    name: 'Moku',
    kind: 'a small ivory bunny',
    // What it is in a word or two, as the app's welcome and Settings say it (Companion.kind).
    species: 'bunny',
    // Who it is, for "Who'd you like to work with?" (moku-and-friends.md). Only built
    // talents are claimed: Moku's are still being made (next-wave.md §2).
    personality: 'Gentle, a little anxious for you, and overjoyed when you’re back.',
    talent: null,
    // Tetsu is on home but not in the download yet (0.1.7 has Moku alone). Delete
    // `arriving` once the release with Tetsu is out.
    arriving: null,
    icon: '#bunny',  // the menu bar symbol, in index.html's SVG definitions
    motion: motion(),
    moods: ['content', 'disappointed', 'happy'],
    restingMood: 'content',
    moments: moments('Hi! I’m Moku.'),
    // Read by the stills, and by the stage label for screen readers.
    describe: {
      content: 'Moku, a small ivory bunny, sits contentedly in the corner',
      disappointed: 'Moku looks up at you with a sad little face',
      happy: 'Moku beams, eyes closed in a smile, ears up',
    },
    // The website's palette (MEMORY.md): the page, then the demo's desk. Each
    // companion sets every key, so switching back restores Moku's exactly.
    theme: {
      '--paper': '#f7f5ee',
      '--green': '#344633',
      '--world': '#303f30',
      '--companion-accent': '#344633',
      '--companion-progress': '#344633',
      '--desk-wall-top': '#eef0e3',
      '--desk-wall-bottom': '#c3cfb0',
      '--desk-hill': '#a9b994',
      '--desk-hill-far': '#cdd6bd',
    },
    home: {
      name: 'Today’s house',
      builds: 'Builds a cottage',
      // The day's 24-piece cottage, one piece per 10 focused minutes (house-data.json).
      image: renders(),
      thumb: thumbs(),
      stages: house.stages,
      pieceNames: house.pieceNames,
      // The home section's live 3D diorama is the cottage's (public/models).
      model: true,
      pitch: 'A beam. A window. A light left on for you. Every 10 focused minutes builds a little more of Moku’s home. A new house, every day.',
      finished: 'The lights are on. Moku’s home is finished for today.',
      finishedAlt: 'Moku’s finished daily cottage, with a teal tiled roof, a porch, flowers, a white fence, and glowing windows',
    },
  },

  tetsu: {
    id: 'tetsu',
    name: 'Tetsu',
    kind: 'a small desk robot',
    species: 'desk robot',
    personality: 'Earnest, logical and quietly loyal. Your focus is its mission.',
    // RobotTalents.swift: the scan beam while it reads your window, the hologram when a piece lands.
    talent: 'Scans your window with a thin beam of light, and projects today’s rocket over its head when a piece lands.',
    arriving: null,  // in 0.1.8
    icon: '#home',  // the app's menu bar shows a house for every companion
    motion: motion('tetsu'),
    moods: ['content', 'disappointed', 'happy'],
    restingMood: 'content',
    // While you work, Tetsu scans your window once a loop: its display narrows and
    // sweeps (the clip) as the beam crosses the work. In place of the glance, so it
    // scans right after the work changes; in the loop that opens with its hello, in
    // place of the slow blink, after the hello.
    moments: { ...moments('Hi! I’m Tetsu.'), glance: scan },
    helloMoments: { slowBlink: scan },
    // The beam on the site (RobotTalents.swift's ScanBeam, made a clear moment): how
    // long it lasts, how far it reaches at least (in hundredths of the corner's width;
    // further when a wide desk sets the work further off) and its sweep, from high on
    // the window to its foot, in degrees above the line to the left. Its one place:
    // match the app's here when it changes (tetsu-perfect).
    scanBeam: { seconds: 2.2, reach: 122, from: 38, to: -12 },
    describe: {
      content: 'Tetsu, a small desk robot, sits in the corner, its eyes glowing softly behind its visor',
      disappointed: 'Tetsu looks up at you, its eyes tilted into a sad little frown',
      happy: 'Tetsu beams, its eyes curved into happy arcs, antennae up',
    },
    // The page keeps the warm paper and forest green whoever is picked (Charles, 2026-10-04: the cool page wasn't
    // "premium"); Tetsu's own colours are inside the demo's screen (slate desk, an amber accent) and in small monospace
    // labels (style.css).
    theme: {
      '--paper': '#f7f5ee',
      '--green': '#344633',
      '--world': '#303f30',
      '--companion-accent': '#2f3a40',
      '--companion-progress': '#e0a243',
      '--desk-wall-top': '#eef1f1',
      '--desk-wall-bottom': '#c5ced2',
      '--desk-hill': '#a5b0b6',
      '--desk-hill-far': '#cdd4d7',
    },
    home: {
      name: 'Today’s rocket',
      builds: 'Builds a rocket on its launch pad',
      image: renders('tetsu'),
      thumb: thumbs('tetsu'),
      // The app's hologram of the rocket, as far as it's built (assets/world/tetsu/hologram/stage-<1…5>.png).
      hologram: (stage) => `/images/house/tetsu/hologram/stage-${stage}.png`,
      stages: stages(['The pad', 'The gantry', 'The hull', 'Fins & nose', 'Launch-ready']),
      pieceNames: ['the chalk ring', 'the concrete pad', 'the hazard stripes', 'the launch ring', 'the gantry legs', 'the gantry top',
        'the crew walkway', 'the fuel lines', 'the engine', 'the lower hull', 'the upper hull', 'the round hatch', 'the portholes',
        'the amber bands', 'the left fin', 'the right fin', 'the back fin', 'the nose cone', 'the beacon', 'the pad lights',
        'the countdown clock', 'the radio dish', 'the mission flag', 'the finishing touches'],
      model: false,
      pitch: 'A pad. A gantry. A nose cone pointing up. Every 10 focused minutes builds a little more of Tetsu’s rocket. A new rocket, every day.',
      finished: 'The beacon is on. Tetsu’s rocket is ready for today.',
      finishedAlt: 'Tetsu’s finished daily rocket on its launch pad, under its gantry, with portholes, fins and a beacon on top',
    },
  },
};

export const defaultCompanion = companions.moku;

// The companions this build can show, Moku first: another one only once its clips
// are exported (`files[id].clips`). Its home section needs its renders too
// (`files[id].home`); until then it keeps the cottage, as the app does.
export function availableCompanions(files = {}) {
  return Object.values(companions)
    .filter((companion) => companion === defaultCompanion || files[companion.id]?.clips)
    .map((companion) => (companion === defaultCompanion || files[companion.id]?.home ? companion : { ...companion, home: cottageFor(companion) }));
}

// The cottage, built by another companion while its own home isn't exported yet.
function cottageFor({ name }) {
  const { home } = defaultCompanion;
  return { ...home, pitch: home.pitch.replace('Moku’s', `${name}’s`), finished: home.finished.replace('Moku’s', `${name}’s`), finishedAlt: home.finishedAlt.replace('Moku’s', `${name}’s`) };
}

// The moments a loop plays: the companion's own, and in the loop that opens with its
// hello, that loop's changes (Tetsu scans after its hello, not in place of a glance).
export const momentsFor = (companion, { hello = false } = {}) => (hello && companion.helloMoments ? { ...companion.moments, ...companion.helloMoments } : companion.moments);

// Every clip a companion needs for its loops, in the order a loop first uses them.
export function clipsFor(companion, cues) {
  const names = [];
  for (const { moment } of cues) {
    for (const set of [companion.moments, companion.helloMoments ?? {}]) {
      const clip = set[moment]?.clip;
      if (clip && !names.includes(clip)) names.push(clip);
    }
  }
  return names;
}
