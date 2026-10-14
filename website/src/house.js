import house from './house-data.json' with { type: 'json' };
import { plan } from './loading-plan.js';

// The cottage's names and renders, as the app's DayHouse has them. Every companion's
// home has the same 24 pieces in the same five stages, with its own names and renders
// (companions.js).
const cottage = {
  stages: house.stages, pieceNames: house.pieceNames,
  image: (minutes) => `/images/house/${String(minutes).padStart(3, '0')}.webp`,
  thumb: (minutes) => `/images/house/thumb/${String(minutes).padStart(3, '0')}.webp`,
};
// On a slow connection, a house's full render loads once the house has stopped changing for this long.
const SETTLE_MS = 300;

// These constants are exported from the app's DayHouse, alongside its native renders.
export function houseProgress(minutes, home = cottage) {
  const focused = Math.max(0, Math.min(house.goalMinutes, Number.isFinite(minutes) ? minutes : 0));
  const built = Math.min(house.pieces, Math.floor(focused / house.minutesPerPiece));
  const complete = built === house.pieces;
  const stage = home.stages.filter(({ first }) => built >= first).length - 1;  // stages ascend (no findLastIndex: Chrome < 97)
  return {
    built, complete, stage,
    percent: Math.floor(focused / house.goalMinutes * 100),
    title: complete ? 'Home, sweet home.' : home.stages[stage].name,
    image: home.image(built * house.minutesPerPiece),
    next: complete ? null : { name: home.pieceNames[built], minutes: Math.ceil((built + 1) * house.minutesPerPiece - focused) },
  };
}

// Scroll first builds the native 24-piece house, then lets the evening arrive.
export function houseStoryProgress(value) {
  const progress = Math.max(0, Math.min(1, Number.isFinite(value) ? value : 0));
  const buildProgress = Math.max(0, Math.min(1, (progress - .06) / .76));
  const smooth = (n) => n * n * (3 - 2 * n);
  return {
    progress,
    buildProgress,
    minutes: Math.min(house.goalMinutes, Math.floor((buildProgress * house.pieces + 1e-8)) * house.minutesPerPiece),
    cameraProgress: smooth(Math.min(1, progress / .82)),
    evening: smooth(Math.max(0, Math.min(1, (progress - .82) / .18))),
  };
}

