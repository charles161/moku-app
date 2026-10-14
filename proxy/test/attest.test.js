import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createHash } from 'node:crypto';
import { APPLE_ATTEST_ROOT, CHALLENGE_MINUTES, challengeIsFresh, decodeCbor, MACOS_ACL, newChallenge, verifyAttestation } from '../api/_lib/attest.js';
import { APP_ID, cbor, fakeApple } from './support/fake-apple.js';

const DEVICE = 'a'.repeat(64);
const CHALLENGE = 'challenge-from-the-relay';
const apple = fakeApple();
const check = (made, extra = {}) => verifyAttestation({ object: made.object, keyId: made.keyId, challenge: CHALLENGE, device: DEVICE, appId: APP_ID, root: apple.root, ...extra });
const made = (extra = {}) => apple.attest({ challenge: CHALLENGE, device: DEVICE, ...extra });

test('a genuine attestation is accepted and says how the app was launched', () => {
  const result = check(made());
  assert.equal(result.ok, true);
  assert.equal(result.category, 6);
  assert.equal(result.bundleVersion, '0.1.12');
  assert.equal(result.publicKey.length, 65);
});

test('each check fails alone, with its own reason', () => {
  const cases = [
    ['a wrong format', made({ format: 'packed' }), 'format'],
    ['a chain in the wrong order', made({ chain: 'swap' }), 'chain'],
    ['an intermediate Apple did not sign', made({ chain: 'foreign' }), 'chain'],
    ['an expired leaf', made({ chain: 'expired' }), 'chain'],
    ['a nonce for another statement', made({ nonce: Buffer.alloc(32, 7) }), 'nonce'],
    ['a key without the SIP and full security policy', made({ acl: 'MEAMAjExMDowCQwCb2uhAwEB/zAJDAJvYaEDAQH/MAsMBG9kZWyhAwEB/zAVDARvc2duoAYMBHJzZWMwBaYDAgEB-weaker' }), 'acl'],
    ['a key id that is not the key', made({ key: Buffer.alloc(32, 1) }), 'key'],
    ['another app (a re-signed Moku has another team)', made({ appId: 'ABCDE12345.ai.lightslips.moku' }), 'rp'],
    ['a key already used', made({ counter: 1 }), 'counter'],
    ['a development key', made({ aaguid: Buffer.from('appattestdevelop') }), 'aaguid'],
    ['an app not launched from a Developer ID signature', made({ category: 3 }), 'category'],
  ];
  for (const [what, attestation, reason] of cases) assert.deepEqual(check(attestation), { ok: false, reason }, what);
});

test('the attestation is for this challenge and this Mac', () => {
  assert.equal(check(made(), { challenge: 'another-challenge' }).reason, 'nonce');
  assert.equal(check(made(), { device: 'b'.repeat(64) }).reason, 'nonce', 'a genuine Moku vouches only for its own Mac');
});

test('the root is pinned: another Apple, even a perfect fake, is refused', () => {
  const stranger = fakeApple();
  assert.equal(check(made(), { root: stranger.root }).reason, 'chain');
  assert.equal(check(made(), { root: APPLE_ATTEST_ROOT }).reason, 'chain', 'the real root did not sign this');
});

test('certificates out of date are refused, whenever the check runs', () => {
  assert.equal(check(made(), { now: Date.now() + 5 * 86_400_000 }).reason, 'chain');
});

test('a development key passes only where development is allowed', () => {
  const dev = made({ aaguid: Buffer.from('appattestdevelop') });
  assert.equal(check(dev).reason, 'aaguid');
  assert.equal(check(dev, { development: true }).ok, true);
});

test('no extensions is fine: the category is only checked when present', () => {
  assert.equal(check(made({ category: null })).ok, true);
});

test('the access policy may be the bytes Apple\'s base64 stands for', () => {
  const asBytes = made({ acl: Buffer.from(MACOS_ACL, 'base64') });
  assert.equal(check(asBytes).ok, true);
});

test('garbage never throws', () => {
  for (const object of [Buffer.alloc(0), Buffer.from('not cbor'), Buffer.from([0xa0]), cbor({ fmt: 'apple-appattest' }), cbor([1, 2]), Buffer.alloc(40, 0xff)]) {
    const result = verifyAttestation({ object, keyId: Buffer.alloc(32), challenge: CHALLENGE, device: DEVICE, appId: APP_ID, root: apple.root });
    assert.equal(result.ok, false);
  }
  assert.equal(verifyAttestation({ object: made().object, keyId: Buffer.alloc(32), challenge: CHALLENGE, device: DEVICE, appId: APP_ID, root: 'not a certificate' }).reason, 'chain');
});

test('the CBOR reader reads what App Attest sends and refuses the rest', () => {
  const value = decodeCbor(cbor({ a: 1, b: [Buffer.from([1, 2]), 'x', -5], c: new Map([[1, 2]]) })).value;
  assert.deepEqual([...value.keys()], ['a', 'b', 'c']);
  assert.deepEqual(value.get('b'), [Buffer.from([1, 2]), 'x', -5]);
  assert.throws(() => decodeCbor(Buffer.from([0x5f, 0x41, 0x01, 0xff])), 'indefinite lengths');
  assert.throws(() => decodeCbor(Buffer.from([0x45, 1, 2])), 'a string longer than the input');
  assert.throws(() => decodeCbor(Buffer.from([0x9b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])), 'an absurd length');
  assert.throws(() => decodeCbor(Buffer.from([0x81, 0x81, 0x81, 0x81, 0x81, 0x81, 0x81, 0x81, 0x81, 0x81, 0x00])), 'too deep');
});

test('a challenge is the relay\'s own, fresh, and used once in time', () => {
  const now = 1_800_000_000_000;
  const challenge = newChallenge('secret', now);
  assert.equal(challengeIsFresh(challenge, 'secret', now + 1000), true);
  assert.equal(challengeIsFresh(challenge, 'secret', now + CHALLENGE_MINUTES * 60_000), true);
  assert.equal(challengeIsFresh(challenge, 'secret', now + CHALLENGE_MINUTES * 60_000 + 1), false, 'too old');
  assert.equal(challengeIsFresh(challenge, 'secret', now - 120_000), false, 'from the future');
  assert.equal(challengeIsFresh(challenge, 'other', now), false, 'another relay\'s');
  // The signature's first character: its last one's low bits are base64 padding, so changing it could leave the bytes as
  // they were (the test failed about one run in 16).
  assert.equal(challengeIsFresh(challenge.replace(/\.([^.])([^.]*)$/, (_, c, rest) => `.${c === 'A' ? 'B' : 'A'}${rest}`), 'secret', now), false, 'tampered');
  for (const junk of ['', 'a.b', 'a.b.c.d', '..', 'x'.repeat(5000)]) assert.equal(challengeIsFresh(junk, 'secret', now), false);
  assert.notEqual(newChallenge('secret', now), newChallenge('secret', now), 'never the same twice');
});

test('the pinned root is Apple\'s', () => {
  const fingerprint = createHash('sha256').update(Buffer.from(APPLE_ATTEST_ROOT.replace(/-----[A-Z ]+-----|\s/g, ''), 'base64')).digest('hex');
  assert.equal(fingerprint, '1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932');
});
