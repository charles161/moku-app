import house from './house-data.json' with { type: 'json' };

// Your day, as the app shows it (app/MokuVisual/Sources/MokuVisual/Today.swift, by task
// with the workflow: docs/specs/your-day-by-goal.md): an example day for each kind of
// work in the hero. Each task has its hours, a line about it, the workflow (the apps in
// the order the work reached them, with their minutes, and the detours where they
// happened), the steps in plain words, the longest stretch and how you came back. The
// apps and sites are the hero's generic ones; nothing here is a real brand. The steps
// use the app's words (workflow.go): "edited" an editor's files, "ran" a terminal's
// command, "read" a document, else "<title> on <site>", or Moku's own words for the work.
//
// The numbers add up as the app's do: the tasks and the small ones make the focused
// time, a task's apps make its minutes, and the house has a piece per 10 focused minutes.

const app = (name, minutes) => ({ kind: 'app', name, minutes });
const detour = (place, minutes) => ({ kind: 'detour', place, minutes });

export const days = {
  writing: {
    id: 'writing',
    date: 'Tuesday, October 6',
    focused: 192, returns: 5,
    note: (piece) => `A long stretch on the essay, and you came back every time. I put up ${piece}.`,
    // The day, from 9:00 AM: work and drift, in minutes after nine.
    ribbon: [[5, 50, 'work'], [50, 56, 'drift'], [56, 168, 'work'], [175, 186, 'drift'], [310, 340, 'work'], [340, 344, 'drift'], [344, 365, 'work'], [400, 409, 'drift'], [420, 435, 'work']],
    tasks: [
      {
        title: 'writing the slow-mornings essay', minutes: 136, hours: '9:05–11:48 AM',
        summary: 'The part about tea going cold, then a third draft of the ending',
        workflow: [app('Writer', 104), detour('feed.example', 6), app('Reader', 21), app('dictionary.example', 11)],
        steps: ['edited The case for slow mornings', 'read morning-light.pdf', '“liminal” on dictionary.example'],
        longest: 52, detours: 1, detourMinutes: 6,
      },
      {
        title: 'planning the October newsletter', minutes: 41, hours: '2:10–3:05 PM',
        summary: 'Three topics for the month, and a first subject line',
        workflow: [app('Writer', 26), detour('video.example', 4), app('Mail', 15)],
        steps: ['edited October newsletter', 'wrote to the editor'],
        longest: 25, detours: 1, detourMinutes: 4,
      },
    ],
    also: [['answering email', 9], ['reading about morning routines', 6]],
    best: { at: '9:56 AM', from: 'feed.example', away: 6, task: 'the slow-mornings essay', stayed: 52 },
  },

  design: {
    id: 'design',
    date: 'Wednesday, October 7',
    focused: 214, returns: 4,
    note: (piece) => `The welcome screen came together, and a long video didn’t keep you. I put up ${piece}.`,
    ribbon: [[40, 88, 'work'], [88, 97, 'drift'], [97, 235, 'work'], [270, 300, 'work'], [300, 305, 'drift'], [305, 320, 'work'], [335, 341, 'drift'], [350, 384, 'work']],
    tasks: [
      {
        title: 'designing the onboarding screens', minutes: 142, hours: '9:40 AM–12:55 PM',
        summary: 'The welcome screen’s button and title, then the second screen’s layout',
        workflow: [app('Canvas', 104), detour('video.example', 9), app('icons.example', 14), app('Writer', 24)],
        steps: ['edited Onboarding — Welcome', 'Line icons on icons.example', 'edited Onboarding copy'],
        longest: 47, detours: 1, detourMinutes: 9,
      },
      {
        title: 'reworking the app icon', minutes: 38, hours: '2:30–3:20 PM',
        summary: 'Six comments from the team, and two new versions of the house',
        workflow: [app('Mail', 12), app('Canvas', 26), detour('shop.example', 5)],
        steps: ['went through Icon feedback, round 2', 'edited App icon'],
        longest: 21, detours: 1, detourMinutes: 5,
      },
    ],
    also: [['exporting assets', 22], ['notes for the stand-up', 12]],
    best: { at: '10:37 AM', from: 'video.example', away: 9, task: 'the onboarding screens', stayed: 47 },
  },

  code: {
    id: 'code',
    date: 'Thursday, October 8',
    focused: 226, returns: 6,
    note: (piece) => `The tests pass again, and you came back from the keyboards. I put up ${piece}.`,
    ribbon: [[20, 78, 'work'], [78, 86, 'drift'], [86, 155, 'work'], [175, 182, 'drift'], [280, 345, 'work'], [365, 369, 'drift'], [425, 470, 'work'], [470, 473, 'drift'], [473, 490, 'work']],
    tasks: [
      {
        title: 'fixing the streak bug', minutes: 114, hours: '9:20–11:35 AM',
        summary: 'A day without focus wasn’t breaking the run; now it does, and the tests pass',
        workflow: [app('Editor', 76), app('Terminal', 22), detour('shop.example', 8), app('docs.example', 16)],
        steps: ['edited streak.ts and day.ts', 'ran npm test', 'read Dates and time zones on docs.example'],
        longest: 58, detours: 1, detourMinutes: 8,
      },
      {
        title: 'reviewing the settings pull request', minutes: 52, hours: '1:40–2:45 PM',
        summary: 'One store for every pane: three comments, then an approval',
        workflow: [app('code.example', 31), app('Editor', 14), app('Terminal', 7)],
        steps: ['read Settings: one store for every pane on code.example', 'ran npm run build'],
        longest: 34, detours: 0, detourMinutes: 0,
      },
      {
        title: 'writing the release notes', minutes: 34, hours: '4:05–4:50 PM',
        summary: 'What changed in 2.4, in words a person would use',
        workflow: [app('Writer', 26), detour('news.example', 3), app('Editor', 8)],
        steps: ['edited Release notes 2.4', 'edited CHANGELOG.md'],
        longest: 22, detours: 1, detourMinutes: 3,
      },
    ],
    also: [['answering email', 14], ['the stand-up', 12]],
    best: { at: '10:26 AM', from: 'shop.example', away: 8, task: 'the streak bug', stayed: 58 },
  },

  study: {
    id: 'study',
    date: 'Friday, October 9',
    focused: 178, returns: 7,
    note: (piece) => `Chapter 6 is done, on an on-and-off day. You kept coming back. I put up ${piece}.`,
    ribbon: [[10, 51, 'work'], [51, 58, 'drift'], [58, 95, 'work'], [120, 125, 'drift'], [130, 175, 'work'], [175, 180, 'drift'], [180, 205, 'work'], [300, 329, 'work'], [329, 334, 'drift'], [334, 352, 'work'], [380, 403, 'work']],
    tasks: [
      {
        title: 'studying for the statistics exam', minutes: 108, hours: '9:10 AM–12:25 PM, on and off',
        summary: 'Chapter 6 on confidence intervals, then two practice sets',
        workflow: [app('Reader', 52), detour('news.example', 7), app('Writer', 31), detour('video.example', 5), app('practice.example', 25)],
        steps: ['read chapter-6.pdf', 'edited Stats notes', 'Practice set 6B on practice.example'],
        longest: 41, detours: 2, detourMinutes: 12,
      },
      {
        title: 'reading for the seminar', minutes: 47, hours: '2:00–3:05 PM',
        summary: 'Two papers on attention and short breaks, with notes',
        workflow: [app('Reader', 33), detour('video.example', 5), app('Writer', 14)],
        steps: ['read short-breaks.pdf and attention-review.pdf', 'edited Seminar notes'],
        longest: 29, detours: 1, detourMinutes: 5,
      },
    ],
    also: [['flashcards', 15], ['emailing the study group', 8]],
    best: { at: '9:58 AM', from: 'news.example', away: 7, task: 'the statistics exam', stayed: 41 },
  },
};

