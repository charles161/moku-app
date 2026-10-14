// Renders public/og-image.jpg (1200×630) from the hero itself: the H1 and its line
// beside the comeback frame (the live demo's still at 13.4 s, after the house piece
// lands, with Moku happy). At 560px the stage is its close-up: Moku's face and
// today's house.
//
//   node scripts/export-og-image.cjs http://127.0.0.1:4173/
//
// Set PLAYWRIGHT_MODULE when Playwright lives elsewhere (../melo-tab on Charles's Mac).
const path = require('node:path');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');

const url = new URL('?still=13.4', process.argv[2] || 'http://127.0.0.1:5186/');
const output = path.resolve(__dirname, '../public/og-image.jpg');

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
  await page.goto(url.href, { waitUntil: 'load' });
  await page.waitForFunction(() => document.querySelector('.live-demo').classList.contains('is-still'));
  // Only the hero: the H1, its line and the stage, with room to breathe.
  await page.addStyleTag({ content: `
    body > *:not(main), main > *:not(.live-hero), .hero-get, .hero-privacy, .live-demo > :not(.desk-frame) { display: none !important; }
    .live-hero { min-height: 630px !important; height: 630px; padding-block: 0 !important; width: 1080px !important; grid-template-columns: 460px 560px !important; column-gap: 60px !important; }
    .hero-copy { padding-bottom: 0 !important; }
    .hero-copy h1 { font-size: 80px !important; }
    .live-demo { width: 560px !important; min-width: 0 !important; }
  ` });
  await page.evaluate(async () => {
    await document.fonts.ready;
    const images = [...document.querySelectorAll('.desk img')].filter((image) => image.loading !== 'lazy' || image.complete);
    await Promise.race([Promise.all(images.map((image) => image.decode().catch(() => {}))), new Promise((resolve) => setTimeout(resolve, 3000))]);
    window.dispatchEvent(new Event('resize'));
  });
  await page.waitForTimeout(600);
  await page.screenshot({ path: output, type: 'jpeg', quality: 88 });
  await browser.close();
  console.log(`Wrote ${path.relative(process.cwd(), output)}`);
})();
