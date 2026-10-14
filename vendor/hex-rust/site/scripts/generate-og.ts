import { chromium } from "playwright"
import { fileURLToPath } from "node:url"

// Run against the local Vite site; ?og freezes the actual Three.js rig.
const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 })
  await page.goto(`${process.env.HEX_SITE_URL ?? "http://127.0.0.1:5173"}/?og`)
  await page.waitForFunction(() => document.querySelector("canvas")?.width === 1200)
  await page.evaluate(() => document.fonts.ready)
  await page.addStyleTag({ content: `
    .header { padding: 54px 64px; }
    .hero { position: absolute; left: 64px; top: 215px; padding: 0; width: 480px; text-align: left; align-items: flex-start; }
    .hero__copy { align-items: flex-start; }
    h1 { font-size: 66px; max-width: 8ch; line-height: 1.03; }
    .hero__copy > p { font-size: 20px; max-width: 330px; text-align: left; margin-top: 18px; }
    .hero__title { display: block; }
    .download, .requirements, .download-alternative { display: none !important; }
  ` })
  await page.locator(".hero__copy > p").evaluate(el => { el.textContent = "Private, local voice dictation. For Mac and Linux." })
  // Let the GPU present the fixed pose after styles and fonts settle.
  await page.evaluate(() => new Promise<void>(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))))
  await page.screenshot({ path: fileURLToPath(new URL("../public/og-teeth.png", import.meta.url)) })
} finally {
  await browser.close()
}
