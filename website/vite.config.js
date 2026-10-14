import { defineConfig } from 'vite';
import { fileURLToPath } from 'node:url';
import { existsSync, readdirSync, statSync } from 'node:fs';

// Four pages: the site, its privacy policy, its changelog and the thanks after a purchase (served at /privacy, /changelog
// and /thanks; vercel.json has cleanUrls).
// changelog.html is written from CHANGELOG.md by scripts/changelog.mjs (npm run build runs it first).
const page = (name) => fileURLToPath(new URL(name, import.meta.url));

// Which companions this build has files for: clips in public/motion/<id>/ (the hero's
// switcher shows them) and home renders in public/images/house/<id>/ (the home section).
function companionFiles() {
  const folders = (path) => { try { return readdirSync(page(path)).filter((name) => statSync(page(`${path}/${name}`)).isDirectory()); } catch { return []; } };
  const files = {};
  for (const id of new Set([...folders('public/motion'), ...folders('public/images/house')])) {
    files[id] = { clips: existsSync(page(`public/motion/${id}/manifest.json`)), home: existsSync(page(`public/images/house/${id}/240.webp`)) };
  }
  return files;
}

// The home page's CSS goes inside its HTML, first in <head>: on a slow connection the text
// then paints with the page's first 30 KB, rather than waiting for a stylesheet that shares
// the line with the script, the fonts and the pictures (docs/specs/next-0-1-9.md §3). The
// HTML is revalidated on every visit and a 304 costs nothing, so nothing is downloaded twice.
// The CSP allows inline styles ('unsafe-inline' in style-src), never inline scripts.
function inlineStyles(page = 'index.html') {
  return {
    name: 'inline-styles',
    apply: 'build',
    enforce: 'post',
    generateBundle(_, bundle) {
      const html = bundle[page];
      if (!html) return;
      const styles = [];
      let source = String(html.source).replace(/\s*<link rel="stylesheet"(?: crossorigin)? href="\/(assets\/[^"]+\.css)">/g, (tag, file) => {
        if (!bundle[file]) return tag;
        styles.push(String(bundle[file].source));
        return '';
      });
      source = source.replace(/(<meta name="viewport"[^>]*>)/, `$1\n    <style>${styles.join('\n')}</style>`);
      html.source = source;
      // A stylesheet no other page links is gone from the build.
      const pages = Object.values(bundle).filter((file) => file.fileName.endsWith('.html') && file !== html).map((file) => String(file.source));
      for (const name of Object.keys(bundle)) {
        if (name.endsWith('.css') && !pages.some((other) => other.includes(name))) delete bundle[name];
      }
    },
  };
}

export default defineConfig({
  plugins: [inlineStyles()],
  // __VERCEL_OBSERVABILITY__: the script and intake addresses Vercel sets for a build (src/vercel-insights.js), or null.
  define: { __COMPANION_FILES__: JSON.stringify(companionFiles()), __VERCEL_OBSERVABILITY__: JSON.stringify(process.env.VERCEL_OBSERVABILITY_CLIENT_CONFIG ?? null) },
  // The headline's serif comes inside the page's CSS (21 KB), so the first paint is already set in it.
  build: { assetsInlineLimit: (file) => (/serif-(normal|italic)\.woff2$/.test(file) ? true : undefined), rollupOptions: { input: { main: page('index.html'), privacy: page('privacy.html'), changelog: page('changelog.html'), thanks: page('thanks.html') } } },
});
