// @ts-check
import { DEFAULTS, PLANS, parseFlags, resolveFlags } from '../api/_lib/flags.js';

/**
 * `npm run check-flags -- '<MOKU_FLAGS value>'`: checks a value before it goes into Vercel, and shows what everyone,
 * each plan and each device listed would get. Exits 1 when an entry would be dropped. The call limits shown start
 * from the code's defaults; the relay starts them from MOKU_RATE_PER_MINUTE and MOKU_RATE_PER_DAY when those are set.
 */
const raw = process.argv[2];
if (!raw) { console.error(`usage: npm run check-flags -- '{"everyone":{"forceCalm":true}}'`); process.exit(1); }
const doc = parseFlags(raw, 'MOKU_FLAGS');
const show = (/** @type {string} */ label, /** @type {import('../api/_lib/flags.js').Who} */ who) => {
  const flags = resolveFlags({ ...DEFAULTS }, [doc], who);
  const changed = Object.entries(flags).filter(([name, value]) => value !== DEFAULTS[/** @type {keyof typeof DEFAULTS} */ (name)]);
  console.log(`${label.padEnd(24)} ${changed.length ? changed.map(([name, value]) => `${name}=${JSON.stringify(value)}`).join(' ') : '(defaults)'}`);
};
show('everyone', {});
for (const plan of PLANS) show(`plan ${plan}`, { plan });
for (const device of Object.keys(doc.devices)) show(`device ${device.slice(0, 12)}`, { device });
if (doc.problems.length) {
  console.log(`\ndropped (the rest still applies):\n${doc.problems.map((p) => `  ${p}`).join('\n')}`);
  process.exit(1);
}
