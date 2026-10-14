// @ts-check
import { randomInt } from 'node:crypto';
import { hashInvite } from '../api/_lib/access.js';

/**
 * `npm run new-invite -- <name>`: a readable invite code (MOKU-XXXX-XXXX) for a friend or a group, and the entry to
 * add to MOKU_INVITES on Vercel. The relay keeps only the hash; anyone with the code gets tester access.
 */
const name = (process.argv[2] ?? '').trim();
if (!/^[a-z0-9][a-z0-9_-]{0,31}$/i.test(name)) { console.error('usage: npm run new-invite -- <name>'); process.exit(1); }
const letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O, 1/I
const pick = (n) => Array.from({ length: n }, () => letters[randomInt(letters.length)]).join('');
const code = `MOKU-${pick(4)}-${pick(4)}`;
console.log(`invite code for ${name}:\n  ${code}\n`);
console.log(`add to MOKU_INVITES (comma-separated):\n  ${name}:${hashInvite(code)}`);
