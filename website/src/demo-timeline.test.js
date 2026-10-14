import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  LOOP, beats, beatAt, awayFor, cues, cueRuns, dayAt, shownDay, formatFocus, formatClock, scenes, sceneOrder, workForVisit,
  sceneAt, trackValue, cursorAt, seamOpacity, DRIFT_STARTS, RETURN_CLICK, PIECE_LANDS, PICKED_AT,
  CAMERA, cameraAt, cubicBezier, quietLine, stills, WELCOME_FROM, WELCOME_SOON, FEED_FRONT, WORK_FRONT,
  captions, captionAt, captionText, CAPTION_FADE,
} from './demo-timeline.js';
import { nextCue, LATE } from './demo-actor.js';
import { companions, clipsFor } from './companions.js';

const manifest = JSON.parse(readFileSync(new URL('../public/motion/manifest.json', import.meta.url)));
const moku = companions.moku;
const seconds = (moment) => manifest[moku.moments[moment].clip].duration / 1000;
const END = LOOP - 1e-6;

test('the three beats run in order and cover the whole loop', () => {
  assert.deepEqual(beats.map(({ id }) => id), ['work', 'drift', 'back']);
  assert.equal(beats[0].start, 0);
  assert.equal(beats.at(-1).end, LOOP);
  beats.slice(1).forEach((beat, index) => assert.equal(beat.start, beats[index].end));
  assert.equal(beatAt(0).id, 'work');
  assert.equal(beatAt(DRIFT_STARTS).id, 'drift');
  assert.equal(beatAt(RETURN_CLICK + .1).id, 'back');
  assert.equal(beatAt(END).id, 'back');
});

test('one quiet line: it invites the visitor to look away, and welcomes them back', () => {
  assert.equal(quietLine(moku), 'Look away. It’ll notice.');
  assert.equal(quietLine(moku, { state: 'away' }), 'Moku noticed you left.');
  assert.equal(quietLine(companions.tetsu, { state: 'away' }), 'Tetsu noticed you left.');
  assert.equal(quietLine(moku, { state: 'back', away: awayFor(14.3) }), 'Gone 14 seconds. You came back.');
  assert.equal(quietLine(moku, { state: 'back', away: null }), 'You came back.', 'a blink away is no time at all');
});

const cue = (moment) => cues.find((item) => item.moment === moment);
const sadFormed = cue('sad').at + 1.4;  // Moku's face has fallen 1.3 s into its clip, Tetsu's 1.75 s

test('the camera: a wide shot, a push-in on the falling face, a still hold, a pull-back on the comeback', () => {
  const [inFrom, inTo] = CAMERA.pushIn, [outFrom, outTo] = CAMERA.pullBack;
  assert.equal(cameraAt(0), 0);
  assert.equal(cameraAt(END), 0, 'the loop seam is a wide shot at both ends');
  assert.equal(cameraAt(DRIFT_STARTS + .9), 0, 'the screen has greyed before the camera moves');
  assert.ok(inTo - inFrom >= 1.8 && inTo - inFrom <= 2.2, 'the push-in takes about 2 s');
  assert.ok(outTo - outFrom >= 1.5 && outTo - outFrom <= 2, 'the pull-back takes 1.5 to 2 s');
  assert.ok(cue('sad').at > inFrom && cue('sad').at < inTo, 'the face falls as the camera pushes in');
  assert.ok(outFrom - sadFormed >= 1.9, `the sad face holds ${(outFrom - sadFormed).toFixed(1)} s in the close-up`);
  for (let t = inTo; t < outFrom; t += .01) assert.equal(cameraAt(t), 1, `still at ${t.toFixed(2)}`);
  assert.equal(outFrom, RETURN_CLICK + .07, 'the camera pulls back as the work window comes forward');
  assert.ok(Math.abs(cue('perk').at - outFrom) <= .1, 'and the face lifts with it');
  assert.ok(PIECE_LANDS - outTo >= 1.2, 'a clear beat of being back in the wide shot before the payoff');
  assert.ok(cue('cheer').at - outTo >= 1, 'and before the cheer');
  assert.ok(PIECE_LANDS > outTo && PIECE_LANDS - cue('cheer').at < .5, 'the piece lands in the wide shot, as the cheer begins');
  assert.ok(PIECE_LANDS < cue('cheer').at + manifest[moku.moments.cheer.clip].duration / 1000, 'while the companion still cheers');
  assert.equal(cameraAt(WELCOME_FROM), 1, 'the tab-leave moment picks up in the close-up');
  assert.ok(WELCOME_FROM >= sadFormed, 'with the face already sad');
  assert.ok(CAMERA.pullBack[0] - WELCOME_FROM >= 1.2, 'a beat of it before the comeback, back from out of sight');
  assert.equal(cameraAt(WELCOME_SOON), 1);
  assert.ok(cue('perk').at - WELCOME_SOON <= .6, 'watched all along, the face lifts within 0.6 s of your return');
});

