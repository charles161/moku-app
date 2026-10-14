// @ts-check
import { randomBytes } from 'node:crypto';
import { hashToken } from '../api/_lib/proxy.js';

/**
 * `npm run new-token -- <tester name>`: a fresh token for one tester. Prints the token (give it to
 * the tester, once, privately; it goes in their ~/.moku/credentials.env) and the entry to add to
 * MOKU_TESTER_TOKENS on Vercel. The proxy only ever sees the hash.
 */
const name = (process.argv[2] ?? '').trim();
if (!/^[a-z0-9][a-z0-9_-]{0,31}$/i.test(name)) {
  console.error('usage: npm run new-token -- <tester name: letters, digits, - or _>');
  process.exit(1);
}
const token = `moku_${randomBytes(32).toString('base64url')}`;
console.log(`token for ${name} (give it to them; it is not stored anywhere):\n  ${token}\n`);
console.log(`add to MOKU_TESTER_TOKENS (comma-separated):\n  ${name}:${hashToken(token)}\n`);
console.log(`their ~/.moku/credentials.env:\n  MOKU_GATEWAY_URL=https://<your-proxy>.vercel.app/v4/ai\n  MOKU_ACCESS_TOKEN=${token}`);
