import { loadNear } from './near-images.js';
import { days, dayFacts, minutesText, stepsLine, cameBack } from './your-day-data.js';

// Your day (index.html, 04): the app's window, drawn from an example day for the kind
// of work on show in the hero, written by the companion that's picked: the day and its
// note, today's house as it stands, the day's numbers and ribbon, then what you worked
// on, task by task, with the workflow, the steps and how you came back.

const RIBBON_MINUTES = 9 * 60;  // 9:00 AM to 6:00 PM

const escape = (text) => String(text).replace(/[&<>"]/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[char]);

// The generic apps' icons, as small tiles; a site gets a letter tile, as in the app.
const icons = {
  Writer: ['W', 'yd-icon-writer'], Canvas: ['◇', 'yd-icon-canvas'], Editor: ['‹›', 'yd-icon-editor'],
  Terminal: ['›_', 'yd-icon-terminal'], Reader: ['▤', 'yd-icon-reader'], Mail: ['✉', 'yd-icon-mail'],
};
function icon(name) {
  const [glyph, className] = icons[name] ?? [name[0].toUpperCase(), 'yd-icon-site'];
  return `<i class="yd-icon ${className}" aria-hidden="true">${escape(glyph)}</i>`;
}

// Each link carries its arrow, so a row that wraps never ends on one.
function workflow(task) {
  return task.workflow.map((step, i) => {
    const arrow = i ? '<span class="yd-arrow" aria-hidden="true">→</span>' : '';
    return step.kind === 'app'
      ? `<span class="yd-link">${arrow}<span class="yd-app">${icon(step.name)}<b>${escape(step.name)}</b> ${minutesText(step.minutes)}</span></span>`
      : `<span class="yd-link">${arrow}<span class="yd-detour" title="A detour to ${escape(step.place)}, then back"><span aria-hidden="true">↩</span> ${escape(step.place)} ${minutesText(step.minutes)}</span></span>`;
  }).join('');
}

function taskCard(task) {
  const back = cameBack(task);
  return `<li class="yd-task">
    <div class="yd-task-top"><h4>${escape(task.title)}</h4><span class="yd-hours">${escape(task.hours)}</span><b>${minutesText(task.minutes)}</b></div>
    <p class="yd-summary">${escape(task.summary)}</p>
    <p class="yd-flow">${workflow(task)}</p>
    <p class="yd-steps">${escape(stepsLine(task.steps))}</p>
    <p class="yd-how"><span><i aria-hidden="true">◷</i>Longest stretch ${minutesText(task.longest)}</span>${back ? `<span><i aria-hidden="true">↩</i>${back}</span>` : ''}</p>
  </li>`;
}

function ribbon(day) {
  return day.ribbon.map(([from, to, kind]) => `<i class="yd-r-${kind}" style="left: ${(from / RIBBON_MINUTES * 100).toFixed(2)}%; width: ${((to - from) / RIBBON_MINUTES * 100).toFixed(2)}%"></i>`).join('');
}

export function render(day, companion) {
  const facts = dayFacts(day, companion.home);
  const { stages } = companion.home;
  const pieces = 24;
  const stageMarks = stages.slice(1).map(({ first }) => `<i style="left: ${(first / pieces * 100).toFixed(2)}%"></i>`).join('');
  const stageNames = stages.map(({ name, first }, i) => {
    const end = stages[i + 1]?.first ?? pieces;
    return `<span class="${i === facts.stage ? 'is-current' : i < facts.stage ? 'is-done' : ''}" style="flex: ${end - first}">${escape(name.replace(/^The /, '').replace(/(^|\s)\p{Ll}/gu, (letter) => letter.toUpperCase()))}</span>`;
  }).join('');
  return `
    <header class="yd-head">
      <h3 id="day-card-date">${escape(day.date)}</h3>
      <span class="yd-with">YOUR DAY WITH ${escape(companion.name.toUpperCase())}</span>
      <p class="yd-note">${escape(day.note(facts.piece))}</p>
    </header>
    <div class="yd-body">
      <div class="yd-home">
        <img class="yd-house" data-near-src="${facts.image}" alt="${escape(`${companion.home.name} after ${minutesText(day.focused)} of focus: ${facts.built} of 24 pieces built`)}" width="800" height="760" />
        <div class="yd-progress">
          <p><strong>${facts.percent}%</strong> built <span>${minutesText(day.focused)} of 4h</span></p>
          <span class="yd-meter" style="--built: ${(facts.built / pieces).toFixed(4)}"><i class="yd-fill"></i>${stageMarks}</span>
          <span class="yd-stages">${stageNames}</span>
          <p class="yd-next">${facts.next ? `Next: ${escape(facts.next.name)}, in ${facts.next.minutes} focused min` : escape(companion.home.finished)}</p>
        </div>
      </div>
      <div class="yd-work">
        <dl class="yd-metrics">
          <div><dt>focused</dt><dd>${minutesText(day.focused)}</dd></div>
          <div><dt>returns</dt><dd>${day.returns}</dd></div>
          <div><dt>longest</dt><dd>${minutesText(facts.longest)}</dd></div>
        </dl>
        <div class="yd-ribbon" aria-hidden="true"><span>${ribbon(day)}</span><p><span>9:00 AM</span><span>6:00 PM</span></p></div>
        <p class="yd-label">WHAT YOU WORKED ON · ${facts.taskCount} tasks, ${minutesText(day.focused)}</p>
        <ul class="yd-tasks">${day.tasks.map(taskCard).join('')}</ul>
        <p class="yd-also"><b>Also</b> ${day.also.map(([title, minutes]) => `${escape(title)} ${minutesText(minutes)}`).join(' · ')}</p>
        <div class="yd-best"><p class="yd-label">BEST COMEBACK</p><p>At ${escape(day.best.at)}, you came back from ${escape(day.best.from)} after ${day.best.away} min, then stayed with ${escape(day.best.task)} for ${day.best.stayed} min.</p></div>
      </div>
    </div>
    <footer class="yd-foot"><span>Every 10 focused minutes adds a piece to the day’s house; four hours builds all of it.</span><span>Only you see this. An example day.</span></footer>`;
}

// The card follows the hero: its companion and its kind of work. The day's own tabs pick
// the work in the hero too (`pickWork`), so there's one choice for the page.
export function initYourDay(section, { companion, work = 'writing', pickWork = () => {} }) {
  const card = section?.querySelector('[data-your-day]');
  if (!card) return null;
  const tabs = [...section.querySelectorAll('[data-day-work]')];
  let current = { companion, work: days[work] ? work : 'writing' };
  const draw = () => {
    card.innerHTML = render(days[current.work], current.companion);
    loadNear(card);
    card.dataset.work = current.work;
    tabs.forEach((tab) => tab.setAttribute('aria-pressed', String(tab.dataset.dayWork === current.work)));
  };
  tabs.forEach((tab) => tab.addEventListener('click', () => {
    if (tab.dataset.dayWork === current.work) return;
    current = { ...current, work: tab.dataset.dayWork };
    draw();
    pickWork(current.work);
  }));
  draw();
  return {
    setCompanion(next) { if (next !== current.companion) { current = { ...current, companion: next }; draw(); } },
    setWork(id) { if (days[id] && id !== current.work) { current = { ...current, work: id }; draw(); } },
  };
}
