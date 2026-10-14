// @ts-check
import { createProxy } from './_lib/proxy.js';

/**
 * The one function: POST /v4/ai/{evaluation-model,language-model} (rewritten here by vercel.json),
 * GET /health and /get (HEAD too). Configuration comes from the project's environment variables (README.md).
 */
const handle = createProxy({ env: process.env });

export function POST(/** @type {Request} */ request) {
  return handle(request);
}

export function GET(/** @type {Request} */ request) {
  return handle(request);
}

// A HEAD on /get (hellomoku.com/download): Vercel would answer 405 for a method not exported here.
export function HEAD(/** @type {Request} */ request) {
  return handle(request);
}
