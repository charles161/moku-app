// Pictures below the fold load as they come near (within half a screen), not when
// the browser's own lazy loading would: Chrome starts those up to 2500 px ahead on a slow
// connection, so a phone paid for the friends' cards before the hero's clips. Mark them
// <img data-near-src="…"> (no src). Without IntersectionObserver they load at once.
// A row you swipe (the friends' cards on a phone) is marked data-near-group and loads as
// one: its cards past the row's edge are clipped by the row, so they'd never count as near
// and would pop in mid-swipe.
export function loadNear(root = document) {
  const images = [...root.querySelectorAll('img[data-near-src]')];
  const show = (image) => {
    if (!image.dataset.nearSrc) return;
    if (!image.getAttribute('src')) image.src = image.dataset.nearSrc;
    delete image.dataset.nearSrc;
  };
  if (typeof IntersectionObserver === 'undefined') { images.forEach(show); return; }
  const groups = new Map();
  for (const image of images) {
    const target = image.closest('[data-near-group]') ?? image;
    if (!groups.has(target)) groups.set(target, []);
    groups.get(target).push(image);
  }
  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      groups.get(entry.target).forEach(show);
      observer.unobserve(entry.target);
    }
  }, { rootMargin: '50% 0px' });
  groups.forEach((_, target) => observer.observe(target));
}
