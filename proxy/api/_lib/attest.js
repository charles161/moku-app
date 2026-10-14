// @ts-check
import { createHash, createHmac, randomBytes, timingSafeEqual, X509Certificate } from 'node:crypto';

/**
 * Apple App Attest, checked on the relay (docs/specs/app-attest.md). A Mac that asks for a trial can prove, with a
 * statement Apple signed, that it is a real Apple-silicon Mac (full security, SIP on) running an app signed by our
 * team with our identifier. A re-signed or modified Moku has another team, so it can't.
 *
 * `verifyAttestation` follows Apple's list ("Validating apps that connect to your server") step by step and answers
 * `{ ok: true, … }` or `{ ok: false, reason }` with one word for what failed. No dependencies: a small CBOR reader and
 * a small DER reader are all it takes. Nothing here keeps anything; the caller decides what a failure costs.
 */

/** Apple App Attestation Root CA (valid to 2045-03-15), from https://www.apple.com/certificateauthority/. SHA-256 1CB9823B…42C932. */
export const APPLE_ATTEST_ROOT = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`;

/** What the Mac says in `aclBlob` (OID 1.2.840.113635.100.8.6) with SIP and full security on: Apple's one accepted value. */
export const MACOS_ACL = 'MEAMAjExMDowCQwCb2uhAwEB/zAJDAJvYaEDAQH/MAsMBG9kZWyhAwEB/zAVDARvc2duoAYMBHJzZWMwBaYDAgEB';

/** Apple's validation category for an app launched from a Developer ID signature. */
export const DEVELOPER_ID = 6;

const OID_NONCE = '1.2.840.113635.100.8.2';
const OID_ACL = '1.2.840.113635.100.8.6';
const sha256 = (/** @type {Buffer | string} */ data) => createHash('sha256').update(data).digest();

// ───────────────────────────── CBOR (what an attestation object uses) ─────────────────────────────

/**
 * One CBOR item from `buf` at `at`: maps (as Map), arrays, byte and text strings, integers up to 2^53, booleans and null.
 * Indefinite lengths and tags aren't used by App Attest and are refused.
 * @returns {{ value: unknown, end: number }}
 */
export function decodeCbor(/** @type {Buffer} */ buf, at = 0, depth = 0) {
  if (depth > 8 || at >= buf.length) throw new Error('cbor');
  const head = buf[at], major = head >> 5, info = head & 31;
  let p = at + 1, length = info;
  if (info === 24) { length = buf.readUInt8(p); p += 1; }
  else if (info === 25) { length = buf.readUInt16BE(p); p += 2; }
  else if (info === 26) { length = buf.readUInt32BE(p); p += 4; }
  else if (info === 27) {
    const big = buf.readBigUInt64BE(p);
    if (big > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('cbor');
    length = Number(big); p += 8;
  } else if (info > 27) {
    if (major === 7 && info >= 20 && info <= 22) return { value: info === 22 ? null : info === 21, end: p };
    throw new Error('cbor');
  }
  if (major === 0) return { value: length, end: p };
  if (major === 1) return { value: -1 - length, end: p };
  if (major === 2 || major === 3) {
    if (p + length > buf.length) throw new Error('cbor');
    const bytes = buf.subarray(p, p + length);
    return { value: major === 2 ? Buffer.from(bytes) : bytes.toString('utf8'), end: p + length };
  }
  if (major === 4 || major === 5) {
    if (length > buf.length) throw new Error('cbor');
    const items = [];
    for (let i = 0; i < (major === 5 ? length * 2 : length); i++) {
      const item = decodeCbor(buf, p, depth + 1);
      items.push(item.value); p = item.end;
    }
    if (major === 4) return { value: items, end: p };
    const map = new Map();
    for (let i = 0; i < items.length; i += 2) map.set(items[i], items[i + 1]);
    return { value: map, end: p };
  }
  throw new Error('cbor');
}

// ───────────────────────────── DER (certificates and their extensions) ─────────────────────────────

/** @returns {{ tag: number, start: number, end: number }} the item at `at`: its tag and where its content runs. */
function der(/** @type {Buffer} */ buf, /** @type {number} */ at) {
  if (at + 2 > buf.length) throw new Error('der');
  const tag = buf[at];
  let length = buf[at + 1], p = at + 2;
  if (length & 0x80) {
    const n = length & 0x7f;
    if (n < 1 || n > 4 || p + n > buf.length) throw new Error('der');
    length = 0;
    for (let i = 0; i < n; i++) length = length * 256 + buf[p + i];
    p += n;
  }
  if (p + length > buf.length) throw new Error('der');
  return { tag, start: p, end: p + length };
}

/** The first OCTET STRING anywhere inside a DER value: Apple's extensions wrap theirs in one or two SEQUENCEs. */
export function firstOctetString(/** @type {Buffer} */ buf, from = 0, to = buf.length, depth = 0) {
  for (let p = from; p < to && depth < 6;) {
    const item = der(buf, p);
    if (item.tag === 0x04) return buf.subarray(item.start, item.end);
    if (item.tag & 0x20) {
      const inner = firstOctetString(buf, item.start, item.end, depth + 1);
      if (inner) return inner;
    }
    p = item.end;
  }
  return null;
}

const oidBytes = (/** @type {string} */ oid) => {
  const parts = oid.split('.').map(Number);
  const out = [parts[0] * 40 + parts[1]];
  for (const part of parts.slice(2)) {
    const chunk = [part & 0x7f];
    for (let rest = Math.floor(part / 128); rest > 0; rest = Math.floor(rest / 128)) chunk.unshift((rest & 0x7f) | 0x80);
    out.push(...chunk);
  }
  return Buffer.from(out);
};

/** The value (the OCTET STRING's content) of extension `oid` in a DER certificate, or null. */
export function certExtension(/** @type {Buffer} */ cert, /** @type {string} */ oid) {
  const want = oidBytes(oid);
  const outer = der(cert, 0);
  const tbs = der(cert, outer.start);
  for (let p = tbs.start; p < tbs.end;) {
    const field = der(cert, p);
    if (field.tag === 0xa3) {
      const list = der(cert, field.start);
      for (let q = list.start; q < list.end;) {
        const ext = der(cert, q);
        const id = der(cert, ext.start);
        if (id.tag === 0x06 && cert.subarray(id.start, id.end).equals(want)) {
          let v = id.end;
          if (cert[v] === 0x01) v = der(cert, v).end; // `critical`
          const value = der(cert, v);
          return value.tag === 0x04 ? cert.subarray(value.start, value.end) : null;
        }
        q = ext.end;
      }
    }
    p = field.end;
  }
  return null;
}

// ───────────────────────────── The attestation ─────────────────────────────

/** What the app signs over with the challenge: this challenge, for this Mac. */
export const clientData = (/** @type {string} */ challenge, /** @type {string} */ device) => Buffer.from(`${challenge}:${device}`);

const equal = (/** @type {Buffer} */ a, /** @type {Buffer} */ b) => a.length === b.length && timingSafeEqual(a, b);
const fail = (/** @type {string} */ reason) => /** @type {const} */ ({ ok: false, reason });

/**
 * Whether an attestation object proves a genuine app on a genuine Mac, for this challenge and device.
 * @param {{ object: Buffer, keyId: Buffer, challenge: string, device: string, appId: string,
 *   root?: string, now?: number, development?: boolean, categories?: number[] }} input
 * @returns {{ ok: true, publicKey: Buffer, category: number | null, bundleVersion: string | null } | { ok: false, reason: string }}
 */
export function verifyAttestation({ object, keyId, challenge, device, appId, root = APPLE_ATTEST_ROOT, now = Date.now(), development = false, categories = [DEVELOPER_ID] }) {
  /** @type {Map<string, any>} */
  let decoded;
  try {
    const top = decodeCbor(object).value;
    if (!(top instanceof Map)) return fail('format');
    decoded = top;
  } catch { return fail('format'); }
  const statement = decoded.get('attStmt'), authData = decoded.get('authData');
  if (decoded.get('fmt') !== 'apple-appattest' || !(statement instanceof Map) || !Buffer.isBuffer(authData)) return fail('format');
  const chain = statement.get('x5c');
  if (!Array.isArray(chain) || chain.length !== 2 || !chain.every(Buffer.isBuffer)) return fail('format');

  // 1. The chain: leaf ← Apple's intermediate ← Apple's root (pinned), every one in date.
  /** @type {X509Certificate[]} */
  let certs;
  let anchor;
  try {
    certs = chain.map((raw) => new X509Certificate(raw));
    anchor = new X509Certificate(root);
  } catch { return fail('chain'); }
  const [leaf, middle] = certs;
  const when = new Date(now);
  const inDate = [leaf, middle, anchor].every((c) => new Date(c.validFrom) <= when && when <= new Date(c.validTo));
  if (!inDate || !leaf.checkIssued(middle) || !middle.checkIssued(anchor) || !leaf.verify(middle.publicKey) || !middle.verify(anchor.publicKey) || !anchor.verify(anchor.publicKey)) return fail('chain');

  // 2–4. The nonce Apple put in the leaf is SHA-256(authData ‖ SHA-256(clientData)).
  const nonce = sha256(Buffer.concat([authData, sha256(clientData(challenge, device))]));
  let seen = null, acl = null;
  try {
    const nonceExt = certExtension(chain[0], OID_NONCE);
    seen = nonceExt && firstOctetString(nonceExt);
    const aclExt = certExtension(chain[0], OID_ACL);
    acl = aclExt && firstOctetString(aclExt);
  } catch { return fail('chain'); }
  if (!seen || !equal(seen, nonce)) return fail('nonce');
  // On macOS the key's access policy must be the one for SIP on and full security (Apple: the exact value, never changes).
  // Apple prints it in base64; the extension might hold that text or the bytes it stands for.
  if (!acl || !(acl.toString('latin1') === MACOS_ACL || equal(acl, Buffer.from(MACOS_ACL, 'base64')))) return fail('acl');

  // 5. SHA-256 of the key's X9.62 uncompressed point is the key id.
  const jwk = leaf.publicKey.export({ format: 'jwk' });
  if (jwk.kty !== 'EC' || jwk.crv !== 'P-256' || !jwk.x || !jwk.y) return fail('key');
  const publicKey = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url')]);
  if (!equal(sha256(publicKey), keyId)) return fail('key');

  // 6–9. authData: rpIdHash(32) flags(1) counter(4) aaguid(16) credIdLength(2) credId, then the key, then extensions.
  if (authData.length < 55) return fail('format');
  if (!equal(authData.subarray(0, 32), sha256(appId))) return fail('rp');
  if (authData.readUInt32BE(33) !== 0) return fail('counter');
  const aaguid = authData.subarray(37, 53);
  const live = Buffer.concat([Buffer.from('appattest'), Buffer.alloc(7)]);
  if (!(equal(aaguid, live) || (development && equal(aaguid, Buffer.from('appattestdevelop'))))) return fail('aaguid');
  const idLength = authData.readUInt16BE(53);
  if (authData.length < 55 + idLength || !equal(authData.subarray(55, 55 + idLength), keyId)) return fail('key');

  // 10–11. Extensions (after the COSE key), when there are any: how the app was launched, and its version.
  let category = null, bundleVersion = null;
  try {
    const key = decodeCbor(authData, 55 + idLength);
    if (key.end < authData.length) {
      const extensions = decodeCbor(authData, key.end).value;
      if (extensions instanceof Map) {
        const c = extensions.get('apple_validation_category_01'), v = extensions.get('apple_bundle_version_01');
        category = typeof c === 'number' ? c : null;
        bundleVersion = typeof v === 'string' ? v.slice(0, 40) : null;
      }
    }
  } catch { return fail('format'); }
  if (category !== null && !categories.includes(category)) return fail('category');
  return { ok: true, publicKey, category, bundleVersion };
}

// ───────────────────────────── Challenges ─────────────────────────────

/** How long a challenge may be answered. */
export const CHALLENGE_MINUTES = 10;

/** A challenge the relay can recognise without keeping it: `<random>.<time>.<mac>`. */
export function newChallenge(/** @type {string} */ secret, /** @type {number} */ now) {
  const body = `${randomBytes(16).toString('base64url')}.${now.toString(36)}`;
  return `${body}.${createHmac('sha256', `attest-challenge:${secret}`).update(body).digest('base64url')}`;
}

/** Whether `challenge` is one this relay made, no older than CHALLENGE_MINUTES and not from the future. */
export function challengeIsFresh(/** @type {string} */ challenge, /** @type {string} */ secret, /** @type {number} */ now) {
  const [random, time, mac, extra] = challenge.split('.');
  if (!random || !time || !mac || extra !== undefined) return false;
  const want = createHmac('sha256', `attest-challenge:${secret}`).update(`${random}.${time}`).digest();
  const got = Buffer.from(mac, 'base64url');
  if (!equal(want, got)) return false;
  const made = parseInt(time, 36);
  return Number.isFinite(made) && made <= now + 60_000 && now - made <= CHALLENGE_MINUTES * 60_000;
}
