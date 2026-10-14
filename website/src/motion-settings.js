// "Pause little movements": one choice for the whole page, remembered on this
// device, and overridden by the system's reduced-motion preference.
export function initMotionSettings() {
  const settings = { reduced: matchMedia('(prefers-reduced-motion: reduce)'), paused: false };
  try { settings.paused = localStorage.getItem('moku:motion-paused') === 'true'; } catch { /* Storage is optional. */ }
  const controls = document.querySelectorAll('[data-motion-toggle]');
  const sync = () => {
    controls.forEach((button) => {
      button.textContent = settings.reduced.matches ? 'Motion reduced' : settings.paused ? 'Resume little movements' : 'Pause little movements';
      button.setAttribute('aria-label', button.textContent);  // without the decorative ::before glyph
      button.setAttribute('aria-pressed', String(settings.paused || settings.reduced.matches));
      button.disabled = settings.reduced.matches;
    });
    document.dispatchEvent(new CustomEvent('moku:motion-change'));
  };
  controls.forEach((button) => button.addEventListener('click', () => {
    settings.paused = !settings.paused;
    try { localStorage.setItem('moku:motion-paused', String(settings.paused)); } catch { /* Keep the setting in memory. */ }
    sync();
  }));
  settings.reduced.addEventListener('change', sync);
  sync();
  return settings;
}
