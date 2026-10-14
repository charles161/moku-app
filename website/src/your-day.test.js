import test from 'node:test';
import assert from 'node:assert/strict';
import { days, dayFacts, minutesText, stepsLine, cameBack } from './your-day-data.js';
import { scenes, sceneOrder } from './demo-timeline.js';
import { companions } from './companions.js';

const appNames = new Set(['Writer', 'Canvas', 'Editor', 'Terminal', 'Reader', 'Mail']);

test('a day for every kind of work in the hero', () => {
  assert.deepEqual(Object.keys(days).sort(), [...sceneOrder].sort());
  assert.deepEqual(Object.keys(days).sort(), Object.keys(scenes).sort());
});

test('each day adds up as the app’s do', () => {
  for (const day of Object.values(days)) {
    const facts = dayFacts(day, companions.moku.home);
    assert.equal(facts.tasks + facts.small, day.focused, `${day.id}: the tasks make the focused time`);
    for (const task of day.tasks) {
      const apps = task.workflow.filter((step) => step.kind === 'app');
      const detours = task.workflow.filter((step) => step.kind === 'detour');
      assert.equal(apps.reduce((sum, step) => sum + step.minutes, 0), task.minutes, `${day.id}: ${task.title}'s apps make its minutes`);
      assert.equal(detours.reduce((sum, step) => sum + step.minutes, 0), task.detourMinutes, `${day.id}: ${task.title}'s detours`);
      assert.ok(detours.length <= task.detours && (task.detours === 0) === (detours.length === 0));
      assert.ok(task.longest <= task.minutes);
      assert.equal(task.workflow[0].kind, 'app', 'a workflow starts with an app');
      assert.ok(apps.length <= 4, 'at most four apps in a row');
      assert.equal(new Set(apps.map(({ name }) => name)).size, apps.length, 'each app once, where the work first reached it');
      for (const { name } of apps) assert.ok(appNames.has(name) || name.endsWith('.example'), `${name}: the hero's generic apps and sites only`);
      for (const { place } of detours) assert.match(place, /\.example$/);
      assert.ok(task.steps.length >= 2);
    }
    assert.ok(day.returns >= day.tasks.reduce((sum, task) => sum + task.detours, 0), `${day.id}: every detour came back`);
    assert.equal(facts.built, Math.floor(day.focused / 10));
    assert.ok(day.tasks.length >= 2 && day.tasks.length <= 3);
  }
});

test('the note names the piece the day ended on, in the companion’s home', () => {
  const writing = days.writing;
  assert.match(writing.note(dayFacts(writing, companions.moku.home).piece), /I put up the porch\.$/);
  assert.match(writing.note(dayFacts(writing, companions.tetsu.home).piece), /I put up the beacon\.$/);
  assert.equal(dayFacts(writing, companions.tetsu.home).image, '/images/house/tetsu/190.webp');
});

test('the words are the app’s', () => {
  assert.equal(minutesText(192), '3h 12m');
  assert.equal(minutesText(120), '2h');
  assert.equal(minutesText(52), '52m');
  assert.equal(stepsLine(['edited streak.ts', 'ran npm test']), 'Edited streak.ts · ran npm test');
  assert.equal(cameBack({ detours: 0, detourMinutes: 0 }), null);
  assert.equal(cameBack({ detours: 1, detourMinutes: 6 }), 'Came back once, 6m away');
  assert.equal(cameBack({ detours: 2, detourMinutes: 12 }), 'Came back 2 times, 12m away');
});
