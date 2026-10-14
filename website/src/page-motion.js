import { animate, inView, scroll, stagger } from 'motion';
import { storyProgress } from './scroll-story.js';
import { plan } from './loading-plan.js';

const ease = [.22, 1, .36, 1];

// Scroll choreography below the hero: the daily home pins and builds with the
// page's scroll on desktops; elsewhere everything stays in flow.
export function initPageMotion({ settings, house }) {
  const root = document.documentElement;
  const enabled = () => !settings.paused && !settings.reduced.matches;
  const desktop = matchMedia('(min-width: 960px) and (min-height: 620px)');
  const stories = ['world'].map((name) => ({ name, element: document.querySelector(`.${name}-story`), start: 0, height: 0, previous: -1 }));
  const [worldStory] = stories;
  const animations = new Set();
  const styleOwners = new WeakMap();
  const originalStyles = new WeakMap();
  const replay = document.querySelector('.house-replay');
  const slider = document.querySelector('#world-progress');
  const chapterLinks = [...document.querySelectorAll('.chapter-nav a')];
  const chapters = chapterLinks.map((link) => ({ link, element: document.querySelector(link.hash), start: 0 }));
  const chapterNav = document.querySelector('.chapter-nav');
  let pinned = false, frame = 0, needsMeasure = true, viewportHeight = innerHeight;
  let build, hasBuilt = false, worldVisible = false, houseReady = false, loading;
  let progressAnimation, stopProgress;
  let manualHouse = false;
  let lastScrollY = scrollY;
  let restorePosition;

  function play(subject, keyframes, options = {}) {
    const nodes = typeof subject === 'string' ? [...document.querySelectorAll(subject)] : [subject];
    const properties = [...new Set(Object.keys(keyframes).map((key) => ['x', 'y', 'scale', 'rotate', 'rotateX', 'rotateY'].includes(key) ? 'transform' : key === 'clipPath' ? 'clip-path' : key).filter((key) => key !== 'pathLength'))];
    nodes.forEach((node) => {
      if (!originalStyles.has(node)) originalStyles.set(node, new Map());
      const originals = originalStyles.get(node);
      properties.forEach((property) => { if (!originals.has(property)) originals.set(property, node.style.getPropertyValue(property)); });
    });
    const animation = animate(subject, keyframes, { duration: .85, ease, ...options });
    nodes.forEach((node) => styleOwners.set(node, animation));
    animations.add(animation);
    animation.finished.then(() => {
      animations.delete(animation);
      // Completion has already released the animation. Cancelling here rewinds
      // JS-driven transforms to their first frame, scheduling a stale render
      // after this cleanup and leaving the letters/Moku tilted while scrolling.
      nodes.forEach((node) => {
        if (styleOwners.get(node) !== animation) return;
        properties.forEach((property) => {
          const original = originalStyles.get(node).get(property);
          if (original) node.style.setProperty(property, original);
          else node.style.removeProperty(property);
        });
      });
    });
    return animation;
  }
  function update() {
    frame = 0;
    if (document.hidden) return;
    if (needsMeasure) {
      viewportHeight = innerHeight;
      const y = scrollY;
      stories.forEach((story) => {
        const bounds = story.element.getBoundingClientRect();
        story.start = bounds.top + y;
        story.height = bounds.height;
      });
      chapters.forEach((chapter) => { chapter.start = chapter.element.getBoundingClientRect().top + y; });
      needsMeasure = false;
    }
    if (restorePosition) {
      const { story, progress } = restorePosition;
      restorePosition = null;
      window.scrollTo({ top: story.start + (pinned ? progress * Math.max(0, story.height - viewportHeight) : 0), behavior: 'instant' });
    }
    const y = scrollY;
    const currentChapter = chapters.filter((chapter) => chapter.start <= y + viewportHeight * .45).pop() || chapters[0];
    chapters.forEach(({ link }) => {
      if (link === currentChapter.link) {
        if (!link.hasAttribute('aria-current')) link.setAttribute('aria-current', 'location');
      } else if (link.hasAttribute('aria-current')) link.removeAttribute('aria-current');
    });
    const onWorld = y >= worldStory.start - viewportHeight * .45 && y < worldStory.start + worldStory.height - viewportHeight * .45;
    chapterNav.classList.toggle('on-dark', onWorld);
    // On phones the dock waits below the hero, so it never covers the one-liner.
    chapterNav.classList.toggle('at-hello', currentChapter.element.id === 'hello');
    lastScrollY = y;
    if (!pinned) return;
    for (const story of stories) {
      const progress = storyProgress(y, story.start, story.height, viewportHeight);
      if (Math.abs(progress - story.previous) < .0001) continue;
      story.previous = progress;
      story.savedProgress = progress;
      story.element.dataset.scrollProgress = progress.toFixed(4);
      const chapter = chapterLinks.find((link) => link.hash === `#${story.element.id}`);
      chapter?.style.setProperty('--chapter-progress', `${progress * 360}deg`);
      const style = story.element.style;
      if (story.name === 'world') {
        style.setProperty('--world-progress', progress);
        if (!manualHouse) house.setStoryProgress(progress);
        const cue = document.querySelector('.world-scroll-cue > span:last-child');
        const cueText = progress > .82 ? 'THE LIGHTS ARE ON. WELCOME HOME.' : 'SCROLL TO BUILD ↓';
        if (cue.textContent !== cueText) cue.textContent = cueText;
      }
    }
  }
  function schedule(measure = false) {
    needsMeasure ||= measure;
    if (!frame) frame = requestAnimationFrame(update);
  }
  window.addEventListener('scroll', () => schedule(), { passive: true });
  window.addEventListener('resize', () => {
    // Keep the current beat when a desktop window changes size. Measurements
    // here still describe the previous viewport, before the next render pass.
    if (pinned && desktop.matches) {
      const active = stories.find((story) => lastScrollY >= story.start && lastScrollY <= story.start + story.height - viewportHeight);
      if (active) {
        restorePosition = { story: active, progress: active.savedProgress || 0 };
      }
    }
    schedule(true);
  }, { passive: true });
  const observer = new ResizeObserver(() => schedule(true));
  stories.forEach(({ element }) => observer.observe(element));
  document.fonts.ready.then(() => schedule(true));

  function buildLabel() {
    replay.innerHTML = build ? 'PAUSE BUILD <span aria-hidden="true">Ⅱ</span>' : enabled() ? 'PLAY THE WHOLE DAY <span aria-hidden="true">↻</span>' : 'FINISH HOME <span aria-hidden="true">↗</span>';
    replay.setAttribute('aria-label', build ? 'Pause the house being built' : enabled() ? 'Replay the house being built' : 'Show the finished house');
  }
  function stopBuild() { build?.stop(); build = null; buildLabel(); }
  function playBuild() {
    stopBuild(); hasBuilt = true; manualHouse = true;
    if (!enabled()) { house.setMinutes(240, true); return; }
    house.setStoryProgress(0);
    build = animate(0, 1, {
      duration: 10, ease: 'linear',
      onUpdate: (progress) => house.setStoryProgress(progress),
      onComplete: () => { build = null; buildLabel(); },
    });
    buildLabel();
  }
  replay.addEventListener('click', () => build ? stopBuild() : playBuild());
  for (const event of ['pointerdown', 'keydown', 'input']) {
    slider.addEventListener(event, () => { hasBuilt = true; manualHouse = true; stopBuild(); });
  }
  document.addEventListener('moku:house-interaction', () => {
    hasBuilt = true;
    manualHouse = true;
    stopBuild();
  });
  function resumeScrollStory() {
    if (manualHouse) stopBuild();
    manualHouse = false;
  }
  // Focusing a control can scroll it into view. Only an intentional page
  // gesture hands control back to the story, not that automatic repositioning.
  window.addEventListener('wheel', resumeScrollStory, { passive: true });
  document.addEventListener('touchmove', (event) => {
    if (!event.target.closest('.house-canvas.is-dragging, input[type="range"]')) resumeScrollStory();
  }, { passive: true });
  document.addEventListener('pointerdown', (event) => {
    if (event.target === root && event.clientX >= root.clientWidth) resumeScrollStory();
  }, { passive: true });
  document.addEventListener('keydown', (event) => {
    if (event.defaultPrevented || event.target.closest('input, textarea, select, [contenteditable]')) return;
    if (event.key === ' ' && event.target.closest('button')) return;
    if (['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End', ' '].includes(event.key)) resumeScrollStory();
  });
  document.querySelectorAll('a[href^="#"]').forEach((link) => link.addEventListener('click', resumeScrollStory));
  const maybeBuild = () => { if (!pinned && worldVisible && houseReady && enabled() && !hasBuilt) playBuild(); };
  inView('.house-scene', () => { worldVisible = true; maybeBuild(); return () => { worldVisible = false; stopBuild(); }; }, { amount: .5 });
  function loadScene() {
    loading ??= import('./house-scene.js').then(({ createHouseScene }) => createHouseScene(document.querySelector('.house-canvas'), settings))
      .then((scene) => house.connectScene(scene))
      .catch((error) => console.warn('The 3D cottage is unavailable; showing the native preview.', error))
      .finally(() => { houseReady = true; maybeBuild(); });
    return loading;
  }
  // The 3D cottage (three.js and its models, about 1 MB) loads near its section; on a slow
  // connection or with Save-Data (loading-plan.js) the native renders tell the day, and a
  // tap turns it into 3D.
  if (plan.house3d === 'auto') {
    inView('.world-story', () => { loadScene(); }, { margin: '600px' });
  } else {
    houseReady = true;
    const scene = document.querySelector('.house-scene');
    const turn = Object.assign(document.createElement('button'), { type: 'button', className: 'house-3d', textContent: 'Turn it in 3D' });
    turn.addEventListener('click', () => {
      turn.disabled = true;
      turn.textContent = 'Loading the 3D…';
      loadScene().then(() => turn.remove());
    });
    scene?.append(turn);
  }

  // Your day's ribbon and house bar fill in as the window comes into view.
  inView('.day-window', () => {
    if (enabled()) play('.yd-ribbon > span, .yd-meter > .yd-fill', { clipPath: ['inset(0 100% 0 0)', 'inset(0 0% 0 0)'] }, { duration: 1.2, delay: stagger(.15, { startDelay: .2 }) });
  }, { amount: .3 });
  inView('.closing', () => {
    if (!enabled()) return;
    play('.closing h2', { clipPath: ['inset(0 50% 0 50%)', 'inset(0 -2% 0 -2%)'] }, { duration: 1.1 });
    play('.closing-flower', { rotate: [-90, 0], scale: [.5, 1] }, { duration: 1.5 });
  }, { amount: .3 });

  function sync() {
    const oldPinned = pinned;
    const anchor = document.activeElement?.closest('.world-pin');
    const activeStory = stories.find((story) => anchor ? story.element.contains(anchor) : lastScrollY >= story.start && lastScrollY < story.start + story.height);
    const previousProgress = activeStory?.savedProgress || 0;
    root.classList.toggle('motion-enabled', enabled());
    pinned = enabled() && desktop.matches;
    if (pinned !== oldPinned) {
      stories.forEach((story) => { story.previous = -1; });
      manualHouse = false;
      stopBuild();
      if (activeStory) {
        restorePosition = { story: activeStory, progress: previousProgress };
      }
    }
    if (enabled() && !stopProgress) {
      progressAnimation = animate('.reading-progress > span', { scaleX: [0, 1] }, { ease: 'linear' });
      stopProgress = scroll(progressAnimation);
    } else if (!enabled()) {
      for (const animation of animations) animation.complete();
      animations.clear();
      stopProgress?.(); stopProgress = null;
      progressAnimation?.cancel();
      stopBuild();
    }
    buildLabel();
    schedule(true);
    maybeBuild();
  }
  desktop.addEventListener('change', sync);
  document.addEventListener('moku:motion-change', sync);
  document.addEventListener('visibilitychange', () => { if (document.hidden) stopBuild(); else schedule(true); });
  sync();
}
