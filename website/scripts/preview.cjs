// What the headless checks share: Playwright, and dist/ served as Vercel serves it.
const fs = require('node:fs');
const path = require('node:path');

function playwright() {
  const candidates = [process.env.PLAYWRIGHT_MODULE, 'playwright', path.resolve(__dirname, '../../../melo-tab/node_modules/playwright'), '/Users/charlesmariajoseph/mj/lightslips.ai/melo-tab/node_modules/playwright'];
  for (const candidate of candidates.filter(Boolean)) {
    try { return require(candidate); } catch { /* the next one */ }
  }
  throw new Error('Playwright not found: set PLAYWRIGHT_MODULE to its absolute path.');
}

// vercel.json's headers, as Vercel would send them (caching, the CSP), so a check sees
// what a visitor's browser does with them. Only the patterns and conditions it uses.
function vercelHeaders() {
  const { headers = [] } = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../vercel.json'), 'utf8'));
  // A source's groups, like (.*), are regular expressions; the rest is literal.
  const pattern = (source) => new RegExp(`^${source.split(/(\(.*?\))/).map((part) => part.startsWith('(') ? part : part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('')}$`);
  const rules = headers.map((rule) => ({ ...rule, pattern: pattern(rule.source) }));
  const holds = (conditions = [], query) => conditions.every(({ type, key }) => type === 'query' && query.has(key));
  // The preview is plain http on 127.0.0.1: WebKit (Safari) obeys upgrade-insecure-requests even
  // there and asks for every file over https, which isn't served. hellomoku.com is https, so the
  // directive changes nothing there; a check of the live site sees the header exactly as sent.
  const local = (key, value) => (key.toLowerCase() === 'content-security-policy' ? value.replace(/;?\s*upgrade-insecure-requests/, '') : value);
  return {
    name: 'vercel-headers',
    configurePreviewServer(server) {
      server.middlewares.use((request, response, next) => {
        const { pathname, searchParams } = new URL(request.url, 'http://local');
        // Vercel's own default for static files, unless a rule says otherwise.
        response.setHeader('Cache-Control', 'public, max-age=0, must-revalidate');
        for (const rule of rules) {
          if (!rule.pattern.test(pathname) || !holds(rule.has, searchParams) || (rule.missing ?? []).some((c) => holds([c], searchParams))) continue;
          for (const { key, value } of rule.headers) response.setHeader(key, local(key, value));
        }
        next();
      });
    },
  };
}

// Serves dist/ (or another build, `outDir`) on 127.0.0.1:<port> until close().
async function preview(port, outDir = path.resolve(__dirname, '../dist')) {
  if (!fs.existsSync(path.join(outDir, 'index.html'))) throw new Error(`No ${path.relative(process.cwd(), outDir) || '.'}/index.html: run npm run build first.`);
  const { preview: start } = await import('vite');
  const server = await start({ root: path.resolve(__dirname, '..'), logLevel: 'warn', plugins: [vercelHeaders()], build: { outDir: path.resolve(outDir) }, preview: { host: '127.0.0.1', port, strictPort: true } });
  return { url: `http://127.0.0.1:${port}/`, close: () => new Promise((resolve) => server.httpServer.close(resolve)) };
}

module.exports = { playwright, vercelHeaders, preview };
