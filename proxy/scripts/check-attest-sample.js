// Verifies a real attestation (scripts/check-attest.sh writes build/attest-sample.json) with the relay's own verifier and
// Apple's real root certificate, and says why when it doesn't pass. Prints nothing secret: reasons and a few public facts.
import { readFileSync } from 'node:fs';
import { verifyAttestation } from '../api/_lib/attest.js';

const file = process.argv[2];
if (!file) { console.error('usage: node scripts/check-attest-sample.js <sample.json>'); process.exit(64); }
const sample = JSON.parse(readFileSync(file, 'utf8'));
const result = verifyAttestation({
  object: Buffer.from(sample.object, 'base64'), keyId: Buffer.from(sample.keyId, 'base64'), challenge: sample.challenge, device: sample.device,
  appId: process.env.MOKU_ATTEST_APP_ID || 'HTM2272E7P.ai.lightslips.moku', now: sample.capturedAt, development: process.env.MOKU_ATTEST_DEVELOPMENT === '1',
});
if (result.ok) {
  console.log(`verified: validation category ${result.category ?? 'not stated'}, app version ${result.bundleVersion ?? 'not stated'}, macOS ${sample.macOS}`);
} else {
  console.log(`NOT verified: ${result.reason}`);
  process.exitCode = 1;
}
