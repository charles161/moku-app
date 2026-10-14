// @ts-check
import { isIPv4, isIPv6 } from 'node:net';

/**
 * Who a per-address limit counts (installs, heartbeats, usage events, website errors, downloads): the address a request
 * came from, as Vercel gives it (the first in x-forwarded-for, which Vercel sets itself, else x-real-ip).
 *
 * An IPv4 address is itself. An IPv6 address is its /64: one home or phone gets a whole /64, so keyed by the full
 * address a single machine could step through 2^64 of them and never meet a limit (security review 2026-10-05). An
 * IPv4-mapped address (::ffff:a.b.c.d) is the IPv4 address it carries. Brackets, a port and a zone id don't count.
 */
export function clientAddress(/** @type {Request} */ request) {
  return addressKey((request.headers.get('x-forwarded-for') ?? request.headers.get('x-real-ip') ?? '').split(',')[0]);
}

/** "2001:db8:85a3::8a2e:370:7334" → "2001:db8:85a3:0::/64"; "::ffff:203.0.113.7" → "203.0.113.7"; "" → "unknown". */
export function addressKey(/** @type {string} */ raw) {
  let address = raw.trim().toLowerCase();
  if (!address) return 'unknown';
  const bracketed = /^\[([^\]]+)\](?::\d+)?$/.exec(address);
  if (bracketed) address = bracketed[1];
  else if (/^[\d.]+:\d+$/.test(address)) address = address.slice(0, address.lastIndexOf(':'));
  address = address.replace(/%.*$/, '');
  if (isIPv4(address)) return address;
  if (!isIPv6(address)) return address.slice(0, 64);  // not an address: Vercel never sends one; kept, cut short
  const groups = hextets(address);
  if (groups.slice(0, 5).every((g) => g === 0) && groups[5] === 0xffff) {
    return [groups[6] >> 8, groups[6] & 0xff, groups[7] >> 8, groups[7] & 0xff].join('.');
  }
  return `${groups.slice(0, 4).map((g) => g.toString(16)).join(':')}::/64`;
}

/** A valid IPv6 address (no zone) → its eight 16-bit groups. */
function hextets(/** @type {string} */ address) {
  const tail = address.replace(/(\d+)\.(\d+)\.(\d+)\.(\d+)$/, (_, a, b, c, d) => `${((+a << 8) | +b).toString(16)}:${((+c << 8) | +d).toString(16)}`);
  const [head, rest] = tail.split('::');
  const before = head ? head.split(':') : [];
  const after = rest === undefined ? [] : rest ? rest.split(':') : [];
  const zeros = rest === undefined ? [] : Array(8 - before.length - after.length).fill('0');
  return [...before, ...zeros, ...after].map((group) => parseInt(group, 16));
}