test('the drift is seen before the camera moves: the feed comes forward and is scrolled in the wide shot', () => {
  const [inFrom] = CAMERA.pushIn;
  assert.ok(inFrom - FEED_FRONT >= 3.5, `the feed has the wide shot for ${(inFrom - FEED_FRONT).toFixed(1)} s`);
  for (const scene of Object.values(scenes)) {
    const scroll = scene.tracks['scroll:feed'];
    const [first] = scroll.segments, last = scroll.segments.at(-1);
    assert.ok(first[0] - FEED_FRONT >= .8, `${scene.id}: the stories and the first post are seen before it scrolls`);
    assert.ok(last[1] - first[0] >= 2.5 && last[1] <= inFrom, `${scene.id}: about 3 s of scrolling, all of it in the wide shot`);
  }
  assert.ok(cue('notice').at > FEED_FRONT && cue('notice').at < FEED_FRONT + .5, 'the companion sniffs as the feed comes forward');
});

test('the captions: one at a time, never while the camera closes in, the noticing one in the close-up', () => {
  for (const [a, b] of captions.slice(1).map((caption, i) => [captions[i], caption])) assert.ok(a.to <= b.from, `${a.id} is gone before ${b.id}`);
  const [inFrom, inTo] = CAMERA.pushIn;
  for (let t = 0; t < LOOP; t += .01) {
    const shown = captionAt(t);
    if (!shown) continue;
    assert.ok(t < inFrom || t >= inTo, `no caption while the camera pushes in (${shown.id} at ${t.toFixed(2)})`);
    assert.ok(shown.opacity >= 0 && shown.opacity <= 1);
    if (shown.place === 'centre') assert.equal(cameraAt(t) < 1, true, `${shown.id}: a centred caption is never over the close-up`);
  }
  const at = (id) => captions.find((caption) => caption.id === id);
  assert.ok(at('working').from < 1 && at('working').to <= DRIFT_STARTS, 'working, from the first second');
  assert.ok(at('drifting').from > FEED_FRONT + .5 && at('drifting').to <= inFrom, 'drifting, once the feed is seen, gone before the camera moves');
  for (let t = at('noticed').from; t < at('noticed').to; t += .05) assert.equal(cameraAt(t), 1, 'noticed, held in the close-up');
  assert.equal(at('noticed').place, 'top', 'above the face, never on it');
  assert.ok(at('back').from >= CAMERA.pullBack[0] + 1 && at('back').to <= PIECE_LANDS, 'back to focus, as the camera settles, gone as the piece lands');
  assert.equal(captionAt(at('working').from + CAPTION_FADE.in).opacity, 1);
  assert.ok(captionAt(at('working').from).opacity < .01, 'it fades in from nothing');
  assert.equal(captionAt(at('noticed').from + 1, { skip: ['noticed'] }), null, 'the tab-leave moment leaves it out');
  for (const scene of Object.values(scenes)) {
    assert.ok(captionText('working', { companion: moku, scene }).detail, `${scene.id}: says what the work is`);
    assert.ok(captionText('back', { companion: moku, scene }).word === 'Back to focus');
  }
  assert.equal(captionText('noticed', { companion: companions.tetsu, scene: scenes.code }).word, 'Tetsu noticed');
});

