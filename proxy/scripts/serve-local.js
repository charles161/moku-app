// @ts-check
import { createServer } from 'node:http';
import { createProxy } from '../api/_lib/proxy.js';

/**
 * `npm run local` (PORT, AI_GATEWAY_API_KEY and MOKU_TESTER_TOKENS in the environment): the proxy
 * on http://127.0.0.1:PORT, for trying it before deploying. Point a brain at it with
 * MOKU_GATEWAY_URL=http://127.0.0.1:PORT/v4/ai and MOKU_ACCESS_TOKEN=<a tester token>.
 */
const handle = createProxy({ env: process.env });
const port = Number(process.env.PORT || 8787);
createServer(async (req, res) => {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const headers = new Headers();
  for (const [name, value] of Object.entries(req.headers)) if (typeof value === 'string') headers.set(name, value);
  const request = new Request(`http://127.0.0.1:${port}${req.url}`, {
    method: req.method, headers, body: req.method === 'GET' || req.method === 'HEAD' ? undefined : Buffer.concat(chunks),
  });
  const response = await handle(request);
  res.writeHead(response.status, Object.fromEntries(response.headers));
  res.end(Buffer.from(await response.arrayBuffer()));
}).listen(port, '127.0.0.1', () => console.log(`moku-proxy on http://127.0.0.1:${port} (POST /v4/ai/{evaluation-model,language-model}, GET /health)`));