export function initHouse(companion) {
  const $ = (selector) => document.querySelector(selector);
  const slider = $('#world-progress');
  const stageList = $('#house-stages');
  const image = $('#world-image');
  let frameRequest = 0;
  let scene;
  let storyProgress;
  let storyActive = false;
  // The cottage, until a companion with its own home is chosen.
  let home = companion?.home ?? { ...cottage, model: true, finished: 'The lights are on. Moku’s home is finished for today.', finishedAlt: image.alt };
  let preloaded = false;
  // The section's renders load once it's near (400 px), not with the page.
  let near = false, thumbsNear = false;
  // Renders and thumbnails decoded, so they show at once; and the full render on its way (one at a time on a slow
  // connection, so the house you stop on never waits behind every step you passed on the way).
  const ready = new Set();
  let coming = null;
  function load(src, priority = 'auto') {
    const frame = new Image();
    frame.fetchPriority = priority;
    frame.src = src;
    return { frame, done: frame.decode().then(() => { ready.add(src); }) };
  }
  function loadRender(src) {
    if (coming?.src === src) return coming.done;
    if (coming && plan.light) coming.frame.removeAttribute('src');
    const { frame, done } = load(src, 'high');
    const next = { src, frame, done: done.finally(() => { if (coming === next) coming = null; }) };
    coming = next;
    return next.done;
  }
  // Every thumbnail (3 KB each), nearest the slider's place first: whatever step you stop on shows at once.
  function preloadThumbs() {
    if (!home.thumb) return;
    const here = Number(slider.value);
    const steps = Array.from({ length: house.pieces + 1 }, (_, i) => i * house.minutesPerPiece);
    for (const minutes of steps.sort((a, b) => Math.abs(a - here) - Math.abs(b - here))) load(home.thumb(minutes)).done.catch(() => {});
  }
  function labelStages() {
    stageList.innerHTML = home.stages.map(({ name, first }, i) => {
      const end = home.stages[i + 1]?.first ?? house.pieces;
      return `<span style="flex:${end - first}">${name.replace('The ', '')}</span>`;
    }).join('');
  }
  labelStages();
  function preload() {
    for (let minutes = 0; minutes <= house.goalMinutes; minutes += house.minutesPerPiece) {
      load(houseProgress(minutes, home).image).done.catch(() => {});
    }
  }

  async function showHouse(minutes, immediate = false) {
    const progress = houseProgress(minutes, home);
    if (home.model) scene?.setMinutes(minutes, immediate);
    const request = ++frameRequest;
    const hours = Math.floor(minutes / 60);
    const remainder = minutes % 60;
    const time = hours ? `${hours}h${remainder ? ` ${remainder}m` : ''}` : `${remainder}m`;
    // Each element on its own: a page changed on the visitor's side (an extension, a translator) once lost #house-stage,
    // and the rejection skipped the rest (2026-10-07, Chrome on Windows).
    const write = (selector, text) => { const element = $(selector); if (element) element.textContent = text; };
    write('#house-stage', progress.title);
    write('#house-percent', `${progress.percent}%`);
    write('#house-time', `${time} of 4h`);
    write('#house-pieces', `${progress.built} / ${house.pieces} pieces`);
    write('#house-next', progress.next ? `Next: ${progress.next.name}, in ${progress.next.minutes} focused min.` : home.finished);
    $('#house-meter')?.style.setProperty('--house-progress', `${progress.percent}%`);
    [...stageList.children].forEach((label, i) => label.classList.toggle('is-current', !progress.complete && i === progress.stage));
    slider.setAttribute('aria-valuetext', `${time} focused. ${progress.percent}% built. ${progress.title}`);
    slider.style.setProperty('--range-progress', `${progress.percent}%`);
    const alt = progress.complete
      ? home.finishedAlt
      : `${home.name ?? 'Today’s house'} after ${time} of focus: ${progress.built} of ${house.pieces} pieces built. ${progress.title}.`;
    if (image.getAttribute('src') === progress.image || !near) { image.alt = alt; return; }
    const stand = home.thumb?.(progress.built * house.minutesPerPiece);
    const show = (src) => {
      if (image.getAttribute('src') !== src) image.src = src;
      image.alt = alt;
      image.classList.toggle('is-preview', src === stand);
    };
    if (ready.has(progress.image)) return show(progress.image);
    // This house at once from its thumbnail, softened, until its own render is in.
    if (ready.has(stand)) show(stand);
    else if (stand) load(stand, 'high').done.then(() => { if (request === frameRequest && !ready.has(progress.image)) show(stand); }, () => {});
    if (plan.light) {
      await new Promise((resolve) => setTimeout(resolve, SETTLE_MS));
      if (request !== frameRequest) return;
    }
    for (let attempt = 0; attempt < 2; attempt++) {
      try {
        await loadRender(progress.image);
        if (request === frameRequest) show(progress.image);
        return;
      } catch {
        // Passed by, or the network dropped it: a house still wanted gets one more try.
        if (request !== frameRequest) return;
        await new Promise((resolve) => setTimeout(resolve, 800));
        if (request !== frameRequest) return;
      }
    }
  }

  slider.addEventListener('input', () => {
    storyActive = false;
    showHouse(Number(slider.value), true);
  });
  showHouse(Number(slider.value));
  // Near the section, its render for the slider's place, then (on a good connection)
  // every other render, so scrubbing never waits. On a slow one each loads as it's shown.
  // The thumbnails (81 KB in all) a screen and a half ahead, so even a slow connection has them by the time you build.
  const thumbsObserver = new IntersectionObserver((entries) => {
    if (!entries.some(({ isIntersecting }) => isIntersecting)) return;
    thumbsObserver.disconnect();
    thumbsNear = true;
    preloadThumbs();
  }, { rootMargin: '150% 0px' });
  thumbsObserver.observe($('#world'));
  const observer = new IntersectionObserver((entries) => {
    if (!entries.some(({ isIntersecting }) => isIntersecting)) return;
    near = true;
    if (!thumbsNear) { thumbsNear = true; preloadThumbs(); }
    showHouse(Number(slider.value), true);
    preloaded = !plan.light;
    if (preloaded) preload();
    observer.disconnect();
  }, { rootMargin: '400px' });
  observer.observe($('#world'));
  function setMinutes(minutes, immediate = false) {
    const step = Math.max(0, Math.min(house.goalMinutes, Math.round(minutes / house.minutesPerPiece) * house.minutesPerPiece));
    if (immediate) scene?.setMinutes(step, true);
    if (Number(slider.value) === step) return;
    slider.value = step;
    showHouse(step, immediate);
  }
  // A companion's home: its names, its words and its native renders. The cottage's
  // 3D diorama shows only for the cottage.
  function setHome(next) {
    if (!next || next === home) return;
    home = next;
    $('.house-scene').dataset.home = home.model ? '' : 'stills';
    $('#house-name').textContent = (home.name ?? 'Today’s house').toUpperCase();
    if (home.pitch) $('#house-pitch').textContent = home.pitch;
    labelStages();
    if (thumbsNear) preloadThumbs();
    if (preloaded) preload();
    showHouse(Number(slider.value), true);
    if (home.model && scene) scene.setMinutes(Number(slider.value), true);
  }
  if (companion) setHome({ ...companion.home });
  return {
    setHome,
    connectScene(value) {
      scene = value;
      if (!home.model) return;
      scene.setMinutes(Number(slider.value), true);
      if (storyActive) scene.setStoryProgress(storyProgress, true);
    },
    setMinutes(minutes, immediate = false) {
      storyActive = false;
      setMinutes(minutes, immediate);
    },
    setStoryProgress(value) {
      const next = houseStoryProgress(value);
      if (next.progress === storyProgress) return;
      storyProgress = next.progress;
      storyActive = true;
      setMinutes(next.minutes);
      if (home.model) scene?.setStoryProgress(storyProgress);
      // This remains inspectable even while the 3D module is loading.
      $('.house-canvas').dataset.storyProgress = next.progress.toFixed(4);
    },
  };
}