// "3h 12m", "52m", as the app writes minutes.
export const minutesText = (minutes) => {
  const hours = Math.floor(minutes / 60), rest = minutes % 60;
  return hours ? `${hours}h${rest ? ` ${rest}m` : ''}` : `${rest}m`;
};

// The steps as one line, the first word capitalized (Today.swift's stepsLine).
export const stepsLine = (steps) => steps.length ? [steps[0][0].toUpperCase() + steps[0].slice(1), ...steps.slice(1)].join(' · ') : null;

// How you came back to a task (Today.swift's cameBack).
export const cameBack = ({ detours, detourMinutes }) => detours === 0 ? null
  : detours === 1 ? `Came back once, ${minutesText(detourMinutes)} away` : `Came back ${detours} times, ${minutesText(detourMinutes)} away`;

// A day's numbers, and its house as it stands in a companion's home.
export function dayFacts(day, home) {
  const tasks = day.tasks.reduce((sum, task) => sum + task.minutes, 0);
  const small = day.also.reduce((sum, [, minutes]) => sum + minutes, 0);
  const built = Math.min(house.pieces, Math.floor(day.focused / house.minutesPerPiece));
  const stage = home.stages.filter(({ first }) => built >= first).length - 1;  // stages ascend (no findLastIndex: Chrome < 97)
  return {
    tasks, small, built, stage,
    longest: Math.max(...day.tasks.map((task) => task.longest)),
    taskCount: day.tasks.length + day.also.length,
    percent: Math.floor(Math.min(1, day.focused / house.goalMinutes) * 100),
    piece: home.pieceNames[built - 1],
    next: built < house.pieces ? { name: home.pieceNames[built], minutes: (built + 1) * house.minutesPerPiece - day.focused } : null,
    image: home.image(built * house.minutesPerPiece),
  };
}
