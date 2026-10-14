import { LOOP, cues, cueRuns } from './demo-timeline.js';
import { NativeMotion, loadMotion } from './native-motion.js';
import { momentsFor } from './companions.js';

// A gesture this late no longer belongs to its moment, so it's skipped.
export const LATE = .45;

// What the companion does next. A playing clip is never interrupted (the caller
// only asks when idle). A mood change always plays, even late, because the moods
// after it depend on it; a gesture plays only near its time and in its own mood.
// Anything that can't play is skipped, so the performance re-aligns within a loop.
export function nextCue({ elapsed, position, mood, moments, helloLoop = 0 }) {
  let { loop, index } = position;
  for (let checked = 0; checked <= cues.length; checked++) {
    if (index >= cues.length) { loop += 1; index = 0; }
    const cue = cues[index];
    const at = loop * LOOP + cue.at;
    if (at > elapsed) return { action: 'wait', position: { loop, index } };
    const moment = moments[cue.moment];
    const after = { loop, index: index + 1 };
    if (moment && cueRuns(cue, loop, helloLoop)) {
      if (moment.from ? moment.from === mood : moment.mood === mood && elapsed - at <= LATE) {
        return { action: 'play', cue, moment, at, position: after, replay: { loop, index } };
      }
    }
    index += 1;
  }
  return { action: 'wait', position: { loop, index } };
}

// How long a word stays up when its clip hasn't arrived (the hello's wave is 2.2 s).
export const LINE_ALONE_MS = 2200;
// While it waits for you, a sad companion blinks now and then, and is otherwise still.
export const WAITING_BLINK_MS = 4200;

// The moment that turns one mood into another, among a companion's moments.
export const turnFor = (moments, from, to) => Object.values(moments).find((moment) => moment.from === from && moment.to === to) ?? null;

// Plays the companion's side of the loop through its native clips.
export class CompanionActor {
  // `isReady(clip)` says whether a clip has arrived. One that hasn't is never waited
  // for: a mood change shows its new mood's still at once, so the companion is never
  // left sad once you're back, and a gesture is skipped (its word still shows).
  constructor(root, companion, { onLine, onTalent, isReady = () => true } = {}) {
    this.companion = companion;
    this.onLine = onLine;
    this.onTalent = onTalent;
    this.isReady = isReady;
    const { manifest, poster } = companion.motion;
    this.motion = new NativeMotion(root, (name) => loadMotion(name, manifest), poster);
    this.mood = companion.restingMood;
    this.position = { loop: 0, index: 0 };
    this.current = null;
    // The loop whose cheer is a welcome back (the tab-leave moment), and the loop
    // that starts with a hello (the first, or the one after a switch).
    this.welcomeLoop = -1;
    this.helloLoop = 0;
    // A live reaction outside the loop (the tab-leave moment, live-demo.js): turn to
    // a mood as soon as the current clip ends, then wait there. The loop's cues wait.
    this.live = null;
  }

  // The mood the companion is in, or is turning to in the clip that's playing.
  get heading() { return this.current?.to ?? this.mood; }

  // Turn to `mood` through the companion's own transition clip, once free. `onTurn`
  // runs as the turn begins (or at once if it's already there).
  react(mood, onTurn) {
    this.live = { mood, onTurn, turned: false, blinkAt: 0 };
  }

  update(elapsed) {
    // Its moods' stills go into memory as it starts, so no mood change waits on the network.
    if (!this.prepared) { this.prepared = true; this.motion.prepare(this.companion.moods); }
    if (this.motion.busy) return;
    if (this.live) return this.performLive();
    const moments = momentsFor(this.companion, { hello: this.position.loop === this.helloLoop });
    const welcome = this.position.loop === this.welcomeLoop && moments.welcome;
    const plan = nextCue({ elapsed, position: this.position, mood: this.mood, moments: welcome ? { ...moments, cheer: welcome } : moments, helloLoop: this.helloLoop });
    this.position = plan.position;
    if (plan.action !== 'play') return;
    if (this.isReady(plan.moment.clip)) this.start(plan);
    else this.skip(plan);
  }

  performLive() {
    const live = this.live, now = performance.now();
    if (this.mood !== live.mood) {
      const turn = turnFor(this.companion.moments, this.mood, live.mood);
      if (!turn) { this.show(live.mood); this.live = live; return this.turned(live); }
      this.turned(live);
      if (this.isReady(turn.clip)) this.start({ moment: turn });
      else this.skip({ moment: turn });
      return;
    }
    this.turned(live);
    const blink = this.companion.moments.waitingBlink;
    if (!live.blinkAt) live.blinkAt = now + WAITING_BLINK_MS;
    if (blink && now >= live.blinkAt) {
      live.blinkAt = now + WAITING_BLINK_MS * (.8 + Math.random() * .4);
      if (blink.mood === this.mood && this.isReady(blink.clip)) this.start({ moment: blink });
    }
  }

  turned(live) {
    if (live.turned) return;
    live.turned = true;
    live.onTurn?.();
  }

  skip({ moment }) {
    if (moment.to) {
      this.mood = moment.to;
      this.motion.setPoster(moment.to);
    }
    if (moment.line) {
      const word = this.word = {};
      this.onLine?.(moment.line);
      setTimeout(() => { if (word === this.word) this.onLine?.(null); }, LINE_ALONE_MS);
    }
  }

  start({ moment, replay }) {
    const current = this.current = { replay, to: moment.to };
    this.word = null;
    if (moment.line) this.onLine?.(moment.line);
    // A talent (Tetsu's scan beam) starts with its clip's first frame.
    this.motion.play(moment.clip, {
      onFinish: async () => {
        if (current !== this.current) return;
        this.current = null;
        if (moment.line) this.onLine?.(null);
        if (moment.to) {
          this.mood = moment.to;
          await this.motion.setPoster(moment.to);
        }
      },
    }).then((started) => { if (started && moment.talent && current === this.current) this.onTalent?.(moment.talent); });
  }

  // A paused demo shows a still. An interrupted clip plays again from its start,
  // from the mood it began in, so resuming never snaps.
  freeze() {
    if (this.current?.replay) this.position = this.current.replay;
    this.current = null;
    this.word = null;
    this.onLine?.(null);
    this.motion.cancel();
    this.motion.setPoster(this.mood);
  }

  // Another actor takes the corner (a new pick): this one stops, and nothing it started
  // lands after it.
  retire() {
    this.current = null;
    this.word = null;
    this.onLine?.(null);
    this.motion.retire();
  }

  // Stills and the first frame show a mood without any motion.
  show(mood) {
    this.freeze();
    this.mood = mood;
    this.motion.setPoster(mood);
  }
}
