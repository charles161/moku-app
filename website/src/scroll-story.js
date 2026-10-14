export const clamp = (value, low = 0, high = 1) => Math.max(low, Math.min(high, Number.isFinite(value) ? value : low));

export function storyProgress(scrollTop, start, height, viewportHeight) {
  return clamp((scrollTop - start) / Math.max(1, height - viewportHeight));
}
