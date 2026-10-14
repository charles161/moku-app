// A stand-in for Apple in tests: a root, an intermediate and a leaf made here, and the attestation object an app would
// send. Every field a check reads can be changed, so each check can be failed alone. Never used outside tests.
import { createHash, createSign, generateKeyPairSync, X509Certificate } from 'node:crypto';
import { MACOS_ACL } from '../../api/_lib/attest.js';

const sha256 = (data) => createHash('sha256').update(data).digest();

// ── DER ──
const len = (n) => (n < 128 ? Buffer.from([n]) : n < 256 ? Buffer.from([0x81, n]) : Buffer.from([0x82, n >> 8, n & 255]));
const tlv = (tag, ...parts) => { const body = Buffer.concat(parts); return Buffer.concat([Buffer.from([tag]), len(body.length), body]); };
const seq = (...parts) => tlv(0x30, ...parts);
const oid = (text) => {
  const p = text.split('.').map(Number), out = [p[0] * 40 + p[1]];
  for (const n of p.slice(2)) { const c = [n & 127]; for (let r = n >> 7; r > 0; r >>= 7) c.unshift((r & 127) | 128); out.push(...c); }
  return tlv(0x06, Buffer.from(out));
};
const name = (cn) => seq(tlv(0x31, seq(oid('2.5.4.3'), tlv(0x0c, Buffer.from(cn)))));
const utc = (date) => tlv(0x17, Buffer.from(date.toISOString().replace(/[-:T]/g, '').slice(2, 14) + 'Z'));
const ecdsaSha256 = seq(oid('1.2.840.10045.4.3.2'));

/** A certificate for `subjectKey`, signed by `issuerKey`, with extensions given as [oid, DER value]. */
function certificate({ subject, issuer, subjectKey, issuerKey, notBefore, notAfter, extensions = [], ca = false }) {
  const exts = [...extensions.map(([id, value]) => seq(oid(id), tlv(0x04, value)))];
  if (ca) exts.unshift(seq(oid('2.5.29.19'), tlv(0x01, Buffer.from([0xff])), tlv(0x04, seq(tlv(0x01, Buffer.from([0xff]))))));
  const tbs = seq(
    tlv(0xa0, tlv(0x02, Buffer.from([2]))), tlv(0x02, Buffer.from([1, Math.floor(Math.random() * 100) + 1])), ecdsaSha256,
    name(issuer), seq(utc(notBefore), utc(notAfter)), name(subject),
    subjectKey.export({ type: 'spki', format: 'der' }), tlv(0xa3, seq(...exts)),
  );
  const signature = createSign('sha256').update(tbs).sign(issuerKey);
  return seq(tbs, ecdsaSha256, tlv(0x03, Buffer.concat([Buffer.from([0]), signature])));
}

// ── CBOR ──
const head = (major, n) => (n < 24 ? Buffer.from([(major << 5) | n]) : n < 256 ? Buffer.from([(major << 5) | 24, n]) : Buffer.from([(major << 5) | 25, n >> 8, n & 255]));
export function cbor(value) {
  if (Buffer.isBuffer(value)) return Buffer.concat([head(2, value.length), value]);
  if (typeof value === 'string') { const b = Buffer.from(value); return Buffer.concat([head(3, b.length), b]); }
  if (typeof value === 'number') return value >= 0 ? head(0, value) : head(1, -1 - value);
  if (Array.isArray(value)) return Buffer.concat([head(4, value.length), ...value.map(cbor)]);
  const entries = value instanceof Map ? [...value] : Object.entries(value);
  return Buffer.concat([head(5, entries.length), ...entries.flatMap(([k, v]) => [cbor(k), cbor(v)])]);
}

const DAY = 86_400_000;
export const APP_ID = 'HTM2272E7P.ai.lightslips.moku';