test('the camera never jumps: every 60 fps frame moves it a little, and it starts and stops gently', () => {
  let largest = 0;
  for (let t = 0; t < LOOP; t += 1 / 240) {
    const step = Math.abs(cameraAt(t + 1 / 60) - cameraAt(t));
    largest = Math.max(largest, step);
  }
  assert.ok(largest < .06, `the largest step in a frame is ${largest.toFixed(4)} of the move`);
  const [inFrom, inTo] = CAMERA.pushIn, [outFrom, outTo] = CAMERA.pullBack;
  const firstFrame = (from, sign) => Math.abs(cameraAt(from + 1 / 60) - cameraAt(from)) * sign;
  assert.ok(firstFrame(inFrom, 1) < .002 && Math.abs(1 - cameraAt(inTo - 1 / 60)) < .002, 'the push-in eases in and out');
  assert.ok(Math.abs(cameraAt(outFrom + 1 / 60) - 1) < .003, 'the pull-back starts gently');
  assert.ok(firstFrame(outFrom, 1) < .003, 'the pull-back leaves the hold softly, without a jolt');
  assert.ok(cameraAt(outTo - 1 / 60) < .003, 'and settles into the wide shot');
  const ease = cubicBezier(.42, 0, .58, 1);
  assert.equal(ease(0), 0);
  assert.equal(ease(1), 1);
  assert.ok(Math.abs(ease(.5) - .5) < 1e-6);
});

test('the payoff has the stage: nothing new starts in the work between the comeback and the piece', () => {
  for (const scene of Object.values(scenes)) {
    for (const [name, track] of Object.entries(scene.tracks)) {
      if (name === 'front' || name === 'caret') continue;
      const starts = track.kind === 'step' ? track.keys.slice(1).map(([time]) => time) : track.segments.map(([from]) => from);
      for (const time of starts) assert.ok(time <= RETURN_CLICK || time >= PIECE_LANDS + .35, `${scene.id}: ${name} starts at ${time}s`);
    }
    for (const move of scene.cursor.moves) {
      if (move.from > RETURN_CLICK) assert.ok(move.from >= PIECE_LANDS + .35, `${scene.id}: the pointer moves at ${move.from}s`);
    }
  }
});

test('the menu bar and the home chip change only at the payoff', () => {
  const before = shownDay(0), after = shownDay(PIECE_LANDS);
  for (let t = 0; t < PIECE_LANDS; t += .05) assert.deepEqual(shownDay(t), before, `unchanged at ${t.toFixed(2)}`);
  for (let t = PIECE_LANDS; t < LOOP; t += .05) assert.deepEqual(shownDay(t), after, `unchanged at ${t.toFixed(2)}`);
  assert.equal(formatFocus(before.focusMinutes), '2h 39m');
  assert.equal(formatFocus(after.focusMinutes), '2h 40m', 'the 16th piece lands at 2h 40m');
  assert.equal(before.house.built, 15);
  assert.equal(after.house.built, 16);
  assert.equal(after.comebacks, before.comebacks + 1, 'the comeback counts');
  assert.equal(after.clock - before.clock, 60, 'and the clock moves on a minute');
});

test('the stills: the work, the close-up of the sad face, and the payoff', () => {
  assert.deepEqual(stills.map(({ mood }) => mood), ['content', 'disappointed', 'happy']);
  assert.equal(cameraAt(stills[0].t), 0);
  assert.equal(cameraAt(stills[1].t), 1, 'the middle still is the camera’s close-up');
  assert.ok(stills[1].t >= sadFormed);
  assert.equal(cameraAt(stills[2].t), 0);
  assert.ok(stills[2].t >= PIECE_LANDS, 'the last still holds the landed piece');
});

test('time away reads naturally, and a blink away is no time at all', () => {
  assert.equal(awayFor(.4), null);
  assert.equal(awayFor(1), '1 second');
  assert.equal(awayFor(14.3), '14 seconds');
  assert.equal(awayFor(61), '1 minute');
  assert.equal(awayFor(25 * 60), '25 minutes');
  assert.equal(awayFor(72 * 60), 'a while', 'past an hour, it stops counting');
});

