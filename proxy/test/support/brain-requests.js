// @ts-check
// The requests Moku's brain sends, byte for byte: brain-go's own fixtures (brain-go/internal/brain/testdata, checked
// against the AI SDK's bytes by gateway_test.go), the same gateway.go in every build shipped (0.1.0 to 0.1.13). The
// relay must always take them; a test fails here when the brain starts sending something the relay doesn't know.
import { readdirSync, readFileSync } from 'node:fs';

const DIR = new URL('../../../brain-go/internal/brain/testdata/', import.meta.url);

/** Every fixture: its name, the endpoint it goes to, and its body as the brain writes it. */
export const BRAIN_REQUESTS = readdirSync(DIR).filter((name) => name.endsWith('.json')).map((name) => ({
  name, endpoint: name.startsWith('evaluate-') ? 'evaluation-model' : 'language-model', body: readFileSync(new URL(name, DIR), 'utf8'),
}));

const body = (/** @type {string} */ name) => /** @type {{ body: string }} */ (BRAIN_REQUESTS.find((r) => r.name === name)).body;

/** A Jev call (work or distraction) and a Luna call (one line), as the brain sends them. */
export const JEV_BODY = body('evaluate-kind.json');
export const LUNA_BODY = body('generate-line.json');