/** A fake Apple: its root (as PEM, to hand to verifyAttestation) and a way to attest a key. */
export function fakeApple({ now = Date.now() } = {}) {
  const ec = () => generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const rootKeys = ec(), middleKeys = ec();
  const years = (n) => new Date(now + n * 365 * DAY);
  const rootDer = certificate({ subject: 'Fake App Attestation Root', issuer: 'Fake App Attestation Root', subjectKey: rootKeys.publicKey, issuerKey: rootKeys.privateKey, notBefore: years(-1), notAfter: years(10), ca: true });
  const middleDer = certificate({ subject: 'Fake App Attestation CA 1', issuer: 'Fake App Attestation Root', subjectKey: middleKeys.publicKey, issuerKey: rootKeys.privateKey, notBefore: years(-1), notAfter: years(5), ca: true });
  const pem = (der) => `-----BEGIN CERTIFICATE-----\n${der.toString('base64').match(/.{1,64}/g).join('\n')}\n-----END CERTIFICATE-----`;

  /**
   * What the app sends for `challenge` on `device`. Any step can be changed: `appId`, `counter`, `aaguid`, `acl`,
   * `category` (null: no extensions), `nonce` (a Buffer to put in the leaf instead), `chain` ('swap', 'foreign',
   * 'expired'), `key` (id given to the relay instead of the real one), `format`, `attestedKeys` (a key made earlier).
   */
  function attest({ challenge, device, appId = APP_ID, counter = 0, aaguid = Buffer.concat([Buffer.from('appattest'), Buffer.alloc(7)]), acl = MACOS_ACL, category = 6, nonce, chain, key, format = 'apple-appattest', leafKeys = ec() } = {}) {
    const jwk = leafKeys.publicKey.export({ format: 'jwk' });
    const point = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url')]);
    const keyId = sha256(point);
    const cose = cbor(new Map([[1, 2], [3, -7], [-1, 1], [-2, Buffer.from(jwk.x, 'base64url')], [-3, Buffer.from(jwk.y, 'base64url')]]));
    const counterBytes = Buffer.alloc(4); counterBytes.writeUInt32BE(counter);
    const extensions = category === null ? Buffer.alloc(0) : cbor({ apple_validation_category_01: category, apple_bundle_version_01: '0.1.12' });
    const authData = Buffer.concat([sha256(appId), Buffer.from([category === null ? 0x40 : 0xc0]), counterBytes, aaguid, Buffer.from([0, 32]), keyId, cose, extensions]);
    const clientHash = sha256(Buffer.from(`${challenge}:${device}`));
    const wanted = nonce ?? sha256(Buffer.concat([authData, clientHash]));
    const leafDer = certificate({
      subject: 'Fake attested key', issuer: 'Fake App Attestation CA 1', subjectKey: leafKeys.publicKey, issuerKey: middleKeys.privateKey,
      notBefore: chain === 'expired' ? years(-3) : new Date(now - DAY), notAfter: chain === 'expired' ? new Date(now - DAY) : new Date(now + 2 * DAY),
      extensions: [['1.2.840.113635.100.8.2', seq(tlv(0xa1, tlv(0x04, wanted)))], ['1.2.840.113635.100.8.6', seq(tlv(0x04, Buffer.isBuffer(acl) ? acl : Buffer.from(acl)))]],
    });
    const other = ec();
    const foreign = certificate({ subject: 'Fake App Attestation CA 1', issuer: 'Fake App Attestation Root', subjectKey: middleKeys.publicKey, issuerKey: other.privateKey, notBefore: years(-1), notAfter: years(5), ca: true });
    const x5c = chain === 'swap' ? [middleDer, leafDer] : chain === 'foreign' ? [leafDer, foreign] : [leafDer, middleDer];
    const object = cbor({ fmt: format, attStmt: { x5c, receipt: Buffer.from('receipt') }, authData });
    return { object, keyId: key ?? keyId, leafKeys, authData };
  }

  return { root: pem(rootDer), attest, X509Certificate };
}