test('the welcome back takes the cheer’s place, with a word, and fits before the next clip', () => {
  const { welcome, cheer } = moku.moments;
  assert.equal(welcome.mood, cheer.mood);
  assert.equal(welcome.line, 'There you are!', 'a feeling, not the caption again');
  const at = cues.find(({ moment }) => moment === 'cheer').at;
  const next = cues.find((cue) => cue.at > at).at;
  assert.ok(at + manifest[welcome.clip].duration / 1000 + .04 < next);
});

test('the sped-up day stays true to the app’s drift ladder and daily house', () => {
  const drift = dayAt(LOOP).driftSeconds;
  // BehaviorLadder: sad after the one-second grace; cross only after a minute.
  assert.ok(drift < 60, `the drift lasts ${drift.toFixed(1)} simulated seconds, so Moku never turns cross`);
  const sadAt = cues.find(({ moment }) => moment === 'sad').at;
  assert.ok(dayAt(sadAt).driftSeconds >= 1, 'Moku waits out the grace second before looking sad');
  // Focus only counts while working, and one piece lands exactly at 2h 40m.
  assert.equal(dayAt(0).focusMinutes, 151);
  assert.equal(dayAt(DRIFT_STARTS).focusMinutes, dayAt(RETURN_CLICK).focusMinutes);
  assert.equal(dayAt(PIECE_LANDS - .01).house.built, 15);
  assert.equal(dayAt(PIECE_LANDS).house.built, 16);
  assert.equal(dayAt(PIECE_LANDS).focusMinutes, 160);
  assert.equal(beatAt(PIECE_LANDS).id, 'back');
  assert.equal(formatFocus(dayAt(END).focusMinutes), '2h 40m');
  assert.equal(dayAt(RETURN_CLICK).comebacks, 2);
  assert.equal(dayAt(END).comebacks, 3);
  assert.equal(formatClock(dayAt(0).clock), 'Tue 10:41');
  for (let t = 0; t < LOOP; t += .25) assert.ok(dayAt(t + .25).clock > dayAt(t).clock, 'the clock only moves forward');
});

test('the companion’s clips never overlap and its moods chain through the loop seam', () => {
  for (const loop of [0, 1]) {
    let mood = moku.restingMood;
    let free = -Infinity;
    for (const cue of cues.filter((item) => cueRuns(item, loop))) {
      const moment = moku.moments[cue.moment];
      assert.ok(cue.at >= free + .05, `${cue.moment} at ${cue.at}s starts after the previous clip ends (${free.toFixed(2)}s)`);
      if (moment.from) {
        assert.equal(moment.from, mood, `${cue.moment} begins in the mood the previous clip ended in`);
        mood = moment.to;
      } else assert.equal(moment.mood, mood, `${cue.moment} plays in its own mood`);
      free = cue.at + seconds(cue.moment) + .04;
    }
    assert.equal(mood, moku.restingMood, 'the loop ends in the mood it starts in');
    const firstNext = cues.find((cue) => cueRuns(cue, loop + 1)).at + LOOP;
    assert.ok(free < firstNext, 'the last clip ends before the next loop’s first');
  }
  const driftSeam = cues.find(({ at, moment }) => at > DRIFT_STARTS && at < RETURN_CLICK && moku.moments[moment].from);
  assert.equal(moku.moments[driftSeam.moment].to, 'disappointed', 'the drift turns the companion sad');
  assert.deepEqual(clipsFor(moku, cues).filter((name) => !manifest[name]), [], 'every clip exists in the manifest');
});

test('in every kind of work, the drift brings a browser forward and the comeback brings the work back', () => {
  for (const scene of Object.values(scenes)) {
    assert.equal(sceneAt(scene, 0).values.front, scene.work, scene.id);
    for (let t = DRIFT_STARTS; t < RETURN_CLICK; t += .1) assert.equal(sceneAt(scene, t).values.front, 'browser', `${scene.id} at ${t}`);
    assert.equal(sceneAt(scene, WORK_FRONT).values.front, scene.work, scene.id);
    assert.ok(new Set(Object.values(scene.apps)).size >= 2, `${scene.id}: the work is in more than one real app`);
    assert.ok(scene.apps[scene.work] && scene.apps.browser);
    for (let t = 0; t < LOOP; t += .05) {
      const state = sceneAt(scene, t);
      assert.ok(Object.values(state.values).every((value) => value !== undefined), `${scene.id}: defined at ${t}`);
      assert.ok(state.app, `${scene.id}: names the front app at ${t}`);
    }
  }
});

test('a visit plays one kind of work, drawn from the four', () => {
  assert.deepEqual([0, 1, 2, 3, 4].map(workForVisit), [...sceneOrder, sceneOrder[0]]);
  assert.equal(workForVisit(Number.NaN), 'writing', 'without a count, writing');
  assert.deepEqual(Object.keys(scenes).sort(), [...sceneOrder].sort());
});

// Every element a scene's tracks and pointer name is in its markup (index.html).
test('each scene’s markup has what its timeline drives', () => {
  const html = readFileSync(new URL('../index.html', import.meta.url), 'utf8');
  for (const scene of Object.values(scenes)) {
    const start = html.indexOf(`data-scene="${scene.id}"`);
    assert.ok(start > 0, `${scene.id} is on the page`);
    const end = html.indexOf('data-scene="', start + 12);
    const markup = html.slice(start, end > 0 ? end : html.indexOf('class="house-chip"'));
    const targets = [scene.cursor.rest, ...scene.cursor.moves.map(({ target }) => target)];
    for (const target of new Set(targets)) assert.ok(markup.includes(`data-at="${target}"`), `${scene.id}: the pointer's ${target}`);
    for (const name of Object.keys(scene.tracks)) {
      const [kind, id] = name.split(':');
      const attribute = { type: 'data-type', text: 'data-text', scroll: 'data-scroll' }[kind];
      if (attribute) assert.ok(markup.includes(`${attribute}="${id}"`), `${scene.id}: ${name}`);
    }
    for (const win of new Set(Object.keys(scene.apps))) assert.ok(markup.includes(`data-win="${win}"`), `${scene.id}: the ${win} window`);
  }
});

test('windows change only when the pointer clicks them', () => {
  for (const scene of Object.values(scenes)) windowsChangeOnClicks(scene);
});

function windowsChangeOnClicks(scene) {
  const { tracks, cursor } = scene;
  const clicks = cursor.moves.filter((move) => move.click).map((move) => move.to);
  for (const [time] of tracks.front.keys.slice(1)) {
    assert.ok(clicks.some((click) => time - click >= 0 && time - click <= .2), `the change at ${time}s follows a click`);
  }
  for (const [name, track] of Object.entries(tracks)) {
    const times = track.kind === 'step' ? track.keys.map(([time]) => time) : track.segments.flatMap(([from, to]) => [from, to]);
    assert.deepEqual(times, [...times].sort((a, b) => a - b), `${name} is in order`);
    assert.ok(times.every((time) => time >= 0 && time <= LOOP), `${name} stays inside the loop`);
  }
  const moves = cursor.moves.flatMap(({ from, to }) => [from, to]);
  assert.deepEqual(moves, [...moves].sort((a, b) => a - b), `${scene.id}: the pointer finishes each move before the next`);
}

test('the loop seam: whatever differs between the end and the start fades through it', () => {
  for (const scene of Object.values(scenes)) {
    for (const [name, track] of Object.entries(scene.tracks)) {
      const same = JSON.stringify(trackValue(track, 0)) === JSON.stringify(trackValue(track, END));
      assert.ok(same || scene.seam.includes(name), `${scene.id}: ${name} changes at the seam, so it must fade`);
    }
    const start = cursorAt(scene.cursor, 0), end = cursorAt(scene.cursor, END);
    assert.equal(end.to, start.to, `${scene.id}: the pointer ends where it starts`);
    assert.equal(end.progress, 1);
    assert.equal(end.visible, start.visible, scene.id);
  }
  assert.equal(seamOpacity(0, true), 1, 'the first start never fades in');
  assert.equal(seamOpacity(0), 0);
  assert.equal(seamOpacity(.35), 1);
  assert.ok(seamOpacity(END) < .001);
  assert.equal(seamOpacity(LOOP - .5), 1);
});

const moments = moku.moments;
const play = (elapsed, position, mood = 'content') => nextCue({ elapsed, position, mood, moments });

test('the companion greets once, then glances in later loops', () => {
  const first = play(.6, { loop: 0, index: 0 });
  assert.equal(first.action, 'play');
  assert.equal(first.cue.moment, 'hello');
  const second = play(LOOP + 1.5, { loop: 1, index: 0 });
  assert.equal(second.cue.moment, 'glance');
  assert.equal(play(1.5, first.position).action, 'wait', 'no glance in the first loop');
});

test('a companion picked mid-loop greets you in the next loop, then drifts', () => {
  const helloLoop = 4;
  const pick = (elapsed, position) => nextCue({ elapsed, position, mood: 'content', moments, helloLoop });
  const hello = pick(helloLoop * LOOP + .6, { loop: helloLoop, index: 0 });
  assert.equal(hello.cue.moment, 'hello');
  assert.ok(PICKED_AT < hello.cue.at, 'the loop picks up before the hello');
  assert.equal(pick(helloLoop * LOOP + 1.5, hello.position).action, 'wait', 'no glance over the hello');
  assert.equal(pick((helloLoop + 1) * LOOP + 1.5, { loop: helloLoop + 1, index: 0 }).cue.moment, 'glance');
  assert.equal(pick(1.5, { loop: 0, index: 0 }).cue.moment, 'glance', 'the first loop glances when it isn’t the hello’s');
  assert.ok(cueRuns(cues[0], helloLoop, helloLoop) && !cueRuns(cues[0], 0, helloLoop));
});

test('a late gesture is skipped; a late mood change still plays', () => {
  const late = play(cue('slowBlink').at + LATE + .05, { loop: 0, index: 2 });
  assert.notEqual(late.cue?.moment, 'slowBlink');
  const sad = play(cue('sad').at + 1.5, { loop: 0, index: 4 });
  assert.equal(sad.action, 'play');
  assert.equal(sad.cue.moment, 'sad');
  const wrongMood = play(cue('perk').at + .7, { loop: 0, index: 5 }, 'content');
  assert.notEqual(wrongMood.cue?.moment, 'perk', 'a seam from another mood would snap, so it waits for the next loop');
});

// Plays three loops at 60 fps, with each clip busy for its native duration, and
// checks where the companion's mood is at the moments that matter.
test('three loops: the companion is sad in the drift, happy on the comeback, content at each seam', () => {
  let position = { loop: 0, index: 0 }, mood = 'content', busyUntil = -1, pending = null;
  const moodAt = new Map(), started = [];
  for (let frame = 0; frame <= LOOP * 3 * 60; frame++) {
    const elapsed = frame / 60;
    if (pending && elapsed >= busyUntil) { mood = pending; pending = null; }
    if (elapsed >= busyUntil) {
      const plan = play(elapsed, position, mood);
      position = plan.position;
      if (plan.action === 'play') {
        started.push({ moment: plan.cue.moment, late: elapsed - plan.at });
        busyUntil = elapsed + seconds(plan.cue.moment) + .04;
        if (plan.moment.to) pending = plan.moment.to;
      }
    }
    moodAt.set(Math.round(elapsed * 100) / 100, mood);
  }
  for (let loop = 0; loop < 3; loop++) {
    const base = loop * LOOP;
    assert.equal(moodAt.get(Math.round((base + 15.5) * 100) / 100), 'disappointed', `loop ${loop}: sad before the comeback`);
    assert.equal(moodAt.get(Math.round((base + PIECE_LANDS) * 100) / 100), 'happy', `loop ${loop}: happy after it`);
    assert.equal(moodAt.get(Math.round((base + LOOP - .1) * 100) / 100), 'content', `loop ${loop}: content at the seam`);
  }
  assert.ok(started.every(({ late }) => late < 1 / 60 + 1e-9), 'every clip starts on its frame');
  assert.equal(started.filter(({ moment }) => moment === 'hello').length, 1);
});
